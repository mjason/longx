defmodule Longx.Tls.Listener do
  @moduledoc """
  The HTTPS listener beside the plain http one: a Bandit TLS server in front
  of the same `LongxWeb.Endpoint` (HTTP/2 through ALPN, the websockets too),
  started and stopped at run time under `Longx.Tls.ListenerSupervisor` — the
  endpoint's own `https:` configuration is read once at boot, and the person
  turns HTTPS on from the settings page. `reload/0` makes the next
  connections use the certificate files as they are now (a renewal), the
  open ones keep theirs.
  """

  @supervisor Longx.Tls.ListenerSupervisor

  @doc """
  Starts the listener, replacing a running one. Options: `port:` (0 for
  any), `certfile:`, `keyfile:`, `ip:` (the http listener's by default).
  Answers the port it listens on.
  """
  @spec start(keyword) :: {:ok, :inet.port_number()} | {:error, term}
  def start(opts) do
    :ok = stop()

    spec =
      [
        plug: plug(),
        display_plug: LongxWeb.Endpoint,
        scheme: :https,
        otp_app: :longx,
        port: Keyword.fetch!(opts, :port),
        ip: Keyword.get(opts, :ip) || default_ip(),
        certfile: Keyword.fetch!(opts, :certfile),
        keyfile: Keyword.fetch!(opts, :keyfile),
        cipher_suite: :strong
      ]
      |> Bandit.child_spec()
      |> Supervisor.child_spec(id: __MODULE__)

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> port_of(pid)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops the listener (nothing when none runs)."
  @spec stop() :: :ok
  def stop do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(@supervisor), is_pid(pid) do
      DynamicSupervisor.terminate_child(@supervisor, pid)
    end

    :ok
  end

  @spec running?() :: boolean
  def running?, do: pid() != nil

  @doc "The port the listener is bound to; nil when none runs."
  @spec port() :: :inet.port_number() | nil
  def port do
    case pid() do
      nil ->
        nil

      pid ->
        case port_of(pid) do
          {:ok, port} -> port
          _ -> nil
        end
    end
  end

  @doc """
  The certificate files were replaced: `ssl` caches what it read, so the
  cache goes and the next handshake reads the files again.
  """
  @spec reload() :: :ok
  def reload, do: :ssl.clear_pem_cache()

  defp pid do
    case DynamicSupervisor.which_children(@supervisor) do
      [{_, pid, _, _} | _] when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp port_of(pid) do
    case ThousandIsland.listener_info(pid) do
      {:ok, {_ip, port}} -> {:ok, port}
      other -> {:error, other}
    end
  end

  defp default_ip,
    do: get_in(LongxWeb.Endpoint.config(:http) || [], [:ip]) || {0, 0, 0, 0, 0, 0, 0, 0}

  # as Bandit.PhoenixAdapter does: in dev the code reloader runs before the endpoint
  defp plug do
    if LongxWeb.Endpoint.config(:code_reloader) &&
         Code.ensure_loaded?(Phoenix.Endpoint.SyncCodeReloadPlug) do
      {Phoenix.Endpoint.SyncCodeReloadPlug, {LongxWeb.Endpoint, []}}
    else
      LongxWeb.Endpoint
    end
  end
end
