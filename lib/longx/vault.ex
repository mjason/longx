defmodule Longx.Vault do
  @moduledoc """
  Cloak vault for encrypting secrets at rest (provider API keys via `AshCloak`).

  The key comes from `config :longx, Longx.Vault` — a fixed dev/test key in
  `config/{dev,test}.exs` and `LONGX_CLOAK_KEY` (base64, 32 bytes) in
  `config/runtime.exs` for prod. Generate one with
  `:crypto.strong_rand_bytes(32) |> Base.encode64()`.
  """
  use Cloak.Vault, otp_app: :longx
end
