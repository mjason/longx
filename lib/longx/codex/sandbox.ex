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
  The GPU device nodes a sandboxed command needs, among the entries of
  `/dev`: bubblewrap's `--dev /dev` is a minimal device tree (null, zero,
  random, tty…), so CUDA inside the sandbox saw no GPU on a machine that
  has one. Passed as writable roots, codex `--bind`s them in.
  """
  @spec device_roots([Path.t()]) :: [Path.t()]
  def device_roots(entries \\ dev_entries()) do
    entries
    |> Enum.filter(fn path ->
      name = Path.basename(path)
      String.starts_with?(name, "nvidia") or name == "dri"
    end)
    |> Enum.sort()
  end

  defp dev_entries do
    case File.ls("/dev") do
      {:ok, names} -> Enum.map(names, &Path.join("/dev", &1))
      _ -> []
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
