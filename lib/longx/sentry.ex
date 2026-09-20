defmodule Longx.Sentry do
  @moduledoc """
  Error reporting to Sentry, on when the person saved a DSN in the settings
  (Settings → 请求记录 → 错误上报) and off otherwise — the `:sentry`
  application is configured with no DSN (`config :sentry`), which is how
  the SDK stays silent, and `set_dsn/1` changes that at runtime
  (`Sentry.put_config/2`); a boot reads the setting back
  (`configure_from_settings/0`, a task after the repo).

  What is reported: exceptions in web requests (`Sentry.PlugCapture` on the
  endpoint, `Sentry.PlugContext` for the request), process crashes
  (`Sentry.LoggerHandler`, attached at boot, crash reports only — not
  every error log), the server's own faults (`fault/3`, from
  `Longx.System.Faults`) and failed turns (`turn_failed/3`, from the
  Tracker) as messages with tags, and a test event from the settings page
  (`send_test/0`). The release is Longx's version, the environment
  `production` / `dev` / `test`. The DSN is kept encrypted with the other
  settings and shown masked.
  """

  require Logger

  @key "sentry_dsn"
  @handler :longx_sentry

  @type status :: %{
          enabled: boolean,
          dsn: String.t() | nil,
          environment: String.t(),
          release: String.t()
        }

  @doc "Whether events go out right now."
  @spec enabled?() :: boolean
  def enabled?, do: Sentry.get_dsn() != nil

  @doc "What the settings page shows: on or off, the DSN masked, environment and release."
  @spec status() :: status
  def status do
    %{
      enabled: enabled?(),
      dsn: dsn_setting() && mask(dsn_setting()),
      environment: to_string(Sentry.Config.environment_name()),
      release: Sentry.Config.release() || Longx.Upgrade.current_version()
    }
  end

  @doc "The DSN as saved, or nil."
  @spec dsn_setting() :: String.t() | nil
  def dsn_setting do
    case Longx.System.get_setting(@key) do
      {:ok, %{value: dsn}} when is_binary(dsn) and dsn != "" -> dsn
      _ -> nil
    end
  end

  @doc """
  Saves the DSN and applies it: reporting is on from now. `""` clears it
  and turns reporting off. A DSN is `https://<key>@<host>/<project>`.
  """
  @spec set_dsn(String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def set_dsn(dsn) when is_binary(dsn) do
    case String.trim(dsn) do
      "" ->
        with {:ok, _} <- Longx.System.put_setting(@key, "") do
          apply_dsn(nil)
          {:ok, nil}
        end

      trimmed ->
        with :ok <- validate(trimmed),
             {:ok, _} <- Longx.System.put_setting(@key, trimmed) do
          apply_dsn(trimmed)
          {:ok, trimmed}
        end
    end
  end

  defp validate(dsn) do
    case URI.parse(dsn) do
      %URI{scheme: scheme, userinfo: key, host: host, path: "/" <> project}
      when scheme in ["http", "https"] and is_binary(key) and key != "" and is_binary(host) and
             host != "" and project != "" ->
        :ok

      _ ->
        {:error, "这不是一个 Sentry DSN（形如 https://<key>@<host>/<project>）"}
    end
  end

  @doc "A boot: the saved DSN applied (the SDK starts with none)."
  @spec configure_from_settings() :: :ok
  def configure_from_settings do
    apply_dsn(dsn_setting())
  rescue
    # the table is not there yet on a first boot before the migrations ran
    e -> Logger.warning("sentry: could not read the setting: #{Exception.message(e)}")
  end

  defp apply_dsn(dsn) do
    Sentry.put_config(:dsn, dsn)
    if dsn, do: attach_handler()
    :ok
  end

  # crash reports from every process, once
  defp attach_handler do
    case :logger.add_handler(@handler, Sentry.LoggerHandler, %{
           config: %{capture_metadata: [:file, :line], capture_excluded_domains: [:cowboy]}
         }) do
      :ok ->
        :ok

      {:error, {:already_exist, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning("sentry: could not attach the handler: #{inspect(reason)}")
    end
  end

  @doc """
  `before_send`: what never leaves. A client's own protocol trouble at the
  web server — a connection opened and never used (Bandit's "Read timeout"),
  a malformed request, a socket closed mid-way — is logged by Bandit as an
  error with a crash reason, which the logger handler would report; it is
  not a bug of ours. Everything else goes.
  """
  @spec before_send(Sentry.Event.t()) :: Sentry.Event.t() | false
  def before_send(%Sentry.Event{original_exception: %Bandit.HTTPError{}}), do: false
  def before_send(%Sentry.Event{original_exception: %Bandit.TransportError{}}), do: false
  def before_send(%Sentry.Event{} = event), do: event

  @doc "A test event from the settings page; `{:ok, id}` once the server took it."
  @spec send_test() :: {:ok, String.t()} | {:error, String.t()}
  def send_test do
    if enabled?() do
      case Sentry.capture_message("Longx test event",
             level: :info,
             result: :sync,
             tags: %{source: "settings"}
           ) do
        {:ok, id} -> {:ok, id}
        :ignored -> {:error, "the event was ignored"}
        :unsampled -> {:error, "the event was not sampled"}
        :excluded -> {:error, "the event was excluded"}
        {:error, %Sentry.ClientError{} = e} -> {:error, Exception.message(e)}
      end
    else
      {:error, "no DSN set"}
    end
  end

  @doc "One of the server's own faults (`Longx.System.Faults`), as a warning event."
  @spec fault(atom, String.t() | nil, String.t()) :: :ok
  def fault(kind, where, detail) do
    if enabled?() do
      Sentry.capture_message("#{kind}: #{String.slice(detail, 0, 200)}",
        level: :warning,
        tags: %{fault: to_string(kind), where: where || ""},
        extra: %{detail: detail},
        fingerprint: ["fault", to_string(kind)]
      )
    end

    :ok
  end

  @doc "A turn that ended `failed` (the Tracker), as an error event tagged with the thread and turn."
  @spec turn_failed(String.t(), String.t(), String.t() | nil) :: :ok
  def turn_failed(thread_id, turn_id, error) do
    if enabled?() and not providers_own?(error) do
      Sentry.capture_message("turn failed: #{String.slice(error || "no details", 0, 200)}",
        level: :error,
        tags: %{thread: thread_id, turn: turn_id},
        extra: %{error: error},
        fingerprint: ["turn_failed", first_words(error)]
      )
    end

    :ok
  end

  # a provider refusing the prompt (a content filter) or the account (a spent
  # quota, an unpaid bill) is its word, not a bug of ours — the person sees it on
  # the page; three of them once filled the issue list
  @providers_own ~r/usage policy|invalid prompt|content_policy|flagged as|quota|exhaust|insufficient|balance|credit|billing|payment|exceeded your/i
  defp providers_own?(error) when is_binary(error), do: Regex.match?(@providers_own, error)
  defp providers_own?(_), do: false

  # failures of one kind group together: the message up to the first colon
  defp first_words(nil), do: "unknown"
  defp first_words(error), do: error |> String.split(":", parts: 2) |> hd() |> String.slice(0, 60)

  defp mask(dsn) do
    case URI.parse(dsn) do
      %URI{userinfo: key} = uri when is_binary(key) -> URI.to_string(%{uri | userinfo: "***"})
      _ -> "***"
    end
  end
end
