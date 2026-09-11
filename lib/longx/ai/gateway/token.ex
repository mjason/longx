defmodule Longx.AI.Gateway.Token do
  @moduledoc """
  The bearer token codex must present to `/ai/v1/*`.

  Generated once per BEAM boot and handed to the app-server through the
  `LONGX_GATEWAY_TOKEN` environment variable when we spawn it; nothing else
  ever needs it, so it is never persisted.
  """

  @key {__MODULE__, :token}
  @env_var "LONGX_GATEWAY_TOKEN"

  @doc "Name of the env var the codex provider config reads the token from."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "Generates and stores a fresh token. Called from the application start."
  @spec generate!() :: String.t()
  def generate! do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    :persistent_term.put(@key, token)
    token
  end

  @spec current() :: String.t()
  def current do
    case :persistent_term.get(@key, nil) do
      nil -> generate!()
      token -> token
    end
  end

  @spec valid?(String.t() | nil) :: boolean
  def valid?(candidate) when is_binary(candidate),
    do: Plug.Crypto.secure_compare(candidate, current())

  def valid?(_), do: false
end
