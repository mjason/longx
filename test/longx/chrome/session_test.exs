defmodule Longx.Chrome.SessionTest do
  # a conversation's browser session against the fake extension: tabs in the
  # session's group, the quota, what a navigation may open, the console buffer, the
  # turn's end, the close
  use LongxWeb.ChannelCase, async: false

  alias Longx.Agent.Plugs.Browser, as: BrowserPlug
  alias Longx.Chrome
  alias Longx.Chrome.{Aliases, Session}
  alias Longx.Test.FakeChrome

  setup do
    for b <- Chrome.list_browsers!(), do: :ok = Chrome.destroy_browser(b)
    for %{name: name} <- Aliases.all(), do: Aliases.delete(name)
    state = FakeChrome.start_state!()
    {socket, browser_id} = FakeChrome.connect!("fake-#{System.unique_integer([:positive])}")
    :ok = Aliases.put("qa", [browser_id])
    thread = "sess-#{System.unique_integer([:positive])}"
    on_exit(fn -> Session.whereis(thread) && Session.close(thread) end)

    %{
      state: state,
      socket: socket,
      browser_id: browser_id,
      thread: thread,
      responder: FakeChrome.responder(state)
    }
  end

  defp ensure!(thread, opts \\ []) do
    {:ok, _} =
      Session.ensure(
        thread,
        Keyword.merge(
          [
            alias: "qa",
            max_tabs: 1,
            prelude: BrowserPlug.prelude(),
            project_id: "proj-#{thread}"
          ],
          opts
        )
      )
  end

  defp run(ctx, code, timeout \\ 10_000) do
    task = Task.async(fn -> Session.execute(ctx.thread, code, timeout) end)
    FakeChrome.serve_task(ctx.socket, ctx.responder, task)
  end

  test "a cell opens a tab in the session's group, navigates and reads the page",
       ctx do
    ensure!(ctx.thread)

    assert {:ok,
            %{
              value: %{"url" => "http://site.test/x", "title" => "Page at http://site.test/x"},
              error: nil
            }} =
             run(ctx, "return await page.goto('http://site.test/x')")

    methods = ctx.state |> FakeChrome.commands() |> Enum.map(&elem(&1, 0))
    assert "chrome.tabs.create" in methods
    assert "chrome.tabs.group" in methods
    assert "chrome.tabGroups.update" in methods
    assert "chrome.debugger.attach" in methods

    assert [{_, [_group, %{"title" => "Longx · " <> _}]}] =
             FakeChrome.commands(ctx.state, "chrome.tabGroups.update")

    assert Enum.any?(FakeChrome.commands(ctx.state, "chrome.debugger.sendCommand"), fn {_,
                                                                                        [_, m, p]} ->
             m == "Page.navigate" and p["url"] == "http://site.test/x"
           end)

    # the snapshot filters the accessibility tree; screenshots reach the result
    assert {:ok,
            %{
              value: %{
                "nodes" => [
                  %{"id" => 7, "role" => "button", "name" => "Continue"},
                  %{"id" => 9, "checked" => true}
                ]
              }
            }} =
             run(ctx, "const s = await snapshot(); return {nodes: s.nodes}")

    assert {:ok, %{images: [%{mime: "image/jpeg"}], value: "Screenshot captured."}} =
             run(ctx, "return await screenshot()")

    assert %{tabs: [%{attached: true}]} = Session.info(ctx.thread)
  end

  test "rebinding an alias releases the old session and requires a fresh cell", ctx do
    ensure!(ctx.thread)
    assert {:ok, %{value: []}} = run(ctx, "let oldDevice = 'old'; return await tabs.list()")
    assert %{browser_id: old_id} = Session.info(ctx.thread)
    assert old_id == ctx.browser_id

    {new_socket, new_id} = FakeChrome.connect!("replacement-#{ctx.thread}")
    :ok = Aliases.put("qa", [new_id])
    # Even though the old device is still online, it is no longer the binding.
    assert {:error, message} =
             Session.execute(ctx.thread, "await tabs.open('http://wrong.test/')", 5_000)

    assert message =~ "binding changed"
    assert %{browser_id: nil, tabs: []} = Session.info(ctx.thread)
    assert FakeChrome.commands(ctx.state, "chrome.tabs.create") == []

    assert {:ok, %{value: "undefined", error: nil}} =
             run(%{ctx | socket: new_socket}, "await tabs.list(); return typeof oldDevice")

    assert %{browser_id: ^new_id} = Session.info(ctx.thread)
  end

  test "a binding changed during a cell refuses commands to the old device", ctx do
    ensure!(ctx.thread)
    assert {:ok, %{value: []}} = run(ctx, "return await tabs.list()")
    session = Session.whereis(ctx.thread)
    {_, new_id} = FakeChrome.connect!("mid-cell-#{ctx.thread}")
    :ok = Aliases.put("qa", [new_id])

    assert {:error, message} =
             Session.cdp(session, %{
               target: "longx",
               method: "longx.tabs.open",
               params: %{"url" => "http://wrong.test"},
               runtime: nil
             })

    assert message =~ "binding changed"
    assert FakeChrome.commands(ctx.state, "chrome.tabs.create") == []
  end

  test "deleting a browser releases owned tabs without removing the person's pages", ctx do
    ensure!(ctx.thread)
    assert {:ok, %{error: nil}} = run(ctx, "await page.goto('http://site.test/')")
    assert Longx.Chrome.Tabs.count_of_browser(ctx.browser_id) == 1
    assert :ok = Chrome.delete(ctx.browser_id)
    assert %{tabs: []} = Session.info(ctx.thread)
    assert Longx.Chrome.Tabs.count_of_browser(ctx.browser_id) == 0
    assert map_size(FakeChrome.tabs(ctx.state)) == 1
    assert FakeChrome.commands(ctx.state, "chrome.tabs.remove") == []
  end

  test "the project's tab limit counts, and tabs.close frees a slot", ctx do
    ensure!(ctx.thread, max_tabs: 1)
    assert {:ok, %{error: nil}} = run(ctx, "await page.goto('http://site.test/')")

    assert {:ok, %{error: error}} = run(ctx, "await tabs.open('http://site.test/two')")
    assert error =~ "tab limit (1) reached for this project"

    assert {:ok, %{value: 1}} = run(ctx, "const l = await tabs.list(); return l.length")
    assert {:ok, %{error: nil}} = run(ctx, "await page.close()")
    assert [{_, [_id]}] = FakeChrome.commands(ctx.state, "chrome.tabs.remove")

    assert {:ok, %{value: "http://site.test/two"}} =
             run(
               ctx,
               "const p = await tabs.open('http://site.test/two'); return (await p.info()).url"
             )
  end

  test "a site is opened without asking anyone; only http(s) URLs and about:blank navigate",
       ctx do
    ensure!(ctx.thread)
    assert {:ok, %{error: nil}} = run(ctx, "await page.goto('http://unknown.test/')")
    assert {:ok, %{error: error}} = run(ctx, "await page.goto('chrome://settings')")
    assert error =~ "not an http(s) URL: chrome://settings"
    # the one navigation, no ask
    navigations =
      Enum.filter(FakeChrome.commands(ctx.state, "chrome.debugger.sendCommand"), fn {_, [_, m, _]} ->
        m == "Page.navigate"
      end)

    assert [_] = navigations
  end

  test "managed CDP domains and cookies are refused; other tab commands pass", ctx do
    ensure!(ctx.thread)
    assert {:ok, %{error: nil}} = run(ctx, "await page.goto('http://site.test/')")

    assert {:ok, %{value: "caught: Target.createTarget is managed by Longx" <> _}} =
             run(
               ctx,
               "try { await page.cdp('Target.createTarget', {url: 'x'}) } catch (e) { return 'caught: ' + e.message }"
             )

    assert {:ok, %{value: "caught: Network.getAllCookies: cookies stay the person's"}} =
             run(
               ctx,
               "try { await page.cdp('Network.getAllCookies', {}) } catch (e) { return 'caught: ' + e.message }"
             )

    assert {:ok, %{value: %{"content" => [10, 10, 30 | _]}}} =
             run(ctx, "return (await page.cdp('DOM.getBoxModel', {backendNodeId: 7})).model")
  end

  test "the tab's console is buffered from the extension's events and read with page.console()",
       ctx do
    ensure!(ctx.thread)
    assert {:ok, %{error: nil}} = run(ctx, "await page.goto('http://site.test/')")
    [tab_id] = ctx.state |> FakeChrome.tabs() |> Map.keys()

    push(ctx.socket, "event", %{
      "method" => "chrome.debugger.onEvent",
      "params" => [
        %{"tabId" => tab_id},
        "Runtime.consoleAPICalled",
        %{
          "type" => "error",
          "args" => [
            %{"type" => "string", "value" => "boom"},
            %{"type" => "number", "value" => 42}
          ]
        }
      ]
    })

    push(ctx.socket, "event", %{
      "method" => "chrome.debugger.onEvent",
      "params" => [
        %{"tabId" => tab_id},
        "Runtime.exceptionThrown",
        %{
          "exceptionDetails" => %{
            "exception" => %{"description" => "TypeError: x is not a function"}
          }
        }
      ]
    })

    assert {:ok,
            %{
              value: [
                %{"kind" => "console", "level" => "error", "text" => "boom 42"},
                %{"kind" => "exception", "text" => "TypeError: x is not a function"}
              ]
            }} =
             run(ctx, "return await page.console({clear: true})")

    assert {:ok, %{value: []}} = run(ctx, "return await page.console()")
  end

  test "the turn's end detaches the debugger from every tab; the next cell attaches again", ctx do
    ensure!(ctx.thread)
    assert {:ok, %{error: nil}} = run(ctx, "await page.goto('http://site.test/')")

    task =
      Task.async(fn ->
        Session.turn_ended(ctx.thread)
        wait_until(fn -> match?(%{tabs: [%{attached: false}]}, Session.info(ctx.thread)) end)
      end)

    assert :ok = FakeChrome.serve_task(ctx.socket, ctx.responder, task)
    assert [{_, [%{"tabId" => _}]}] = FakeChrome.commands(ctx.state, "chrome.debugger.detach")

    assert {:ok, %{value: "http://site.test/"}} = run(ctx, "return (await page.info()).url")
    assert length(FakeChrome.commands(ctx.state, "chrome.debugger.attach")) == 2
  end

  test "a tab the person drags into the group is the session's; one dragged out is not; closing removes the session's own",
       ctx do
    ensure!(ctx.thread, max_tabs: 3)
    assert {:ok, %{error: nil}} = run(ctx, "await page.goto('http://site.test/')")
    [own] = ctx.state |> FakeChrome.tabs() |> Map.keys()

    dragged = FakeChrome.drag_in(ctx.state, "http://site.test/theirs", "Theirs")
    assert {:ok, %{value: 2}} = run(ctx, "return (await tabs.list()).length")

    assert {:ok, %{value: "http://site.test/theirs"}} =
             run(ctx, "const t = await tabs.get(#{dragged}); return (await t.info()).url")

    FakeChrome.drag_out(ctx.state, dragged)
    assert {:ok, %{value: [^own]}} = run(ctx, "return (await tabs.list()).map(t => t.id)")

    task = Task.async(fn -> Session.close(ctx.thread) end)
    assert :ok = FakeChrome.serve_task(ctx.socket, ctx.responder, task)
    assert [{_, [^own]}] = FakeChrome.commands(ctx.state, "chrome.tabs.remove")
    assert Session.whereis(ctx.thread) == nil
  end

  test "an alias nobody defined, or a browser offline, is an error the cell can read", ctx do
    ensure!(ctx.thread, alias: "nope")
    assert {:ok, %{error: error}} = run(ctx, "await page.goto('http://site.test/')")
    assert error =~ ~s(no browser is named "nope")
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        :timeout

      true ->
        receive do
        after
          20 -> wait_until(fun, tries - 1)
        end
    end
  end
end
