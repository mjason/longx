defmodule Longx.Codex.Sandbox do
  @moduledoc """
  Is codex's command sandbox going to work on this machine?

  Codex sandboxes agent commands itself (Linux: bubblewrap, bundled as
  `codex-resources/bwrap`; macOS: seatbelt; Windows: its restricted-token
  sandbox). On Linux bubblewrap needs unprivileged user namespaces, which
  WSL1, most containers and some hardened distributions refuse — codex then
  rejects every sandboxed command at turn time. `probe/0` finds that out at
  boot by running the bundled bwrap the way codex does (`--unshare-user
  --unshare-pid --unshare-ipc`, `/proc` dropped when it cannot be mounted),
  then once more with `--unshare-net` — what codex adds when a command runs
  without network access. Some hosts (containers, some VMs, GitHub runners)
  allow the first and refuse the second ("loopback: Failed RTM_NEWADDR"):
  there the sandbox works only for commands allowed to reach the network,
  which is `:no_net_isolation` — a project with network access on is fine,
  one with it off has every command refused. Ubuntu ≥ 24.04 refuses the
  namespaces to unconfined programs through AppArmor
  (`kernel.apparmor_restrict_unprivileged_userns = 1`: "setting up uid map:
  Permission denied") — reported as `:apparmor`, since the fix is a one-line
  profile for the bundled bwrap (README), not a kernel setting. `status/0`
  is what the UI shows.
  """

  @apparmor_sysctl "/proc/sys/kernel/apparmor_restrict_unprivileged_userns"

  alias Longx.Codex.Runtime
  alias Longx.Shim

  @key {__MODULE__, :report}

  @type reason ::
          {:user_namespaces | :apparmor | :network_isolation | :seccomp | :unknown, String.t()}
          | :not_installed
          | :unsupported

  @type status :: :ok | :no_net_isolation | :unavailable

  @doc "Runs the probe and caches the result. `:ok` or `{:error, reason}`."
  @spec probe() :: :ok | {:error, reason}
  def probe do
    {bwrap, result} = run_probe(:os.type())

    :persistent_term.put(@key, %{
      status: status_of(result),
      reason: unwrap(result),
      bwrap: bwrap,
      gpu: gpu?(),
      platform: elem(Longx.Platform.current(), 0),
      checked_at: DateTime.utc_now()
    })

    result
  end

  defp status_of(:ok), do: :ok
  defp status_of({:error, {:network_isolation, _}}), do: :no_net_isolation
  defp status_of({:error, _}), do: :unavailable

  @doc "`:ok` | `:no_net_isolation` | `:unavailable`; probes on first call."
  @spec status() :: status
  def status, do: report().status

  @doc "The cached probe result with its reason, the bwrap it ran, and the time."
  @spec report() :: %{
          status: status,
          reason: reason | nil,
          bwrap: String.t() | nil,
          gpu: boolean,
          platform: Longx.Platform.os(),
          checked_at: DateTime.t()
        }
  def report do
    case :persistent_term.get(@key, nil) do
      nil ->
        probe()
        :persistent_term.get(@key)

      report ->
        report
    end
  end

  # macOS and Windows: nothing to probe from here (seatbelt is built in; the
  # Windows sandbox is set up by codex itself) — assume ok until turn time
  defp run_probe({:unix, :linux}) do
    case bwrap_for_codex() do
      {which, bwrap} when which in [:system, :bundled] ->
        {bwrap,
         evaluate(fn args ->
           case Shim.run([bwrap | args], timeout: 10_000) do
             {:ok, %{status: status, stderr: stderr}} -> {status, stderr}
             {:error, reason} -> {1, inspect(reason)}
           end
         end)}

      {:error, _} = error ->
        {nil, error}
    end
  end

  defp run_probe(_other), do: {nil, :ok}

  @doc """
  The bubblewrap codex will actually run: **a `bwrap` on PATH comes first**
  (codex's launcher prefers the system one when its `--help` lists
  `--perms`; `preferred_bwrap_launcher` in linux-sandbox/src/launcher.rs),
  the bundled `codex-resources/bwrap` otherwise. An AppArmor profile has to
  cover the one codex runs — the bundled path alone is not enough on a
  host with bubblewrap installed.
  """
  @spec bwrap_for_codex() :: {:system | :bundled, String.t()} | {:error, reason}
  def bwrap_for_codex do
    system = System.find_executable("bwrap")

    help =
      case system && System.cmd(system, ["--help"], stderr_to_stdout: true) do
        {out, _} -> out
        _ -> ""
      end

    choose_bwrap(system, help, bundled_bwrap())
  rescue
    _ -> choose_bwrap(nil, "", bundled_bwrap())
  end

  @doc false
  def choose_bwrap(system, help, bundled) do
    cond do
      is_binary(system) and help =~ "--perms" -> {:system, system}
      match?({:ok, _}, bundled) -> {:bundled, elem(bundled, 1)}
      true -> bundled
    end
  end

  defp bundled_bwrap do
    with {:ok, exe} <- Runtime.executable() do
      bwrap = exe |> Path.dirname() |> Path.join("../codex-resources/bwrap") |> Path.expand()
      if File.exists?(bwrap), do: {:ok, bwrap}, else: {:error, :not_installed}
    end
  end

  @doc """
  The user's tool cache — where uv, pip, npm, cargo, Hugging Face… keep
  what they download — for the platform: Linux `$XDG_CACHE_HOME` (absolute)
  else `~/.cache`; macOS `~/Library/Caches`; Windows `%LOCALAPPDATA%` else
  `~/AppData/Local`. Nil without a home. Writable in every workspace-write
  sandbox like `/tmp` (`Longx.Projects.writable_roots/1`): a tool that
  cannot write its cache fails on the first `uv run`, and the cache is the
  one directory outside the project every project needs.
  """
  @spec cache_dir(Longx.Platform.t(), %{optional(String.t()) => String.t()}) :: Path.t() | nil
  def cache_dir(platform \\ Longx.Platform.current(), env \\ System.get_env())

  def cache_dir({:linux, _}, env) do
    case env["XDG_CACHE_HOME"] do
      "/" <> _ = dir -> dir
      _ -> home_join(env["HOME"], ".cache")
    end
  end

  def cache_dir({:darwin, _}, env), do: home_join(env["HOME"], "Library/Caches")

  def cache_dir({:windows, _}, env) do
    case env["LOCALAPPDATA"] do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> home_join(env["USERPROFILE"], "AppData\\Local", "\\")
    end
  end

  defp home_join(home, rel, sep \\ "/")
  defp home_join(home, _rel, _sep) when home in [nil, ""], do: nil
  defp home_join(home, rel, sep), do: String.trim_trailing(home, sep) <> sep <> rel

  @doc """
  Does this machine have a GPU (`/dev/nvidia*` nodes, or WSL2's `/dev/dxg`)? A sandboxed
  command cannot see it: bubblewrap's `--dev /dev` is a minimal device tree,
  and codex offers no device pass-through — its writable roots are
  `--bind`s (no device access) that it also seeds with protected `.git` /
  `.codex` entries, so a device node or `/dev/dri` as a root breaks the
  launch (tried on a DGX Spark). GPU work runs in the full-access mode;
  the UI says so where the sandbox is chosen.
  """
  @spec gpu?([Path.t()]) :: boolean
  def gpu?(entries \\ dev_entries()) do
    # WSL2 has no nvidia nodes: its GPU is the paravirtual /dev/dxg
    Enum.any?(entries, fn path ->
      name = Path.basename(path)
      String.starts_with?(name, "nvidia") or name == "dxg"
    end)
  end

  @doc """
  Host paths worth letting into the sandbox on this machine, grouped for the
  settings page: `gpu` (nvidia nodes, WSL2's dxg, /dev/dri), `usb` (the USB
  bus, serial adapters), `docker` (the daemon socket — host root, flagged).
  Only groups with something present.
  """
  @spec presets([Path.t()]) :: [
          %{id: String.t(), label: String.t(), paths: [Path.t()], danger: boolean}
        ]
  def presets(entries \\ dev_entries() ++ socket_entries()) do
    groups = [
      {"gpu", "GPU", false, &(String.starts_with?(&1, "nvidia") or &1 in ["dxg", "dri"])},
      {"usb", "USB / 串口", false,
       &(&1 == "usb" or String.starts_with?(&1, "ttyUSB") or String.starts_with?(&1, "ttyACM"))},
      {"docker", "Docker socket", true, &(&1 == "docker.sock")}
    ]

    for {id, label, danger, match?} <- groups,
        paths = entries |> Enum.filter(&match?.(Path.basename(&1))) |> Enum.uniq() |> Enum.sort(),
        paths != [] do
      %{id: id, label: label, paths: paths, danger: danger}
    end
  end

  defp socket_entries, do: Enum.filter(["/var/run/docker.sock"], &File.exists?/1)

  # /dev one level down, plus the USB bus directory
  defp dev_entries do
    case File.ls("/dev") do
      {:ok, names} ->
        Enum.map(names, &Path.join("/dev", &1)) ++ Enum.filter(["/dev/bus/usb"], &File.dir?/1)

      _ ->
        []
    end
  end

  # codex's namespace flags (linux-sandbox/src/bwrap.rs); --unshare-net is
  # added for commands without network access
  @namespaces ~w(--unshare-user --unshare-pid --unshare-ipc)

  @doc """
  The probe over a runner that gets bwrap's arguments and answers
  `{exit_status, stderr}` — the real one runs the bundled binary. The
  smallest sandbox codex would build (read-only root, `/bin/true`): first
  as codex runs a command with network, `/proc` dropped when it cannot be
  mounted (codex's own preflight does that), then with `--unshare-net`.
  """
  @spec evaluate(([String.t()] -> {integer, String.t()}), apparmor_restricted: boolean) ::
          :ok | {:error, reason}
  def evaluate(run, opts \\ []) do
    with {:ok, mounts} <- base_step(run),
         :ok <- network_step(run.(mounts ++ @namespaces ++ ["--unshare-net", "/bin/true"])) do
      :ok
    else
      {:error, {:user_namespaces, message}} = error ->
        if Keyword.get_lazy(opts, :apparmor_restricted, &apparmor_restricted?/0),
          do: {:error, {:apparmor, message}},
          else: error

      error ->
        error
    end
  end

  # Ubuntu's AppArmor switch: unconfined programs get user namespaces without
  # capabilities, so bwrap cannot write its uid map
  defp apparmor_restricted? do
    case File.read(@apparmor_sysctl) do
      {:ok, value} -> String.trim(value) == "1"
      _ -> false
    end
  end

  defp base_step(run) do
    base = ["--ro-bind", "/", "/", "--dev", "/dev"]
    with_proc = base ++ ["--proc", "/proc"]

    case interpret(run.(with_proc ++ @namespaces ++ ["/bin/true"])) do
      :ok ->
        {:ok, with_proc}

      {:error, {_, message}} = error ->
        # a /proc that cannot be mounted: codex retries without it
        if message =~ ~r/proc/i do
          with :ok <- interpret(run.(base ++ @namespaces ++ ["/bin/true"])), do: {:ok, base}
        else
          error
        end
    end
  end

  defp network_step({0, _stderr}), do: :ok
  defp network_step({_status, stderr}), do: {:error, {:network_isolation, trim(stderr)}}

  defp interpret({status, stderr}), do: interpret(status, stderr)

  defp trim(stderr), do: stderr |> String.trim() |> String.slice(0, 500)

  @doc "Turns bubblewrap's exit status and stderr into a reason."
  @spec interpret(integer, String.t()) :: :ok | {:error, reason}
  def interpret(0, _stderr), do: :ok

  def interpret(_status, stderr) do
    message = trim(stderr)

    cond do
      message =~ ~r/namespace|uid map|gid map|Operation not permitted|Permission denied/i ->
        {:error, {:user_namespaces, message}}

      message =~ ~r/seccomp/i ->
        {:error, {:seccomp, message}}

      true ->
        {:error, {:unknown, message}}
    end
  end

  defp unwrap(:ok), do: nil
  defp unwrap({:error, reason}), do: reason
end
