defmodule Longx.System do
  @moduledoc "Node-level facts the SPA asks for: sandbox availability (more to come: version, updates)."

  use Ash.Domain, otp_app: :longx, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Longx.System.Status do
      rpc_action :sandbox_status, :sandbox
      rpc_action :list_directory, :list_directory
    end
  end

  resources do
    resource Longx.System.Status do
      define :sandbox_status, action: :sandbox
      define :list_directory, action: :list_directory
    end
  end
end
