defmodule Longx.Credentials.Credential.Status do
  @moduledoc """
  The one word the list and the agent see: `:ready` (usable now),
  `:expired` (the token is past its time — the refresh worker will try;
  a login if it cannot), `:needs_login` (no value yet), `:error` (the
  last refresh or request failed; the message is `last_error`).
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _ctx),
    do: [
      :kind,
      :expires_at,
      :refreshed_at,
      :last_error,
      :last_error_at,
      :encrypted_secret,
      :encrypted_access_token
    ]

  @impl true
  def calculate(records, _opts, _ctx), do: Enum.map(records, &of/1)

  @doc "The status of one loaded row."
  @spec of(map) :: :ready | :expired | :needs_login | :error
  def of(%{kind: :api_key} = cred) do
    cond do
      is_nil(cred.encrypted_secret) -> :needs_login
      error?(cred) -> :error
      true -> :ready
    end
  end

  def of(cred) do
    cond do
      is_nil(cred.encrypted_access_token) -> :needs_login
      error?(cred) -> :error
      expired?(cred.expires_at) -> :expired
      true -> :ready
    end
  end

  # an error after the last successful refresh (a store_tokens clears it)
  defp error?(%{last_error: error}) when is_binary(error) and error != "", do: true
  defp error?(_), do: false

  defp expired?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) != :gt
  defp expired?(_), do: false
end
