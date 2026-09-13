defmodule Longx.BrowserTest do
  @moduledoc """
  `Longx.Browser`: page fetches through the bundled headless browser, one
  short-lived process per fetch under `Longx.Shim`, permits from
  `Longx.Browser.Pool`. The binary is played by `test/support/fake_obscura.sh`.
  """
  use ExUnit.Case, async: false

  alias Longx.Browser
  alias Longx.Browser.Pool

  @fake Path.expand("../support/fake_obscura.sh", __DIR__)

  setup do
    previous = Application.get_env(:longx, Longx.Browser, [])

    Application.put_env(
      :longx,
      Longx.Browser,
      Keyword.merge(previous, executable: @fake, max_concurrent: 2, queue_timeout: 300)
    )

    on_exit(fn -> Application.put_env(:longx, Longx.Browser, previous) end)
    :ok
  end

  describe "fetch/2" do
    test "renders the page: title from obscura's log, the cleaned main html by default" do
      assert {:ok, page} = Browser.fetch("https://example.test/page")
      assert page.url == "https://example.test/page"
      assert page.title == "Fake page"
      assert page.format == :html
      # main only, chrome / scripts / non-essential attributes gone
      assert page.content =~ "<h1>Rendered</h1>"
      assert page.content =~ ~s(<a href="/x">link</a>)
      assert page.content =~ "<p>Hello from <b>JS</b></p>"
      refute page.content =~ "menu"
      refute page.content =~ "foot"
      refute page.content =~ "x()"
      refute page.content =~ "data-x"
    end

    test "markdown and text come straight from obscura; flags reach the binary" do
      assert {:ok, %{format: :markdown, content: "# Rendered\n\nHello from JS\n", stderr: stderr}} =
               Browser.fetch("https://example.test/page",
                 format: :markdown,
                 wait_until: :networkidle0,
                 selector: "main",
                 timeout: 7_000
               )

      assert stderr =~ "--dump markdown"
      assert stderr =~ "--wait-until networkidle0"
      assert stderr =~ "--selector main"
      assert stderr =~ "--timeout 7"
      assert stderr =~ "--quiet"

      assert {:ok, %{format: :text, content: "Rendered\nHello from JS\n"}} =
               Browser.fetch("https://example.test/page", format: :text)
    end

    test "a navigation failure is an error with obscura's message" do
      assert {:error, {:navigation, message}} = Browser.fetch("https://example.test/fail")
      assert message =~ "connection refused"
    end

    test "a fetch past its deadline is killed and reported" do
      assert {:error, :timeout} = Browser.fetch("https://example.test/slow?5", timeout: 200)
    end

    test "content is capped" do
      assert {:ok, %{content: content, truncated: true}} =
               Browser.fetch("https://example.test/big", max_bytes: 10_000)

      assert byte_size(content) <= 10_000
    end

    test "only http(s) urls" do
      assert {:error, :invalid_url} = Browser.fetch("file:///etc/passwd")
    end
  end

  describe "pool" do
    test "at most max_concurrent fetches run at once; the rest wait, and give up after queue_timeout" do
      parent = self()

      slow =
        for i <- 1..2 do
          Task.async(fn ->
            send(parent, {:started, i})
            Browser.fetch("https://example.test/slow?1", timeout: 5_000)
          end)
        end

      assert_receive {:started, _}
      assert_receive {:started, _}
      Process.sleep(100)
      assert %{busy: 2, waiting: 0} = Pool.status()

      # the third cannot get a permit within queue_timeout (300 ms) while two 1 s fetches run
      assert {:error, :busy} = Browser.fetch("https://example.test/page")
      assert Enum.all?(Task.await_many(slow, 10_000), &match?({:ok, _}, &1))
      assert %{busy: 0, waiting: 0} = Pool.status()
    end

    test "a caller that dies while holding a permit releases it" do
      pid =
        spawn(fn ->
          Browser.fetch("https://example.test/slow?5", timeout: 10_000)
        end)

      Process.sleep(100)
      assert %{busy: 1} = Pool.status()
      Process.exit(pid, :kill)
      Process.sleep(50)
      assert %{busy: 0} = Pool.status()
    end
  end

  describe "availability" do
    test "available?/0 follows the executable" do
      assert Browser.available?()
      Application.put_env(:longx, Longx.Browser, executable: "/nope/obscura")
      refute Browser.available?()
      assert {:error, :unavailable} = Browser.fetch("https://example.test/page")
    end
  end
end
