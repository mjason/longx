defmodule Longx.Tls.ListenerTest do
  @moduledoc """
  The HTTPS listener beside the plain http one: the same Phoenix endpoint
  behind a Bandit TLS server that starts and stops at run time, and takes a
  renewed certificate without a restart.
  """
  use ExUnit.Case, async: false

  alias Longx.Tls.Listener
  alias Longx.Test.Certs

  setup do
    dir = Path.join(System.tmp_dir!(), "longx-tls-listener-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> Listener.stop() end)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{cert: Path.join(dir, "cert.pem"), key: Path.join(dir, "key.pem")}
  end

  defp write(ctx, %{cert: cert, key: key}) do
    File.write!(ctx.cert, cert)
    File.write!(ctx.key, key)
  end

  defp get(port, path) do
    Req.get!("https://127.0.0.1:#{port}#{path}",
      connect_options: [transport_opts: [verify: :verify_none]],
      retry: false
    )
  end

  test "serves the endpoint over TLS, then stops", ctx do
    first = Certs.self_signed()
    write(ctx, first)
    refute Listener.running?()

    assert {:ok, port} =
             Listener.start(port: 0, ip: {127, 0, 0, 1}, certfile: ctx.cert, keyfile: ctx.key)

    assert Listener.running?()
    assert Listener.port() == port

    assert %Req.Response{status: 200} = get(port, "/health")
    assert Certs.served_serial(port) == first.serial

    :ok = Listener.stop()
    refute Listener.running?()
    assert {:error, _} = :gen_tcp.connect(~c"127.0.0.1", port, [], 500)
  end

  test "a renewed certificate is served to the next connection without a restart", ctx do
    first = Certs.self_signed()
    write(ctx, first)

    {:ok, port} =
      Listener.start(port: 0, ip: {127, 0, 0, 1}, certfile: ctx.cert, keyfile: ctx.key)

    assert Certs.served_serial(port) == first.serial

    second = Certs.self_signed()
    write(ctx, second)
    :ok = Listener.reload()

    assert Certs.served_serial(port) == second.serial
    assert Listener.port() == port
  end

  test "starting again replaces the running listener", ctx do
    write(ctx, Certs.self_signed())
    {:ok, _} = Listener.start(port: 0, ip: {127, 0, 0, 1}, certfile: ctx.cert, keyfile: ctx.key)

    {:ok, port} =
      Listener.start(port: 0, ip: {127, 0, 0, 1}, certfile: ctx.cert, keyfile: ctx.key)

    assert Listener.port() == port
    assert %Req.Response{status: 200} = get(port, "/health")
  end
end
