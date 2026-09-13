defmodule Longx.Tools.Builtin.BrowserFetchTest do
  @moduledoc "`builtin.browser_fetch`: the agent reads a rendered page through Longx.Browser."
  use ExUnit.Case, async: false

  alias Longx.Codex.Tool.Context
  alias Longx.Tools.Builtin.BrowserFetch

  @fake Path.expand("../../../support/fake_obscura.sh", __DIR__)

  setup do
    previous = Application.get_env(:longx, Longx.Browser, [])
    Application.put_env(:longx, Longx.Browser, Keyword.put(previous, :executable, @fake))
    on_exit(fn -> Application.put_env(:longx, Longx.Browser, previous) end)
    %{ctx: %Context{cwd: "/tmp"}}
  end

  test "is a registered builtin with a schema the model can fill", %{ctx: ctx} do
    assert BrowserFetch.name() == "browser_fetch"
    assert BrowserFetch.namespace() == "builtin"
    assert %{"required" => ["url"]} = BrowserFetch.input_schema()
    assert BrowserFetch.available?(ctx)
    assert BrowserFetch.timeout() > Longx.Codex.Tool.default_timeout()
  end

  test "returns the rendered page (main html by default, markdown/text on request)", %{ctx: ctx} do
    assert {:ok, out} = BrowserFetch.call(%{"url" => "https://spa.test/app"}, ctx)
    assert out =~ "Fake page"
    assert out =~ "<h1>Rendered</h1>"
    refute out =~ "menu"

    assert {:ok, md} =
             BrowserFetch.call(%{"url" => "https://spa.test/app", "format" => "markdown"}, ctx)

    assert md =~ "# Rendered"
  end

  test "a failed navigation is a readable error, not a crash", %{ctx: ctx} do
    assert {:error, message} = BrowserFetch.call(%{"url" => "https://spa.test/fail"}, ctx)
    assert message =~ "connection refused"
    assert {:error, message} = BrowserFetch.call(%{"url" => "file:///etc/passwd"}, ctx)
    assert message =~ "http"
  end

  test "unavailable without the binary", %{ctx: ctx} do
    Application.put_env(:longx, Longx.Browser, executable: "/nonexistent/obscura")
    refute BrowserFetch.available?(ctx)
  end
end
