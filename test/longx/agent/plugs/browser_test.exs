defmodule Longx.Agent.Plugs.BrowserTest do
  # the javascript tool end to end: Bypass as the model, the fake extension as
  # the person's Chrome, a real agent whose turn the person's answer unblocks
  use LongxWeb.ChannelCase, async: false

  alias Longx.Agent
  alias Longx.Agent.{Step, ThreadState}
  alias Longx.Agent.Plugs.Browser, as: BrowserPlug
  alias Longx.AI
  alias Longx.Chrome
  alias Longx.Chrome.{Aliases, Session}
  alias Longx.Test.{FakeChrome, ResponsesFixture}

  defmodule Pipeline do
    use Longx.Agent.Pipeline
    plug Longx.Agent.Plugs.Browser, browser: "qa", max_tabs: 2
    plug Longx.Agent.Plugs.Request
  end

  setup do
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)
    for b <- Chrome.list_browsers!(), do: :ok = Chrome.destroy_browser(b)
    for %{name: name} <- Aliases.all(), do: Aliases.delete(name)

    bypass = Bypass.open()
    n = System.unique_integer([:positive])

    provider =
      AI.create_provider!(%{
        name: "Upstream #{n}",
        slug: "upstream-#{n}",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key: "sk-upstream"
      })

    model =
      AI.create_model!(%{
        name: "Fake",
        upstream_id: "real-model",
        slug: "fake-#{n}",
        provider_id: provider.id,
        context_window: 64_000
      })

    AI.make_default_model!(model)

    dir = Path.join(System.tmp_dir!(), "longx-browser-#{n}")
    File.mkdir_p!(dir)
    thread_id = "browser-thread-#{n}"
    :ok = ThreadState.subscribe(thread_id)

    state = FakeChrome.start_state!()
    {socket, browser_id} = FakeChrome.connect!("plug-#{n}")
    :ok = Aliases.put("qa", [browser_id])

    on_exit(fn ->
      Session.whereis(thread_id) && Session.close(thread_id)
      Agent.stop(thread_id)
      ThreadState.stop(thread_id)
      ThreadState.Store.delete(thread_id)
      File.rm_rf!(dir)
      Longx.Test.Agents.stop_all!()
    end)

    {:ok, _pid} =
      Agent.ensure(thread_id: thread_id, cwd: dir, project_id: "p-#{n}", pipeline: Pipeline)

    %{
      bypass: bypass,
      thread_id: thread_id,
      browser_id: browser_id,
      socket: socket,
      state: state,
      responder: FakeChrome.responder(state)
    }
  end

  defp sse(conn, chunks) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, c ->
      {:ok, c} = Plug.Conn.chunk(c, chunk)
      c
    end)
  end

  # the model: `fun.(request_body)` gives the stream for each request; every
  # request body is kept (the fake extension's serve loop drains the mailbox)
  defp route!(bypass, fun) do
    {:ok, requests} = Elixir.Agent.start_link(fn -> [] end)

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      Elixir.Agent.update(requests, &[body | &1])
      sse(conn, fun.(body))
    end)

    requests
  end

  defp requests(agent), do: Elixir.Agent.get(agent, &Enum.reverse/1)

  defp output_of(body) do
    body["input"]
    |> Enum.filter(&(&1["type"] == "function_call_output"))
    |> List.last()
    |> then(&(&1 && &1["output"]))
  end

  test "the prompt names the browser and mounts javascript; nothing live is in it" do
    step = Pipeline.run(Step.new(phase: :request, thread_id: "x"))
    text = Enum.join(step.instructions, "\n")
    assert text =~ "# Browser"
    assert text =~ "Browser Use Confirmation Policy"
    assert text =~ "named `qa`"
    assert text =~ "Tab limit for this project: 2"
    refute text =~ "online"
    assert %{"javascript" => tool} = step.tools
    assert tool.namespace == "browser"
    assert tool.schema["required"] == ["title", "code"]
  end

  test "a cell opens the person's browser without asking; the screenshot reaches the next request; the turn's end detaches",
       ctx do
    code =
      "const info = await page.goto('http://site.test/x'); console.log('at', info.url); await screenshot(); return info.url"

    requests =
      route!(ctx.bypass, fn body ->
        case output_of(body) do
          nil ->
            ResponsesFixture.function_call("javascript", "browser", %{
              "title" => "open the page",
              "code" => code
            })

          _ ->
            ResponsesFixture.assistant_message("done")
        end
      end)

    {:ok, _} = Agent.send(ctx.thread_id, "look at the page")

    # the fake extension serves while the agent runs; nobody is asked before the site opens
    completed =
      FakeChrome.serve(ctx.socket, ctx.responder, fn
        {:thread, _, "longx/action/request", params} ->
          flunk("an ask before opening a site: #{inspect(params)}")

        {:thread, _, "turn/completed", params} ->
          {:halt, params}

        _ ->
          :cont
      end)

    assert %{"turn" => %{"status" => "completed"}} = completed

    # the model read the console line, the value and the screenshot note; the image followed as a screenshot message
    assert [_first, %{"input" => input} = second] = requests(requests)
    output = output_of(second)
    assert output =~ "at http://site.test/x"
    assert output =~ ~s(→ "http://site.test/x")
    assert output =~ "1 screenshot(s) attached"

    assert [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{"type" => "input_image", "image_url" => "data:image/jpeg;base64," <> _}
               ]
             }
           ] =
             Enum.filter(input, &match?(%{"content" => [%{"type" => "input_image"} | _]}, &1))

    # the row the person sees carries the title and the code
    snapshot = ThreadState.snapshot(ctx.thread_id)

    assert %{"details" => details} =
             Enum.find(Map.get(snapshot, :items) || snapshot["items"] || [], fn
               %{"type" => "dynamicToolCall", "tool" => "javascript", "status" => "completed"} ->
                 true

               _ ->
                 false
             end)

    assert details["title"] == "open the page"
    assert details["images"] == 1
    # the person's copy of the screenshot is an attachment of the project
    assert [%{"attachment" => true, "mime" => "image/jpeg", "name" => name}] =
             details["screenshots"]

    assert name =~ ~r/screenshot-1\.jpg$/

    # the turn's end let go of the tab (asynchronously): serve until the detach came through
    Process.send_after(self(), :tick, 50)

    FakeChrome.serve(ctx.socket, ctx.responder, fn
      :tick ->
        if FakeChrome.commands(ctx.state, "chrome.debugger.detach") != [] do
          {:halt, :ok}
        else
          Process.send_after(self(), :tick, 50)
          :cont
        end

      _ ->
        :cont
    end)

    assert [{_, [%{"tabId" => _}]}] = FakeChrome.commands(ctx.state, "chrome.debugger.detach")
    assert %{tabs: [%{attached: false}]} = Session.info(ctx.thread_id)
  end

  test "a URL that is not http(s) is an error the model reads, and nothing is navigated", ctx do
    code =
      "try { await page.goto('chrome://settings') } catch (e) { return 'refused: ' + e.message }"

    requests =
      route!(ctx.bypass, fn body ->
        case output_of(body) do
          nil ->
            ResponsesFixture.function_call("javascript", "browser", %{
              "title" => "try",
              "code" => code
            })

          _ ->
            ResponsesFixture.assistant_message("ok")
        end
      end)

    {:ok, _} = Agent.send(ctx.thread_id, "go")

    FakeChrome.serve(ctx.socket, ctx.responder, fn
      {:thread, _, "turn/completed", params} -> {:halt, params}
      _ -> :cont
    end)

    assert [_first, second] = requests(requests)
    assert output_of(second) =~ "refused: not an http(s) URL: chrome://settings"

    refute Enum.any?(FakeChrome.commands(ctx.state, "chrome.debugger.sendCommand"), fn {_,
                                                                                        [_, m, _]} ->
             m == "Page.navigate"
           end)
  end

  test "the tool describes what the model must know", _ctx do
    tool = Enum.find(BrowserPlug.__agent_tools__(), &(&1.name == "javascript"))
    assert tool.description =~ "Cell deadline: 30000 ms"
    assert tool.schema["properties"]["title"]["description"] =~ "shown to the person"
  end
end
