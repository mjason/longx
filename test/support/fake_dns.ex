defmodule Longx.Test.FakeDns do
  @moduledoc """
  A tiny DNS server over UDP for tests: answers A queries for the names it
  was given, NXDOMAIN for the rest — or nothing at all (`silent: true`), to
  play a resolver that is blocked. `start/2` answers `{pid, port}`.
  """

  @spec start(%{String.t() => String.t()}, keyword) :: {pid, :inet.port_number()}
  def start(records, opts \\ []) do
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(socket)
        send(parent, {:fake_dns, port})
        loop(socket, records, Keyword.get(opts, :silent, false))
      end)

    receive do
      {:fake_dns, port} -> {pid, port}
    after
      2_000 -> raise "the fake DNS server did not start"
    end
  end

  defp loop(socket, records, silent) do
    {:ok, {ip, port, packet}} = :gen_udp.recv(socket, 0)
    unless silent, do: :gen_udp.send(socket, ip, port, answer(packet, records))
    loop(socket, records, silent)
  end

  defp answer(<<id::16, _flags::16, 1::16, _counts::48, rest::binary>>, records) do
    {labels, size} = qname(rest, [], 0)
    <<question::binary-size(size + 4), _::binary>> = rest
    <<_::binary-size(size), qtype::16, _::binary>> = rest

    case {qtype, Map.fetch(records, Enum.join(labels, "."))} do
      {1, {:ok, ip}} ->
        {:ok, {a, b, c, d}} = :inet.parse_address(String.to_charlist(ip))
        record = <<0xC00C::16, 1::16, 1::16, 60::32, 4::16, a, b, c, d>>
        <<id::16, 0x8180::16, 1::16, 1::16, 0::16, 0::16>> <> question <> record

      _ ->
        <<id::16, 0x8183::16, 1::16, 0::16, 0::16, 0::16>> <> question
    end
  end

  # the question's name: its labels and how many bytes it takes
  defp qname(<<0, _::binary>>, acc, size), do: {Enum.reverse(acc), size + 1}

  defp qname(<<len, label::binary-size(len), rest::binary>>, acc, size),
    do: qname(rest, [label | acc], size + len + 1)
end

defmodule Longx.Test.Dns do
  @moduledoc "The system lookups the suite runs with (`config/test.exs`): no name resolves."
  def nothing(_name), do: []
end
