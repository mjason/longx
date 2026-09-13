defmodule Longx.AI.Search.FetchTest do
  @moduledoc """
  `web.run`'s `open` fetched by us (Req), not by a search provider: a page
  becomes readable text for the model. The site is played by a Bypass.
  """
  use ExUnit.Case, async: true

  alias Longx.AI.Search.Fetch

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}"}
  end

  test "html: title and the readable text, chrome and scripts dropped, blocks on their own lines",
       %{
         bypass: bypass,
         base: base
       } do
    Bypass.expect_once(bypass, "GET", "/docs/hooks", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, """
      <html><head><title>Hooks – docs</title><style>body{}</style>
      <script>var x = 1;</script></head>
      <body><nav><a href="/">Home</a></nav>
      <main><h1>Hooks</h1><p>Use <code>usePermissions()</code> to read <b>pending</b> requests.</p>
      <ul><li>one</li><li>two</li></ul><pre>const a = 1;\nconst b = 2;</pre></main>
      <footer>© 2026</footer><script>track()</script></body></html>
      """)
    end)

    assert {:ok, %{title: "Hooks – docs", text: text, content_type: "text/html"}} =
             Fetch.fetch(base <> "/docs/hooks")

    assert text =~ "Hooks\n"
    assert text =~ "Use usePermissions() to read pending requests."
    assert text =~ "one\ntwo"
    assert text =~ "const a = 1;\nconst b = 2;"
    refute text =~ "var x"
    refute text =~ "track()"
    refute text =~ "Home"
    refute text =~ "2026"
  end

  test "text-like bodies (plain, markdown, json) come back as they are", %{
    bypass: bypass,
    base: base
  } do
    Bypass.expect_once(bypass, "GET", "/llms.txt", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, "# Index\n- a\n")
    end)

    assert {:ok, %{title: nil, text: "# Index\n- a\n"}} = Fetch.fetch(base <> "/llms.txt")
  end

  test "binary content, http errors and connection failures are errors the caller can report", %{
    bypass: bypass,
    base: base
  } do
    Bypass.expect_once(bypass, "GET", "/a.png", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, <<137, 80>>)
    end)

    assert {:error, {:unsupported_content_type, "image/png"}} = Fetch.fetch(base <> "/a.png")

    Bypass.expect_once(bypass, "GET", "/gone", fn conn -> Plug.Conn.send_resp(conn, 404, "no") end)

    assert {:error, {:status, 404}} = Fetch.fetch(base <> "/gone")

    Bypass.down(bypass)
    assert {:error, _} = Fetch.fetch(base <> "/x")
    assert {:error, :invalid_url} = Fetch.fetch("ftp://x")
  end

  test "the body is capped", %{bypass: bypass, base: base} do
    Bypass.expect_once(bypass, "GET", "/big", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, String.duplicate("x", 100_000))
    end)

    assert {:ok, %{text: text}} = Fetch.fetch(base <> "/big", max_bytes: 10_000)
    assert byte_size(text) <= 10_000
  end
end
