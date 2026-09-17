defmodule Longx.System do
  @moduledoc "Node-level facts the SPA asks for: the version and its upgrade, the knowledge, the kernel settings; plus the encrypted settings store."

  use Ash.Domain, otp_app: :longx, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Longx.System.Status do
      rpc_action :list_directory, :list_directory
      rpc_action :create_directory, :create_directory
      rpc_action :knowledge_docs, :knowledge_docs
      rpc_action :knowledge_read, :knowledge_read
      rpc_action :knowledge_write, :knowledge_write
      rpc_action :knowledge_delete, :knowledge_delete
      rpc_action :agent_settings, :agent_settings
      rpc_action :set_agent_settings, :set_agent_settings
      rpc_action :public_url, :public_url
      rpc_action :dependencies, :dependencies
      rpc_action :check_dependencies, :check_dependencies
      rpc_action :set_public_url, :set_public_url
      rpc_action :upgrade_status, :upgrade_status
      rpc_action :upgrade_check, :upgrade_check
      rpc_action :upgrade_apply, :upgrade_apply
      rpc_action :set_github_token, :set_github_token
      rpc_action :gateway_requests, :gateway_requests
      rpc_action :browser_settings, :browser_settings
      rpc_action :set_browser_private_network, :set_browser_private_network
    end
  end

  resources do
    resource Longx.System.Status do
      define :list_directory, action: :list_directory
      define :create_directory, action: :create_directory
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
  callback): the setting (`set_public_url/1`), else where the last browser
  connected from (`LongxWeb.Origins`), else the endpoint's own URL.
  """
  @spec public_url() :: String.t()
  def public_url do
    case get_setting(@public_url_key) do
      {:ok, %{value: url}} when is_binary(url) and url != "" -> url
      _ -> LongxWeb.Origins.last() || LongxWeb.Endpoint.url()
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
