defmodule Longx.Tls.DnsTest do
  @moduledoc """
  Looking a name up the way the world sees it, whatever this machine's DNS
  does: a proxy's fake-ip resolver (198.18.0.0/15) answers every name with
  an address of its own, so the public resolvers are asked directly over
  UDP, and over DoH when UDP gets nothing.
  """
  use ExUnit.Case, async: false

  alias Longx.Tls.Dns
  alias Longx.Test.FakeDns

  setup do
    previous = Application.get_env(:longx, Longx.Tls, [])
    on_exit(fn -> Application.put_env(:longx, Longx.Tls, previous) end)
    %{previous: previous}
  end

  defp configure(previous, opts),
    do: Application.put_env(:longx, Longx.Tls, Keyword.merge(previous, opts))

  test "a proxy's fake-ip addresses are recognised" do
    assert Dns.fake_ip?("198.18.0.1")
    assert Dns.fake_ip?("198.19.255.254")
    refute Dns.fake_ip?("198.20.0.1")
    refute Dns.fake_ip?("192.168.2.70")
    refute Dns.fake_ip?("not an address")
  end

  test "the public resolvers are asked directly over UDP", ctx do
    {_pid, port} = FakeDns.start(%{"lx.example.test" => "192.168.2.70"})
    configure(ctx.previous, public_dns: [{{127, 0, 0, 1}, port}], doh_url: nil)

    assert Dns.public_a("lx.example.test") == ["192.168.2.70"]
    assert Dns.public_a("missing.example.test") == []
  end

  test "UDP answered by nobody (a blocked resolver): DoH instead", ctx do
    {_pid, port} = FakeDns.start(%{}, silent: true)
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/resolve", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{"name" => "lx.example.test", "type" => "1"}

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "Status" => 0,
          "Answer" => [
            %{"name" => "lx.example.test.", "type" => 5, "data" => "alias.example.test."},
            %{"name" => "alias.example.test.", "type" => 1, "data" => "192.168.2.70"}
          ]
        })
      )
    end)

    configure(ctx.previous,
      public_dns: [{{127, 0, 0, 1}, port}],
      doh_url: "http://localhost:#{bypass.port}/resolve",
      dns_timeout: 300
    )

    assert Dns.public_a("lx.example.test") == ["192.168.2.70"]
  end

  test "this machine's own lookup goes through the configured function (the system resolver by default)",
       ctx do
    configure(ctx.previous, system_lookup: fn "lx.example.test" -> ["198.18.0.7"] end)
    assert Dns.system_a("lx.example.test") == ["198.18.0.7"]
  end
end
