defmodule Longx.Tls.Manager do
  @moduledoc """
  Obtains and renews the HTTPS certificate and keeps the listener in step
  with the settings. One issuance at a time (a second `issue/1` joins the
  one in flight), run as a task: the tool is fetched first when it is not
  there (`Longx.Tls.Tool`, stages `:downloading` / `:verifying` /
  `:extracting` with the bytes), then `longx-cert obtain` is handed
  `Longx.Tls.request/0` on stdin (`:issuing`) and what it answers is stored
  (`Longx.Tls.store_certificate/1`). Then the listener serves it — started
  on the configured port, or told to reload when it already runs there — or,
  on a failure, nothing changes and the error is shown (`:failed`) and
  recorded (`Longx.System.Faults`, Sentry).

  `status/0` and `{:tls, status}` on `topic/0` say how it goes. At boot the
  listener starts when HTTPS is on and a certificate is on disk;
  `apply_settings/0` does the same after the settings change (turning HTTPS
  off stops it). `renew_if_due/1` — the daily `Longx.Tls.RenewWorker` —
  issues when `due?/3`: at once without a certificate or for other names,
  else 30 days before it runs out (Let's Encrypt's are 90 days long).
  The address it serves is published for `Longx.Tls.https_url/0` (the
  callbacks' public address, the http → https redirect).
  """

  use GenServer

  require Logger

  alias Longx.Tls
  alias Longx.Tls.{Listener, Tool}

  @topic "tls"
  @renew_before_days 30
  @tool_timeout :timer.minutes(12)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The stage now (`:idle`, `:downloading`, `:verifying`, `:extracting`, `:issuing`, `:failed`) and the last error."
  @spec status() :: map
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Starts an issuance, or joins the one running; nothing before names and a provider are saved."
  @spec issue(atom) :: :ok | {:error, :not_configured}
  def issue(reason \\ :manual) do
    case Tls.settings() do
      %{domains: [_ | _], provider: provider} when is_binary(provider) ->
        GenServer.call(__MODULE__, {:issue, reason})

      _ ->
        {:error, :not_configured}
    end
  end

  @doc "Issues when a renewal is due (the daily job)."
  @spec renew_if_due(DateTime.t()) :: :issuing | :not_due | {:error, :not_configured}
  def renew_if_due(now \\ DateTime.utc_now()) do
    if due?(Tls.settings(), Tls.certificate(), now) do
      with :ok <- issue(:renewal), do: :issuing
    else
      :not_due
    end
  end

  @doc "Whether a certificate should be obtained now."
  @spec due?(map, map | nil, DateTime.t()) :: boolean
  def due?(%{enabled: false}, _certificate, _now), do: false
  def due?(_settings, nil, _now), do: true

  def due?(%{domains: domains}, %{domains: have, not_after: not_after}, now) do
    Enum.sort(domains) != Enum.sort(have) or is_nil(not_after) or
      DateTime.diff(not_after, now, :day) < @renew_before_days
  end

  @doc "Starts, reloads or stops the listener to match the settings and the certificate on disk."
  @spec apply_settings() :: :ok
  def apply_settings, do: GenServer.call(__MODULE__, :apply_settings)

  @doc "Forgets a finished or failed run (tests)."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  ## Server

  @impl true
  def init(_opts) do
    {:ok,
     %{
       stage: :idle,
       received: 0,
       total: nil,
       error: nil,
       task: nil,
       reason: nil,
       started_at: nil,
       finished_at: nil
     }, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    apply_listener()
    {:noreply, state}
  rescue
    error ->
      Logger.warning("tls: the listener could not be set up at boot: #{Exception.message(error)}")
      {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call(:reset, _from, %{task: nil} = state),
    do: {:reply, :ok, %{state | stage: :idle, error: nil, received: 0, total: nil}}

  def handle_call(:reset, _from, state), do: {:reply, :ok, state}

  def handle_call(:apply_settings, _from, state) do
    apply_listener()
    {:reply, :ok, state}
  end

  def handle_call({:issue, _reason}, _from, %{task: %Task{}} = state), do: {:reply, :ok, state}

  def handle_call({:issue, reason}, _from, state) do
    server = self()
    request = Tls.request()
    first = if tool_ready?(), do: :issuing, else: :downloading
    task = Task.Supervisor.async_nolink(Longx.Tls.TaskSupervisor, fn -> run(request, server) end)

    Logger.info(
      "tls: obtaining a certificate for #{Enum.join(request["domains"], ", ")} (#{reason})"
    )

    state = %{
      state
      | task: task,
        reason: reason,
        error: nil,
        received: 0,
        total: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil
    }

    {:reply, :ok, stage(state, first)}
  end

  @impl true
  def handle_cast({:progress, received, total}, %{stage: :downloading} = state),
    do: {:noreply, stage(%{state | received: received, total: total}, :downloading)}

  def handle_cast({:progress, _, _}, state), do: {:noreply, state}

  def handle_cast({:stage, s}, state) when s in [:downloading, :verifying, :extracting, :issuing],
    do: {:noreply, stage(state, s)}

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil, finished_at: DateTime.utc_now()}

    case result do
      {:ok, _result} ->
        Logger.info("tls: certificate stored")
        apply_listener()
        {:noreply, stage(%{state | error: nil}, :idle)}

      {:error, reason} ->
        message = describe(reason)
        Logger.warning("tls: no certificate: #{message}")
        Longx.System.Faults.record(:tls, "certificate", message)
        {:noreply, stage(%{state | error: message}, :failed)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    message = "the issuance crashed: #{inspect(reason)}"
    Longx.System.Faults.record(:tls, "certificate", message)

    {:noreply,
     stage(%{state | task: nil, error: message, finished_at: DateTime.utc_now()}, :failed)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## The issuance (in the task)

  defp run(request, server) do
    with {:ok, exe} <- ensure_tool(server),
         :ok <- GenServer.cast(server, {:stage, :issuing}),
         {:ok, result} <- obtain(exe, request) do
      :ok = Tls.store_certificate(result)
      {:ok, result}
    end
  end

  defp tool_ready? do
    case Tool.resolve() do
      {:ok, :env, _} -> true
      _ -> Tool.installed?()
    end
  end

  defp ensure_tool(server) do
    target = Tool.current_target()

    case Tool.resolve(target) do
      {:ok, :env, path} ->
        {:ok, path}

      resolved ->
        if Tool.installed?(target) do
          {:ok, elem(resolved, 2)}
        else
          download(target, server)
        end
    end
  end

  defp download(target, server) do
    with {:ok, sha} <- expected_sha(target),
         {:ok, path} <-
           Tool.install(target,
             source: {:url, config(:download_url) || Tool.asset_url(target)},
             sha256: sha,
             progress: fn {received, total} ->
               GenServer.cast(server, {:progress, received, total})
             end,
             on_stage: fn s -> GenServer.cast(server, {:stage, s}) end
           ) do
      Tool.prune_old(target)
      {:ok, path}
    end
  end

  defp expected_sha(target) do
    case config(:download_sha256) do
      nil -> Tool.sha256(target)
      sha -> {:ok, sha}
    end
  end

  defp obtain(exe, request) do
    case Longx.Shim.run([exe, "obtain"], input: Jason.encode!(request), timeout: @tool_timeout) do
      {:ok, %{stdout: out, stderr: err, status: status}} ->
        case Jason.decode(String.trim(out)) do
          {:ok, %{"ok" => true} = result} -> {:ok, result}
          {:ok, %{"error" => error}} when is_binary(error) -> {:error, error}
          _ -> {:error, "longx-cert exited with #{status}: #{last_lines(err)}"}
        end

      {:error, :timeout} ->
        {:error, "longx-cert did not finish within #{div(@tool_timeout, 60_000)} minutes"}

      {:error, reason} ->
        {:error, "longx-cert could not run: #{inspect(reason)}"}
    end
  end

  defp last_lines(text),
    do: text |> String.split("\n", trim: true) |> Enum.take(-5) |> Enum.join("\n")

  ## The listener

  defp apply_listener do
    settings = Tls.settings()

    case {settings.enabled, Tls.certificate()} do
      {true, %{} = certificate} -> serve(settings, certificate)
      _ -> unserve()
    end
  end

  defp serve(settings, certificate) do
    result =
      if Listener.running?() and Listener.port() == settings.port do
        Listener.reload()
        {:ok, settings.port}
      else
        Listener.start(port: settings.port, certfile: Tls.cert_path(), keyfile: Tls.key_path())
      end

    case result do
      {:ok, port} ->
        Tls.publish(url(certificate.domains, port), settings.redirect)

      {:error, reason} ->
        message = "the https listener could not start on #{settings.port}: #{inspect(reason)}"
        Logger.warning("tls: " <> message)
        Longx.System.Faults.record(:tls, "listener", message)
        Tls.publish(nil, false)
    end
  end

  defp unserve do
    Listener.stop()
    Tls.publish(nil, false)
  end

  # the first name that is not a wildcard; the port left out when it is 443
  defp url(domains, port) do
    case Enum.find(domains, &(not String.starts_with?(&1, "*."))) do
      nil -> nil
      host when port == 443 -> "https://#{host}"
      host -> "https://#{host}:#{port}"
    end
  end

  ## Status

  defp stage(state, s) do
    state = %{state | stage: s}
    Phoenix.PubSub.broadcast(Longx.PubSub, @topic, {:tls, public(state)})
    state
  end

  defp public(state),
    do: Map.take(state, [:stage, :received, :total, :error, :reason, :started_at, :finished_at])

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(:unsupported_target), do: "longx-cert has no build for this platform"

  defp describe({:download_failed, {:status, status}}),
    do: "downloading longx-cert failed (HTTP #{status})"

  defp describe({:download_failed, %{__exception__: true} = e}),
    do: "downloading longx-cert failed: " <> Exception.message(e)

  defp describe({:download_failed, reason}),
    do: "downloading longx-cert failed: #{inspect(reason)}"

  defp describe({:checksum_mismatch, _}),
    do: "the longx-cert archive does not match its pinned checksum"

  defp describe({:extract_failed, reason}), do: "could not unpack longx-cert: #{inspect(reason)}"
  defp describe(reason), do: inspect(reason)

  defp config(key), do: :longx |> Application.get_env(Longx.Tls, []) |> Keyword.get(key)
end
