defmodule Longx.System do
  @moduledoc "Node-level facts the SPA asks for: sandbox availability, the global memory, the version and its upgrade; plus the encrypted settings store."

  use Ash.Domain, otp_app: :longx, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Longx.System.Status do
      rpc_action :sandbox_status, :sandbox
      rpc_action :probe_sandbox, :probe_sandbox
      rpc_action :list_codex_processes, :list_codex_processes
      rpc_action :list_directory, :list_directory
      rpc_action :create_directory, :create_directory
      rpc_action :memory_index, :memory_index
      rpc_action :memory_write_index, :memory_write_index
      rpc_action :memory_notes, :memory_notes
      rpc_action :memory_search, :memory_search
      rpc_action :memory_delete_note, :memory_delete_note
      rpc_action :memory_status, :memory_status
      rpc_action :memory_set_auto_extract, :memory_set_auto_extract
      rpc_action :memory_run, :memory_run
      rpc_action :upgrade_status, :upgrade_status
      rpc_action :upgrade_check, :upgrade_check
      rpc_action :upgrade_apply, :upgrade_apply
      rpc_action :set_github_token, :set_github_token
      rpc_action :pairing_code, :pairing_code
    end

    resource Longx.System.Device do
      rpc_action :list_devices, :list
      rpc_action :revoke_device, :destroy
    end
  end

  resources do
    resource Longx.System.Status do
      define :sandbox_status, action: :sandbox
      define :list_directory, action: :list_directory
      define :create_directory, action: :create_directory
    end

    resource Longx.System.Setting do
      define :put_setting, action: :put, args: [:key, :value]
      define :get_setting, action: :by_key, args: [:key]
      define :delete_setting, action: :destroy
    end

    resource Longx.System.Device do
      define :list_devices, action: :list
      define :revoke_device, action: :destroy
      define :device_by_token_hash, action: :by_token_hash, args: [:token_hash]
      define :device_seen, action: :seen
    end
  end

  ## Devices (the phone app)

  @doc "A fresh pairing code for the settings page to show (`Longx.System.Pairing`)."
  @spec pairing_code() :: %{code: String.t(), expires_at: DateTime.t()}
  def pairing_code, do: Longx.System.Pairing.new_code()

  @doc """
  Pairs a phone: the current code spent, a `Device` row created, the token
  (the only time it is seen; the row keeps its hash) returned with it.
  """
  @spec pair_device(String.t(), map) ::
          {:ok, %{device: Longx.System.Device.t(), token: String.t()}}
          | {:error, :invalid_code | term}
  def pair_device(code, attrs) do
    with :ok <- Longx.System.Pairing.redeem(code) do
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      case Ash.create(Longx.System.Device, Map.put(attrs, :token_hash, token_hash(token))) do
        {:ok, device} -> {:ok, %{device: device, token: token}}
        {:error, _} = error -> error
      end
    else
      :error -> {:error, :invalid_code}
    end
  end

  @doc "The device behind a bearer token; its `last_seen_at` is touched at most once a minute."
  @spec authenticate_device(String.t()) :: {:ok, Longx.System.Device.t()} | :error
  def authenticate_device(token) when is_binary(token) do
    case device_by_token_hash(token_hash(token)) do
      {:ok, %Longx.System.Device{} = device} -> {:ok, touch_seen(device)}
      _ -> :error
    end
  end

  def authenticate_device(_), do: :error

  defp touch_seen(%Longx.System.Device{last_seen_at: seen} = device) do
    stale? = is_nil(seen) or DateTime.diff(DateTime.utc_now(), seen, :second) > 60
    if stale?, do: device_seen!(device), else: device
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
