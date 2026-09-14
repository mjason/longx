defmodule Longx.System do
  @moduledoc "Node-level facts the SPA asks for: sandbox availability (more to come: version, updates)."

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
    end
  end

  resources do
    resource Longx.System.Status do
      define :sandbox_status, action: :sandbox
      define :list_directory, action: :list_directory
      define :create_directory, action: :create_directory
    end
  end
end
