defmodule Longx.Tls.ManagerTest do
  @moduledoc """
  Obtaining and renewing the certificate: the tool (a script standing in for
  longx-cert, fetched first when it is not there) is handed the request on
  stdin, what it answers is stored, and the HTTPS listener serves it; a
  failure keeps what was there.
  """
  use Longx.DataCase, async: false
  use Oban.Testing, repo: Longx.Repo, engine: Oban.Engines.Lite, notifier: Oban.Notifiers.PG

  @moduletag :capture_log

  alias Longx.Tls
  alias Longx.Tls.{Listener, Manager, Tool}
  alias Longx.Test.Certs

  @fake Path.expand("../../support/fake_longx_cert.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "longx-tls-manager-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:longx, Longx.Tls, [])

    Application.put_env(
      :longx,
      Longx.Tls,
      Keyword.merge(previous, dir: Path.join(root, "tls"), tool_dir: Path.join(root, "tool"))
    )

    System.put_env("LONGX_CERT", @fake)
    System.put_env("FAKE_CERT_REQUEST", Path.join(root, "request.json"))
    System.put_env("FAKE_CERT_RESULT", Path.join(root, "result.json"))

    on_exit(fn ->
      Listener.stop()
      # the listener published its address: public_url and the redirect read it
      Tls.publish(nil, false)
      Application.put_env(:longx, Longx.Tls, previous)

      Enum.each(
        ~w(LONGX_CERT FAKE_CERT_REQUEST FAKE_CERT_RESULT FAKE_CERT_EXIT),
        &System.delete_env/1
      )

      File.rm_rf!(root)
      Manager.reset()
    end)

    Phoenix.PubSub.subscribe(Longx.PubSub, Manager.topic())
    %{root: root, port: free_port()}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp configure(ctx) do
    {:ok, _} =
      Tls.save(%{
        enabled: true,
        domains: ["lx.example.test"],
        provider: "tencentcloud",
        port: ctx.port,
        env: %{"TENCENTCLOUD_SECRET_ID" => "AKID", "TENCENTCLOUD_SECRET_KEY" => "secret"}
      })
  end

  defp answer(ctx, cert, overrides \\ %{}) do
    result =
      Map.merge(
        %{
          "ok" => true,
          "certificate" => cert.cert,
          "private_key" => cert.key,
          "issuer" => cert.cert,
          "domains" => ["lx.example.test"],
          "not_before" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "not_after" => DateTime.utc_now() |> DateTime.add(90, :day) |> DateTime.to_iso8601(),
          "serial" => Integer.to_string(cert.serial, 16),
          "account" => %{
            "directory" => "https://acme-v02.api.letsencrypt.org/directory",
            "key" => "PEM",
            "uri" => "https://ca/acct/7"
          }
        },
        overrides
      )

    File.write!(Path.join(ctx.root, "result.json"), Jason.encode!(result))
  end

  defp flush_status do
    receive do
      {:tls, _} -> flush_status()
    after
      0 -> :ok
    end
  end

  defp settled do
    assert_receive {:tls, %{stage: stage} = status} when stage in [:idle, :failed], 15_000
    status
  end

  test "the tool is handed the request; its certificate is stored and served on the port", ctx do
    configure(ctx)
    cert = Certs.self_signed()
    answer(ctx, cert)

    assert :ok = Manager.issue()
    assert %{stage: :idle, error: nil} = settled()

    # what the tool read on stdin
    request = ctx.root |> Path.join("request.json") |> File.read!() |> Jason.decode!()

    assert %{
             "provider" => "tencentcloud",
             "domains" => ["lx.example.test"],
             "env" => %{"TENCENTCLOUD_SECRET_ID" => "AKID", "TENCENTCLOUD_SECRET_KEY" => "secret"}
           } = request

    assert %{domains: ["lx.example.test"]} = Tls.certificate()
    assert Listener.port() == ctx.port
    assert Certs.served_serial(ctx.port) == cert.serial
    assert Tls.https_url() == "https://lx.example.test:#{ctx.port}"

    # a renewal: the same listener, the next connection gets the new certificate
    renewed = Certs.self_signed()
    answer(ctx, renewed)
    assert :ok = Manager.issue()
    assert %{stage: :idle} = settled()
    assert Certs.served_serial(ctx.port) == renewed.serial
    # the account the first run returned went back to the tool
    assert %{"account" => %{"uri" => "https://ca/acct/7"}} =
             ctx.root |> Path.join("request.json") |> File.read!() |> Jason.decode!()
  end

  test "a failure is shown and replaces nothing", ctx do
    configure(ctx)
    first = Certs.self_signed()
    answer(ctx, first)
    :ok = Manager.issue()
    assert %{stage: :idle} = settled()

    File.write!(
      Path.join(ctx.root, "result.json"),
      ~s({"ok":false,"error":"provider tencentcloud: some credentials information are missing"})
    )

    System.put_env("FAKE_CERT_EXIT", "1")
    :ok = Manager.issue()
    assert %{stage: :failed, error: error} = settled()
    assert error =~ "some credentials information are missing"
    assert Certs.served_serial(ctx.port) == first.serial
    assert Manager.status().error == error
  end

  test "nothing to do before the names and the provider are set" do
    assert {:error, :not_configured} = Manager.issue()
  end

  test "the tool is downloaded first when none is there", ctx do
    System.delete_env("LONGX_CERT")
    configure(ctx)
    answer(ctx, Certs.self_signed())

    archive = Path.join(ctx.root, "tool.tar.gz")
    exe = Path.join(ctx.root, "longx-cert")
    File.cp!(@fake, exe)

    :ok =
      :erl_tar.create(String.to_charlist(archive), [{~c"longx-cert", String.to_charlist(exe)}], [
        :compressed
      ])

    sha = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)

    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/longx-cert.tar.gz", fn conn ->
      Plug.Conn.send_resp(conn, 200, File.read!(archive))
    end)

    Application.put_env(
      :longx,
      Longx.Tls,
      Keyword.merge(Application.get_env(:longx, Longx.Tls),
        download_url: "http://localhost:#{bypass.port}/longx-cert.tar.gz",
        download_sha256: sha
      )
    )

    :ok = Manager.issue()
    assert_receive {:tls, %{stage: :downloading}}, 5_000
    assert_receive {:tls, %{stage: :issuing}}, 10_000
    assert %{stage: :idle} = settled()
    assert Tool.installed?(Tool.current_target())
  end

  describe "when a renewal is due" do
    test "never while off; at once without a certificate or for other names; 30 days before it runs out" do
      now = ~U[2026-09-27 00:00:00Z]
      on = %{enabled: true, domains: ["lx.example.test"]}
      cert = %{domains: ["lx.example.test"], not_after: DateTime.add(now, 60, :day)}

      refute Manager.due?(%{on | enabled: false}, nil, now)
      assert Manager.due?(on, nil, now)
      assert Manager.due?(%{on | domains: ["other.example.test"]}, cert, now)
      refute Manager.due?(on, cert, now)
      assert Manager.due?(on, %{cert | not_after: DateTime.add(now, 29, :day)}, now)
    end

    test "the daily job renews when due and does nothing otherwise", ctx do
      # nothing configured: the job has nothing to do
      assert :ok = perform_job(Longx.Tls.RenewWorker, %{})
      refute_receive {:tls, _}, 100

      configure(ctx)
      answer(ctx, Certs.self_signed())
      assert :ok = perform_job(Longx.Tls.RenewWorker, %{})
      assert %{stage: :idle} = settled()
      assert Tls.certificate()

      # the certificate is fresh now: another day's run starts nothing
      flush_status()
      assert :ok = perform_job(Longx.Tls.RenewWorker, %{})
      refute_receive {:tls, %{stage: :issuing}}, 200
    end

    test "renew_if_due issues only then", ctx do
      configure(ctx)
      answer(ctx, Certs.self_signed())
      assert :issuing = Manager.renew_if_due()
      assert %{stage: :idle} = settled()
      assert :not_due = Manager.renew_if_due()
    end
  end

  test "turning HTTPS off stops the listener; on again with a certificate starts it", ctx do
    configure(ctx)
    answer(ctx, Certs.self_signed())
    :ok = Manager.issue()
    assert %{stage: :idle} = settled()
    assert Listener.running?()

    {:ok, _} = Tls.save(%{enabled: false})
    :ok = Manager.apply_settings()
    refute Listener.running?()
    assert Tls.https_url() == nil

    {:ok, _} = Tls.save(%{enabled: true})
    :ok = Manager.apply_settings()
    assert Listener.port() == ctx.port
  end
end
