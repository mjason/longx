defmodule LongxWeb.TlsRpcTest do
  @moduledoc """
  The HTTPS page on the wire: the DNS providers, the settings saved with the
  provider's variables (named back, never returned), the errors on the field
  they concern, an issuance through the tool (a script standing in for
  longx-cert) and turning HTTPS off.
  """
  use LongxWeb.ConnCase, async: false

  @moduletag :capture_log

  alias Longx.Tls.{Listener, Manager}
  alias Longx.Test.Certs

  @fake Path.expand("../../support/fake_longx_cert.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "longx-tls-rpc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:longx, Longx.Tls, [])
    Application.put_env(:longx, Longx.Tls, Keyword.merge(previous, dir: Path.join(root, "tls")))
    System.put_env("LONGX_CERT", @fake)
    System.put_env("FAKE_CERT_RESULT", Path.join(root, "result.json"))

    on_exit(fn ->
      Listener.stop()
      Longx.Tls.publish(nil, false)
      Application.put_env(:longx, Longx.Tls, previous)
      Enum.each(~w(LONGX_CERT FAKE_CERT_RESULT), &System.delete_env/1)
      File.rm_rf!(root)
      Manager.reset()
    end)

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    %{root: root, port: port}
  end

  test "the providers, each with the variables it reads", %{conn: conn} do
    assert %{"success" => true, "data" => %{"providers" => providers}} =
             rpc(conn, "tls_providers", %{"fields" => ["providers"]})

    tencent = Enum.find(providers, &(&1["code"] == "tencentcloud"))
    assert tencent["name"] == "Tencent Cloud DNS"

    assert Enum.map(tencent["credentials"], & &1["name"]) == [
             "TENCENTCLOUD_SECRET_ID",
             "TENCENTCLOUD_SECRET_KEY"
           ]
  end

  test "settings saved with the provider's variables: named back, never returned", %{
    conn: conn,
    port: port
  } do
    assert %{"success" => true, "data" => status} =
             rpc(conn, "set_tls", %{
               "input" => %{
                 "enabled" => false,
                 "domains" => ["lx.example.test"],
                 "provider" => "tencentcloud",
                 "port" => port,
                 "env" => [
                   %{"name" => "TENCENTCLOUD_SECRET_ID", "value" => "AKID-4711"},
                   %{"name" => "TENCENTCLOUD_SECRET_KEY", "value" => "very-secret-4711"}
                 ]
               }
             })

    assert %{
             "domains" => ["lx.example.test"],
             "provider" => "tencentcloud",
             "port" => ^port,
             "envSet" => ["TENCENTCLOUD_SECRET_ID", "TENCENTCLOUD_SECRET_KEY"],
             "stage" => "idle",
             "serving" => false,
             "toolVersion" => _
           } = status

    refute Jason.encode!(status) =~ "AKID-4711"
    refute Jason.encode!(status) =~ "very-secret-4711"

    # an empty value keeps the secret
    assert %{"success" => true} =
             rpc(conn, "set_tls", %{
               "input" => %{"env" => [%{"name" => "TENCENTCLOUD_SECRET_KEY", "value" => ""}]}
             })

    assert Longx.Tls.env()["TENCENTCLOUD_SECRET_KEY"] == "very-secret-4711"

    assert %{"success" => true, "data" => read} = rpc(conn, "tls_status", %{})
    assert read["envSet"] == ["TENCENTCLOUD_SECRET_ID", "TENCENTCLOUD_SECRET_KEY"]
    refute Jason.encode!(read) =~ "AKID-4711"
    refute Jason.encode!(read) =~ "very-secret-4711"
  end

  test "the TXT check's resolvers and wait are saved; where the typed names point comes apart", %{
    conn: conn
  } do
    assert %{"success" => true, "data" => status} =
             rpc(conn, "set_tls", %{
               "input" => %{
                 "resolvers" => ["223.5.5.5"],
                 "propagationCheck" => false,
                 "propagationWait" => 90
               }
             })

    assert %{
             "resolvers" => ["223.5.5.5:53"],
             "propagationCheck" => false,
             "propagationWait" => 90
           } =
             status

    assert %{"success" => false, "errors" => [%{"fields" => ["resolvers"]}]} =
             rpc(conn, "set_tls", %{"input" => %{"resolvers" => ["dns.example.com"]}})

    # the suite's lookups resolve nothing (config/test.exs): the shape, no network
    assert %{
             "success" => true,
             "data" => %{
               "fakeIp" => false,
               "checkResolvers" => ["223.5.5.5:53"],
               "resolution" => [
                 %{
                   "domain" => "lx.example.test",
                   "addresses" => [],
                   "local" => [],
                   "here" => false
                 }
               ]
             }
           } =
             rpc(conn, "tls_resolution", %{
               "input" => %{"domains" => ["lx.example.test", "*.lx.example.test"]}
             })
  end

  test "an error names its field", %{conn: conn} do
    assert %{"success" => false, "errors" => [%{"fields" => ["provider"]}]} =
             rpc(conn, "set_tls", %{"input" => %{"provider" => "no-such-dns"}})

    assert %{"success" => false, "errors" => [%{"fields" => ["env"], "message" => message}]} =
             rpc(conn, "set_tls", %{
               "input" => %{
                 "provider" => "tencentcloud",
                 "env" => [%{"name" => "LD_PRELOAD", "value" => "x.so"}]
               }
             })

    assert message =~ "LD_PRELOAD"

    assert %{"success" => false, "errors" => [%{"fields" => ["domains"]}]} =
             rpc(conn, "tls_issue", %{})
  end

  test "an issuance through the tool; then HTTPS off", %{conn: conn, root: root, port: port} do
    cert = Certs.self_signed()

    File.write!(
      Path.join(root, "result.json"),
      Jason.encode!(%{
        "ok" => true,
        "certificate" => cert.cert,
        "private_key" => cert.key,
        "domains" => ["lx.example.test"],
        "not_after" => DateTime.utc_now() |> DateTime.add(90, :day) |> DateTime.to_iso8601(),
        "serial" => "abc",
        "account" => %{"directory" => "d", "key" => "k", "uri" => "u"}
      })
    )

    assert %{"success" => true} =
             rpc(conn, "set_tls", %{
               "input" => %{
                 "enabled" => true,
                 "domains" => ["lx.example.test"],
                 "provider" => "tencentcloud",
                 "port" => port,
                 "env" => [
                   %{"name" => "TENCENTCLOUD_SECRET_ID", "value" => "id"},
                   %{"name" => "TENCENTCLOUD_SECRET_KEY", "value" => "key"}
                 ]
               }
             })

    Phoenix.PubSub.subscribe(Longx.PubSub, Manager.topic())
    assert %{"success" => true, "data" => %{"stage" => "issuing"}} = rpc(conn, "tls_issue", %{})
    assert_receive {:tls, %{stage: :idle}}, 15_000

    assert %{"success" => true, "data" => status} = rpc(conn, "tls_status", %{})

    assert %{
             "serving" => true,
             "url" => url,
             "certificate" => %{"domains" => ["lx.example.test"], "notAfter" => not_after}
           } = status

    assert url == "https://lx.example.test:#{port}"
    assert is_binary(not_after)

    assert %{"success" => true, "data" => %{"enabled" => false, "serving" => false, "url" => nil}} =
             rpc(conn, "tls_disable", %{})
  end
end
