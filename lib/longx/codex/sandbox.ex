defmodule Longx.Codex.Sandbox do
  @moduledoc """
  Is codex's command sandbox going to work on this machine?

  Codex sandboxes agent commands itself (Linux: bubblewrap, bundled as
  `codex-resources/bwrap`; macOS: seatbelt; Windows: its restricted-token
  sandbox). On Linux bubblewrap needs unprivileged user namespaces, which
  WSL1, most containers and some hardened distributions refuse — codex then
  rejects every sandboxed command at turn time. `probe/0` finds that out at
  boot by running the bundled bwrap once; `status/0` is what the UI shows.
  """

  alias Longx.Codex.Runtime
  alias Longx.Shim

  @key {__MODULE__, :report}

  @type reason ::
          {:user_namespaces | :seccomp | :unknown, String.t()} | :not_installed | :unsupported

  @doc "Runs the probe and caches the result. `:ok` or `{:error, reason}`."
  @spec probe() :: :ok | {:error, reason}
  def probe do
    result = run_probe(:os.type())

    :persistent_term.put(@key, %{
      status: if(result == :ok, do: :ok, else: :unavailable),
      reason: unwrap(result),
      checked_at: DateTime.utc_now()
    })

    result
  end

  @doc "`:ok` | `:unavailable`; probes on first call."
  @spec status() :: :ok | :unavailable
  def status, do: report().status

  @doc "The cached probe result with its reason and time."
  @spec report() :: %{status: :ok | :unavailable, reason: reason | nil, checked_at: DateTime.t()}
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
    with {:ok, bwrap} <- bundled_bwrap() do
      # the smallest sandbox codex would build: read-only root, run `true`
      case Shim.run(
             [
               bwrap,
               "--ro-bind",
               "/",
               "/",
               "--dev",
               "/dev",
               "--proc",
               "/proc",
               "--unshare-all",
               "/bin/true"
             ],
             timeout: 10_000
           ) do
        {:ok, %{status: status, stderr: stderr}} -> interpret(status, stderr)
        {:error, reason} -> {:error, {:unknown, inspect(reason)}}
      end
    end
  end

  defp run_probe(_other), do: :ok

  defp bundled_bwrap do
    with {:ok, exe} <- Runtime.executable() do
      bwrap = exe |> Path.dirname() |> Path.join("../codex-resources/bwrap") |> Path.expand()
      if File.exists?(bwrap), do: {:ok, bwrap}, else: {:error, :not_installed}
    end
  end

  @doc "Turns bubblewrap's exit status and stderr into a reason."
  @spec interpret(integer, String.t()) :: :ok | {:error, reason}
  def interpret(0, _stderr), do: :ok

  def interpret(_status, stderr) do
    message = stderr |> String.trim() |> String.slice(0, 500)

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
