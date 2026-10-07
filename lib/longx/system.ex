defmodule Longx.System do
  @moduledoc "Node-level facts the SPA asks for: the version and its upgrade, the knowledge, the kernel settings; plus the encrypted settings store."

  use Ash.Domain, otp_app: :longx, extensions: [AshGraphql.Domain]

  graphql do
    # every error at the top level of the response, for calls and records alike
    root_level_errors? true

    queries do
      action Longx.System.Status, :list_directory, :list_directory
      action Longx.System.Status, :knowledge_docs, :knowledge_docs
      action Longx.System.Status, :knowledge_read, :knowledge_read
      action Longx.System.Status, :agent_settings, :agent_settings
      action Longx.System.Status, :command_guard_status, :command_guard_status
      action Longx.System.Status, :public_url, :public_url
      action Longx.System.Status, :dependencies, :dependencies
      action Longx.System.Status, :file_rules, :file_rules
      action Longx.System.Status, :sentry_status, :sentry_status
      action Longx.System.Status, :upgrade_status, :upgrade_status
      action Longx.System.Status, :gateway_requests, :gateway_requests
      action Longx.System.Status, :recent_faults, :recent_faults
      action Longx.System.Status, :running_commands, :running_commands
      action Longx.System.Status, :browser_settings, :browser_settings
      action Longx.System.Status, :browser_status, :browser_status
      action Longx.System.Status, :computer_settings, :computer_settings
      action Longx.System.Status, :computer_connection, :computer_connection
      action Longx.System.Status, :computer_devices, :computer_devices
      action Longx.System.Status, :computer_aliases, :computer_aliases
      action Longx.System.Status, :tls_status, :tls_status
      action Longx.System.Status, :tls_providers, :tls_providers
      action Longx.System.Status, :tls_resolution, :tls_resolution
    end

    mutations do
      action Longx.System.Status, :create_directory, :create_directory
      action Longx.System.Status, :knowledge_write, :knowledge_write
      action Longx.System.Status, :knowledge_delete, :knowledge_delete
      action Longx.System.Status, :set_agent_settings, :set_agent_settings
      action Longx.System.Status, :check_dependencies, :check_dependencies
      action Longx.System.Status, :set_public_url, :set_public_url
      action Longx.System.Status, :set_file_rules, :set_file_rules
      action Longx.System.Status, :set_sentry_dsn, :set_sentry_dsn
      action Longx.System.Status, :sentry_test, :sentry_test
      action Longx.System.Status, :upgrade_check, :upgrade_check
      action Longx.System.Status, :upgrade_apply, :upgrade_apply
      action Longx.System.Status, :set_github_token, :set_github_token
      action Longx.System.Status, :kill_command, :kill_command
      action Longx.System.Status, :browser_install, :browser_install
      action Longx.System.Status, :computer_configure, :computer_configure
      action Longx.System.Status, :computer_connect, :computer_connect
      action Longx.System.Status, :computer_disconnect, :computer_disconnect
      action Longx.System.Status, :computer_delete, :computer_delete
      action Longx.System.Status, :computer_set_alias, :computer_set_alias
      action Longx.System.Status, :computer_delete_alias, :computer_delete_alias
      action Longx.System.Status, :computer_set_default, :computer_set_default
      action Longx.System.Status, :set_browser_private_network, :set_browser_private_network
      action Longx.System.Status, :set_tls, :set_tls
      action Longx.System.Status, :tls_issue, :tls_issue
      action Longx.System.Status, :tls_disable, :tls_disable
    end
  end

  resources do
    resource Longx.System.Status do
      define :list_directory, action: :list_directory
      define :create_directory, action: :create_directory
      define :command_guard_status, action: :command_guard_status
    end

    resource Longx.System.Setting do
      define :put_setting, action: :put, args: [:key, :value]
      define :get_setting, action: :by_key, args: [:key]
      define :delete_setting, action: :destroy
    end
  end

  @public_url_key "public_url"

  @doc """
  The address the outside reaches Longx at — what a tool hands a third
  party that must send the person back (`Longx.Agent.Context.ask/2`'s
  callback): the setting (`set_public_url/1`), else `LONGX_PUBLIC_URL`, else
  the https address Longx serves itself (`Longx.Tls.https_url/0` — an https
  callback needs nothing pasted back), else where the last browser connected
  from (`LongxWeb.Origins`), else the endpoint's own URL.
  """
  @spec public_url() :: String.t()
  def public_url do
    case get_setting(@public_url_key) do
      {:ok, %{value: url}} when is_binary(url) and url != "" ->
        url

      _ ->
        env_public_url() || Longx.Tls.https_url() || LongxWeb.Origins.last() ||
          LongxWeb.Endpoint.url()
    end
  end

  # a container sets the address once, in its environment (a compose file),
  # instead of in the settings page
  defp env_public_url do
    case System.get_env("LONGX_PUBLIC_URL") do
      url when is_binary(url) and url != "" -> url |> String.trim() |> String.trim_trailing("/")
      _ -> nil
    end
  end

  @doc "The saved address alone (nil when Longx decides for itself)."
  @spec public_url_setting() :: String.t() | nil
  def public_url_setting do
    case get_setting(@public_url_key) do
      {:ok, %{value: url}} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  @doc "Sets the outside address (`\"\"` clears it); an http(s) URL with a host."
  @spec set_public_url(String.t()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def set_public_url(url) when is_binary(url) do
    case String.trim(url) do
      "" ->
        with {:ok, _} <- put_setting(@public_url_key, ""), do: {:ok, nil}

      trimmed ->
        case URI.parse(trimmed) do
          %URI{scheme: scheme, host: host}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            clean = String.trim_trailing(trimmed, "/")
            with {:ok, _} <- put_setting(@public_url_key, clean), do: {:ok, clean}

          _ ->
            {:error, "an address is http(s)://host[:port], like http://192.168.2.129:7788"}
        end
    end
  end
end
