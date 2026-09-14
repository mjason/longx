defmodule Longx.Upgrade do
  @moduledoc """
  Self-upgrade from GitHub releases, the way `install.sh` does it, from the
  settings page.

  **Check**: `GET /repos/<repo>/releases/latest` (a saved GitHub token —
  `Longx.System.Setting` `github_token` — goes out as the bearer, since an
  anonymous client gets 60 calls an hour per address). The result is cached
  here and refreshed every `tick` (6 h), so the status strip can say "a new
  version is out" without a request per page.

  **Apply** (only inside an install — `RELEASE_ROOT/bin/longx` exists, or
  `app_dir:` is configured): download `longx-<v>-linux-<arch>.tar.gz` and
  its `.sha256` into `<home>/downloads`, verify, snapshot the database to
  `<home>/backups/longx-<current>-<stamp>.db` (`VACUUM INTO`, consistent
  while running), unpack into `app.new`, swap `app` → `app.old` → `app`
  (the running VM keeps its open files; nothing else may start a codex
  before the restart), then run `restart_command` — `systemctl --user
  restart --no-block <service>` by default, which stops this VM. When that
  fails (no systemd) the swap stays and the status asks for a manual
  restart. Every stage is broadcast on `topic/0` as `{:upgrade, status}`.

      config :longx, Longx.Upgrade,
        repo: "mjason/longx", api_url: "https://api.github.com",
        app_dir: nil, restart_command: nil, tick: :timer.hours(6)
  """

  use GenServer
  require Logger

  alias Longx.System, as: Sys

  @token_key "github_token"
  @stages ~w(idle downloading verifying installing restarting installed failed)a

  @type stage ::
          :idle | :downloading | :verifying | :installing | :restarting | :installed | :failed

  @type check :: %{
          current: String.t(),
          latest: String.t(),
          tag: String.t(),
          available: boolean,
          notes_url: String.t() | nil,
          checked_at: DateTime.t()
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "PubSub topic for `{:upgrade, status}`."
  def topic, do: "upgrade"

  @doc "The running version, from the application spec."
  @spec current_version() :: String.t()
  def current_version, do: :longx |> Application.spec(:vsn) |> to_string()

  @doc "The release asset's architecture word for this machine (nil: no prebuilt release)."
  @spec arch() :: String.t() | nil
  def arch do
    case Longx.Platform.current() do
      {:linux, :x86_64} -> "x86_64"
      {:linux, :aarch64} -> "arm64"
      _ -> nil
    end
  end

  @doc "The tarball a release carries for this machine."
  def asset_name(version), do: "longx-#{version}-linux-#{arch()}.tar.gz"

  @doc """
  Where the program lives, when this is an install: `app` (the release
  root — `app_dir:` config, else `RELEASE_ROOT`, which `bin/longx` sets),
  `home` (its parent: downloads, backups, `app.old` go there) and the
  systemd user `service` (`LONGX_SERVICE`, default `longx`). nil in dev.
  """
  @spec install(map) :: %{app: String.t(), home: String.t(), service: String.t()} | nil
  def install(env \\ System.get_env()) do
    app = config(:app_dir) || env["RELEASE_ROOT"]

    if is_binary(app) and app != "" and File.regular?(Path.join(app, "bin/longx")) do
      %{
        app: Path.expand(app),
        home: Path.dirname(Path.expand(app)),
        service: env["LONGX_SERVICE"] || "longx"
      }
    end
  end

  def installed?, do: install() != nil

  # ---- the GitHub token ---------------------------------------------------

  @spec github_token() :: String.t() | nil
  def github_token do
    case Sys.get_setting(@token_key) do
      {:ok, %{value: value}} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  def github_token?, do: github_token() != nil

  @doc "Saves the token (nil or blank removes it)."
  @spec set_github_token(String.t() | nil) :: :ok | {:error, term}
  def set_github_token(token) when token in [nil, ""] do
    case Sys.get_setting(@token_key) do
      {:ok, setting} -> Sys.delete_setting(setting)
      _ -> :ok
    end
  end

  def set_github_token(token) when is_binary(token) do
    with {:ok, _} <- Sys.put_setting(@token_key, String.trim(token)), do: :ok
  end

  # ---- check -----------------------------------------------------------------

  @doc "The latest release against the running version; cached unless `force: true`."
  @spec check(force: boolean) :: {:ok, check} | {:error, String.t()}
  def check(opts \\ []) do
    case {Keyword.get(opts, :force, false), GenServer.call(__MODULE__, :cached)} do
      {false, %{} = cached} -> {:ok, cached}
      _ -> fetch_and_store()
    end
  end

  defp fetch_and_store do
    result =
      case fetch_latest() do
        {:ok, release} -> {:ok, describe(release)}
        {:error, _} = error -> error
      end

    GenServer.call(__MODULE__, {:store_check, result})
    result
  end

  defp describe(release) do
    latest = String.trim_leading(release["tag_name"] || "", "v")

    %{
      current: current_version(),
      latest: latest,
      tag: release["tag_name"],
      available: newer?(latest, current_version()),
      notes_url: release["html_url"],
      checked_at: DateTime.utc_now()
    }
  end

  @doc false
  def newer?(latest, current) do
    match?({:ok, _}, Version.parse(latest)) and match?({:ok, _}, Version.parse(current)) and
      Version.compare(latest, current) == :gt
  end

  defp fetch_latest do
    url = "#{config(:api_url) || "https://api.github.com"}/repos/#{repo()}/releases/latest"

    headers =
      [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "longx/#{current_version()}"}
      ] ++
        case github_token() do
          nil -> []
          token -> [{"authorization", "Bearer #{token}"}]
        end

    case Req.get(url, headers: headers, retry: false, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        # decode ourselves: a test double may answer without a JSON content type
        case decode(body) do
          %{"tag_name" => _} = release -> {:ok, release}
          _ -> {:error, "GitHub 的回应看不懂"}
        end

      {:ok, %{status: 404}} ->
        {:error, "GitHub 上还没有发布版本（#{repo()}）"}

      {:ok, %{status: 401}} ->
        {:error, "GitHub token 无效（401）——检查设置里的 token"}

      {:ok, %{status: status} = resp} when status in [403, 429] ->
        if Req.Response.get_header(resp, "x-ratelimit-remaining") == ["0"] do
          {:error, "GitHub API 限流了（匿名每小时 60 次）：填一个 GitHub token 就不受限"}
        else
          {:error, "GitHub 拒绝了请求（#{status}）"}
        end

      {:ok, %{status: status}} ->
        {:error, "GitHub 回应了 #{status}"}

      {:error, reason} ->
        {:error, "连不上 GitHub：#{Exception.message(reason)}"}
    end
  end

  defp decode(%{} = body), do: body

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp decode(_), do: nil

  defp repo, do: config(:repo) || "mjason/longx"

  # ---- status / apply ----------------------------------------------------------

  @doc "Everything the settings page shows: version, the last check, the stage of an upgrade."
  def status do
    GenServer.call(__MODULE__, :status)
    |> Map.merge(%{installed: installed?(), github_token?: github_token?()})
  end

  @doc "Forget the cached check and the stage (tests)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  Fetches the latest release and, when it is newer and has a tarball for
  this machine, starts the upgrade in the background: the reply is the
  status at `:downloading`; follow `status/0` or the topic from there.
  """
  @spec apply() :: {:ok, map} | {:error, String.t()}
  def apply do
    with {:ok, install} <- ensure_install(),
         {:ok, release} <- fetch_latest(),
         info = describe(release),
         :ok = GenServer.call(__MODULE__, {:store_check, {:ok, info}}),
         :ok <- ensure_newer(info),
         {:ok, urls} <- asset_urls(release, info.latest) do
      GenServer.call(__MODULE__, {:apply, install, info.latest, urls})
    end
  end

  defp ensure_install do
    case install() do
      nil -> {:error, "只有用 install.sh 安装的版本能在这里升级（开发环境请用 git）"}
      install -> {:ok, install}
    end
  end

  defp ensure_newer(%{available: true}), do: :ok
  defp ensure_newer(%{current: current}), do: {:error, "已经是最新版本（#{current}）"}

  defp asset_urls(%{"assets" => assets}, version) when is_list(assets) do
    name = asset_name(version)
    url = fn n -> Enum.find_value(assets, &(&1["name"] == n && &1["browser_download_url"])) end

    case {arch(), url.(name), url.(name <> ".sha256")} do
      {nil, _, _} -> {:error, "这台机器没有预编译包（只有 linux x86_64 / arm64）"}
      {_, nil, _} -> {:error, "v#{version} 没有 linux-#{arch()} 的包（#{name}）"}
      {_, _, nil} -> {:error, "v#{version} 缺少 #{name}.sha256，无法校验"}
      {_, tarball, sha} -> {:ok, %{name: name, tarball: tarball, sha256: sha}}
    end
  end

  defp asset_urls(_release, version), do: {:error, "v#{version} 没有附件"}

  # ---- the server ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    if tick = config(:tick), do: Process.send_after(self(), :tick, min(tick, :timer.minutes(1)))
    {:ok, %{check: nil, error: nil, stage: :idle, message: nil, target: nil, task: nil}}
  end

  @impl true
  def handle_call(:cached, _from, state), do: {:reply, state.check, state}

  def handle_call({:store_check, {:ok, check}}, _from, state),
    do: {:reply, :ok, %{state | check: check, error: nil}}

  def handle_call({:store_check, {:error, message}}, _from, state),
    do: {:reply, :ok, %{state | check: nil, error: message}}

  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call(:reset, _from, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)

    {:reply, :ok,
     %{state | check: nil, error: nil, stage: :idle, message: nil, target: nil, task: nil}}
  end

  def handle_call({:apply, _install, _version, _urls}, _from, %{task: task} = state)
      when task != nil do
    {:reply, {:error, "正在升级到 #{state.target}，等它完成"}, state}
  end

  def handle_call({:apply, install, version, urls}, _from, state) do
    server = self()

    task =
      Task.Supervisor.async_nolink(Longx.Upgrade.TaskSupervisor, fn ->
        run(install, version, urls, fn stage -> GenServer.cast(server, {:stage, stage}) end)
      end)

    state = %{state | task: task, target: version, message: nil} |> stage(:downloading)
    {:reply, {:ok, public(state)}, state}
  end

  @impl true
  def handle_cast({:stage, stage}, state), do: {:noreply, stage(state, stage)}

  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    case result do
      :ok ->
        Logger.info("upgrade: v#{state.target} installed, restart requested")
        {:noreply, stage(state, :restarting)}

      {:installed, message} ->
        Logger.warning("upgrade: v#{state.target} installed, restart failed: #{message}")
        {:noreply, state |> Map.put(:message, message) |> stage(:installed)}

      {:error, message} ->
        Logger.error("upgrade: v#{state.target} failed: #{message}")
        {:noreply, state |> Map.put(:message, message) |> stage(:failed)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    Logger.error("upgrade: crashed: #{inspect(reason)}")
    {:noreply, %{state | task: nil, message: "升级过程崩溃了：#{inspect(reason)}"} |> stage(:failed)}
  end

  def handle_info(:tick, state) do
    Task.start(fn -> check(force: true) end)
    Process.send_after(self(), :tick, config(:tick))
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp stage(state, stage) when stage in @stages do
    state = %{state | stage: stage}
    Phoenix.PubSub.broadcast(Longx.PubSub, topic(), {:upgrade, public(state)})
    state
  end

  defp public(state), do: Map.take(state, [:check, :error, :stage, :message, :target])

  # ---- the work, in a task ------------------------------------------------------------

  defp run(install, version, urls, notify) do
    downloads = Path.join(install.home, "downloads")
    tarball = Path.join(downloads, urls.name)
    File.mkdir_p!(downloads)

    with :ok <- download(urls.tarball, tarball),
         :ok <- download(urls.sha256, tarball <> ".sha256"),
         notify.(:verifying),
         :ok <- verify(tarball),
         notify.(:installing),
         :ok <- backup_database(install, version),
         :ok <- unpack(tarball, install.app),
         :ok <- swap(install.app) do
      # :restarting is the server's word once the command has been run
      restart(install)
    else
      {:error, _} = error ->
        File.rm(tarball)
        File.rm(tarball <> ".sha256")
        error
    end
  end

  defp download(url, to) do
    Logger.info("upgrade: downloading #{url}")

    case Req.get(url, into: File.stream!(to), retry: false, receive_timeout: 600_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, "下载失败（#{status}）：#{url}"}
      {:error, reason} -> {:error, "下载失败：#{Exception.message(reason)}"}
    end
  end

  defp verify(tarball) do
    expected =
      tarball
      |> Kernel.<>(".sha256")
      |> File.read!()
      |> String.split()
      |> List.first()
      |> to_string()
      |> String.downcase()

    actual =
      File.stream!(tarball, 1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected,
      do: :ok,
      else: {:error, "sha256 校验失败：包不完整或被改过（期望 #{expected}，实际 #{actual}）"}
  end

  # `VACUUM INTO` writes a consistent copy of the live database; codex's own
  # state under data/ is not ours to migrate, so it is not copied
  defp backup_database(install, _version) do
    backups = Path.join(install.home, "backups")
    File.mkdir_p!(backups)
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    to = Path.join(backups, "longx-#{current_version()}-#{stamp}.db")
    database = Longx.Repo.config()[:database]

    with {:ok, db} <- Exqlite.Sqlite3.open(database),
         :ok <- Exqlite.Sqlite3.execute(db, "VACUUM INTO '#{String.replace(to, "'", "''")}'"),
         :ok <- Exqlite.Sqlite3.close(db) do
      :ok
    else
      {:error, reason} -> {:error, "备份数据库失败：#{inspect(reason)}"}
    end
  end

  defp unpack(tarball, app) do
    new = app <> ".new"
    File.rm_rf!(new)
    File.mkdir_p!(new)

    case System.cmd("tar", ["-C", new, "--strip-components=1", "-xzf", tarball],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        if File.regular?(Path.join(new, "bin/longx")),
          do: :ok,
          else: {:error, "包里没有 bin/longx"}

      {out, _} ->
        File.rm_rf!(new)
        {:error, "解包失败：#{String.slice(out, 0, 300)}"}
    end
  end

  defp swap(app) do
    old = app <> ".old"
    File.rm_rf!(old)

    with :ok <- File.rename(app, old),
         :ok <- File.rename(app <> ".new", app) do
      :ok
    else
      {:error, reason} ->
        # put the old one back when the second move failed
        if not File.dir?(app) and File.dir?(old), do: File.rename(old, app)
        {:error, "替换程序目录失败：#{inspect(reason)}"}
    end
  end

  defp restart(install) do
    [exe | args] =
      config(:restart_command) ||
        ["systemctl", "--user", "restart", "--no-block", install.service]

    manual = "新版本已经装到 #{install.app}，但自动重启失败，请手动重启服务"

    case System.find_executable(exe) do
      nil ->
        {:installed, "#{manual}（没有 #{exe}）"}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, status} -> {:installed, "#{manual}（#{exe} 退出 #{status}：#{String.trim(out)}）"}
        end
    end
  end

  defp config(key), do: Application.get_env(:longx, __MODULE__, [])[key]
end
