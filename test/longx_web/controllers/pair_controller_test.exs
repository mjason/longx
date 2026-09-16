defmodule LongxWeb.PairControllerTest do
  # A phone pairs with a code the settings page shows and gets a device
  # token; the token replaces the browser's session + CSRF on every RPC,
  # attachment upload and socket — a bearer request cannot be forged by
  # a page, so CSRF is not asked of it.
  use LongxWeb.ConnCase, async: false

  import Phoenix.ConnTest, except: [connect: 2]
  import Phoenix.ChannelTest, only: [connect: 2]

  alias Longx.System

  setup do
    for d <- System.list_devices!(), do: System.revoke_device!(d)
    :ok
  end

  defp pair!(conn, code, attrs \\ %{}) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/pair",
      Jason.encode!(
        Map.merge(%{"code" => code, "name" => "Pixel", "platform" => "android"}, attrs)
      )
    )
  end

  test "a fresh code pairs once; the token is a bearer for RPC without CSRF", %{conn: conn} do
    %{code: code, expires_at: expires} = System.pairing_code()
    assert String.match?(code, ~r/^\d{6}$/)
    assert DateTime.compare(expires, DateTime.utc_now()) == :gt

    assert %{
             "token" => token,
             "device" => %{"name" => "Pixel", "platform" => "android"},
             "server" => %{"version" => version}
           } =
             pair!(conn, code) |> json_response(200)

    assert version == Application.spec(:longx, :vsn) |> to_string()
    assert [%{name: "Pixel", platform: :android} = device] = System.list_devices!()
    refute Map.has_key?(device, :token)

    # spent: the same code is refused
    assert %{"error" => _} = pair!(build_conn(), code) |> json_response(401)

    # a bearer RPC, no CSRF token, from a conn that would otherwise need one
    rpc =
      build_conn()
      |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")
      |> post("/rpc/run", Jason.encode!(%{"action" => "list_projects", "fields" => ["id"]}))

    assert %{"success" => true} = json_response(rpc, 200)

    # a wrong bearer is refused outright
    bad =
      build_conn()
      |> put_req_header("authorization", "Bearer nope")
      |> put_req_header("content-type", "application/json")
      |> post("/rpc/run", Jason.encode!(%{"action" => "list_projects", "fields" => ["id"]}))

    assert json_response(bad, 401)

    # revoked: gone
    System.revoke_device!(device)

    gone =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")
      |> post("/rpc/run", Jason.encode!(%{"action" => "list_projects", "fields" => ["id"]}))

    assert json_response(gone, 401)
  end

  test "a wrong or stale code is refused", %{conn: conn} do
    assert %{"error" => _} = pair!(conn, "000000") |> json_response(401)
    %{code: code} = System.pairing_code()
    # a newer code replaces the old one
    %{code: newer} = System.pairing_code()
    assert %{"error" => _} = pair!(build_conn(), code) |> json_response(401)
    assert %{"token" => _} = pair!(build_conn(), newer) |> json_response(200)
  end

  test "the socket takes the token as a param; a bad one is refused, none is the browser", %{
    conn: _
  } do
    %{code: code} = System.pairing_code()
    %{"token" => token} = pair!(build_conn(), code) |> json_response(200)
    assert {:ok, _} = connect(LongxWeb.UserSocket, %{"token" => token})
    assert :error = connect(LongxWeb.UserSocket, %{"token" => "nope"})
    assert {:ok, _} = connect(LongxWeb.UserSocket, %{})
  end
end
