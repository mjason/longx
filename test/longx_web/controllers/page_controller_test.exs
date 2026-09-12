defmodule LongxWeb.PageControllerTest do
  use LongxWeb.ConnCase

  # The React SPA owns the URL space: any HTML navigation gets the shell and
  # the client router takes it from there. Everything that is not an HTML
  # page (API, sockets, missing static files) must never get the shell.
  describe "SPA shell" do
    test "GET / serves the shell", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ ~s(id="app")
    end

    test "deep links serve the shell too (client-side routing survives a refresh)", %{
      conn: conn
    } do
      for path <- ["/p/my-app", "/p/my-app/t/thr_123", "/settings", "/anything/really"] do
        conn = get(conn, path)
        assert html_response(conn, 200) =~ ~s(id="app")
      end
    end

    test "non-HTML requests to unknown paths are 404, not the shell", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get("/p/my-app")
      assert conn.status == 404
      refute conn.resp_body =~ ~s(id="app")
    end

    test "paths that look like files are 404 (a missing asset must not become HTML)", %{
      conn: conn
    } do
      for path <- ["/assets/missing.js", "/js/x.css", "/img/nope.png", "/x.json"] do
        conn = get(conn, path)
        assert conn.status == 404, path
        refute conn.resp_body =~ ~s(id="app")
      end
    end

    test "the shell carries the PWA bits", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s(rel="manifest")
      assert html =~ "viewport-fit=cover"
      assert html =~ ~s(name="theme-color")
    end
  end
end
