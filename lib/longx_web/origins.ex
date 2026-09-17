defmodule LongxWeb.Origins do
  @moduledoc """
  Where the last browser reached Longx from (scheme, host, port of the
  socket connection) — the address to hand a third party that must send
  the person back here (`Longx.System.public_url/0`), when nobody set one.
  A person on another machine reaches `192.168.2.129:7788`, never the
  endpoint's `localhost`.
  """

  @key {__MODULE__, :last}

  @spec remember(URI.t() | nil) :: :ok
  def remember(%URI{scheme: scheme, host: host} = uri)
      when is_binary(scheme) and is_binary(host) do
    :persistent_term.put(@key, URI.to_string(%URI{scheme: scheme, host: host, port: uri.port}))
  end

  def remember(_uri), do: :ok

  @spec last() :: String.t() | nil
  def last, do: :persistent_term.get(@key, nil)

  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@key)
    :ok
  end
end
