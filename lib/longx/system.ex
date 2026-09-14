defmodule Longx.System do
  @moduledoc "Node-level facts the SPA asks for: sandbox availability, the global memory, the version and its upgrade; plus the encrypted settings store."

  use Ash.Domain, otp_app: :longx, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Longx.System.Status do
      rpc_action :sandbox_status, :sandbox
      rpc_action :probe_sandbox, :probe_sandbox
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
  end
end
