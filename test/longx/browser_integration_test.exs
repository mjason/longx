defmodule Longx.BrowserIntegrationTest do
  @moduledoc """
  The real obscura against a JavaScript-rendered page served by a Bypass:
  what `web_fetch` gets on an SPA. Installs the pinned release into a tmp
  directory when nothing is installed there (network).
  """
  use ExUnit.Case, async: false

  alias Longx.Browser

  @moduletag :integration

  @spa """
  <!doctype html><html><head><title>SPA test</title><script>x=1</script></head>
  <body><nav>menu</nav><div id="app">loading…</div>
  <script>setTimeout(function(){document.getElementById('app').innerHTML=
    '<main><h1>Rendered</h1><p class="lead">Hello from <b>JS</b></p><a href="/x">link</a></main>'},200)</script>
  <footer>foot</footer></body></html>
  """

  setup do
    previous = Application.get_env(:longx, Longx.Browser, [])
    dir = Path.join(System.tmp_dir!(), "longx-obscura-integration")
    target = Longx.Browser.Runtime.current_target()

    unless Longx.Browser.Runtime.installed?(target, dir: dir),
      do: {:ok, _} = Longx.Browser.Runtime.install(target, dir: dir)

    Application.put_env(
      :longx,
      Longx.Browser,
      # the unit suite's config hides the real binary; this test wants it
      previous
      |> Keyword.delete(:executable)
      |> Keyword.put(:dir, dir)
      |> Keyword.put(:allow_private_network, true)
    )

    on_exit(fn -> Application.put_env(:longx, Longx.Browser, previous) end)
    bypass = Bypass.open()

    Bypass.stub(bypass, "GET", "/spa", fn conn ->
      Plug.Conn.put_resp_content_type(conn, "text/html") |> Plug.Conn.send_resp(200, @spa)
    end)

    %{url: "http://127.0.0.1:#{bypass.port}/spa"}
  end

  test "renders the javascript before reading the page", %{url: url} do
    assert Browser.available?()
    assert {:ok, page} = Browser.fetch(url, wait_until: :networkidle0, timeout: 15_000)
    assert page.title == "SPA test"
    assert page.content =~ "<h1>Rendered</h1>"
    assert page.content =~ "Hello from <b>JS</b>"
    refute page.content =~ "loading"
    refute page.content =~ "menu"

    assert {:ok, %{format: :markdown, content: md}} =
             Browser.fetch(url, format: :markdown, timeout: 15_000)

    assert md =~ "# Rendered"
  end

  test "a page that never answers hits the deadline" do
    assert {:error, {:navigation, _}} = Browser.fetch("http://127.0.0.1:1/x", timeout: 3_000)
  end
end
