defmodule Longx.Test.FakeChrome do
  @moduledoc """
  The Longx Chrome extension played by the test process: it joins
  `chrome:bridge`, gets itself approved, and answers the `cmd` pushes with
  a small fake Chrome (`responder/0`: tabs, a tab group, a debugger that
  navigates, evaluates and takes screenshots) while the code under test
  runs in a task (`serve/3`). Every command answered is remembered
  (`commands/1`) for the assertions.
  """

  import ExUnit.Assertions
  import Phoenix.ChannelTest

  alias Longx.Chrome

  @endpoint LongxWeb.Endpoint

  @doc "A connected, approved extension: `{socket, browser_id}`."
  def connect!(install_id) do
    {:ok, socket} =
      connect(LongxWeb.ChromeSocket, %{
        "install_id" => install_id,
        "device" => %{"name" => "Fake Chrome", "platform" => "linux", "extension" => "0.1.0"}
      })

    {:ok, %{"browser_id" => id}, socket} = subscribe_and_join(socket, "chrome:bridge", %{})
    {:ok, _, _token} = Chrome.approve(id)
    assert_push "approved", _
    {socket, id}
  end

  @doc "The fake Chrome's state: an Agent the responder keeps its tabs and the commands in."
  def start_state! do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{next_tab: 100, tabs: %{}, group: nil, commands: [], events: []}
      end)

    pid
  end

  def commands(state), do: Agent.get(state, &Enum.reverse(&1.commands))

  @doc "Commands of one method, oldest first."
  def commands(state, method), do: state |> commands() |> Enum.filter(&(elem(&1, 0) == method))

  def tabs(state), do: Agent.get(state, & &1.tabs)

  @doc "Puts a tab into the group by hand (the person dragged it in)."
  def drag_in(state, url, title) do
    Agent.get_and_update(state, fn s ->
      id = s.next_tab

      {id,
       %{
         s
         | next_tab: id + 1,
           tabs: Map.put(s.tabs, id, %{url: url, title: title, group: s.group})
       }}
    end)
  end

  def drag_out(state, tab_id),
    do:
      Agent.update(state, fn s ->
        %{s | tabs: Map.update!(s.tabs, tab_id, &%{&1 | group: nil})}
      end)

  @doc """
  Answers `cmd` pushes from `socket` with `responder.(method, params)` until
  `until.(message)` says `{:halt, value}` for some other message the test
  process received (a task's reply, a thread event); `:cont` keeps going.
  """
  def serve(socket, responder, until, timeout \\ 15_000) do
    receive do
      %Phoenix.Socket.Message{
        event: "cmd",
        payload: %{"id" => id, "method" => method, "params" => params}
      } ->
        reply =
          case responder.(method, params) do
            {:ok, value} -> %{"id" => id, "result" => value}
            {:error, message} -> %{"id" => id, "error" => message}
          end

        push(socket, "result", reply)
        serve(socket, responder, until, timeout)

      other ->
        case until.(other) do
          {:halt, value} -> value
          :cont -> serve(socket, responder, until, timeout)
        end
    after
      timeout -> flunk("the fake extension waited #{timeout} ms for the end")
    end
  end

  @doc "Serves until the task answers."
  def serve_task(socket, responder, %Task{ref: ref} = task, timeout \\ 15_000) do
    serve(
      socket,
      responder,
      fn
        {^ref, result} ->
          Process.demonitor(ref, [:flush])
          {:halt, result}

        {:DOWN, ^ref, :process, _, reason} ->
          {:halt, {:error, {:task_down, reason}}}

        _ ->
          :cont
      end,
      timeout
    )
    |> tap(fn _ -> _ = task end)
  end

  @doc "The fake Chrome: `chrome.*` calls and the CDP commands a session sends."
  def responder(state) do
    fn method, params ->
      Agent.update(state, fn s -> %{s | commands: [{method, params} | s.commands]} end)
      answer(state, method, params)
    end
  end

  defp answer(state, "chrome.tabs.create", [%{"url" => url}]) do
    id =
      Agent.get_and_update(state, fn s ->
        id = s.next_tab

        {id,
         %{s | next_tab: id + 1, tabs: Map.put(s.tabs, id, %{url: url, title: "", group: nil})}}
      end)

    {:ok, %{"id" => id, "url" => url, "title" => "", "active" => false}}
  end

  defp answer(state, "chrome.tabs.group", [%{"tabIds" => ids} = args]) do
    group =
      Agent.get_and_update(state, fn s ->
        group = args["groupId"] || s.group || 5

        tabs =
          Enum.reduce(ids, s.tabs, fn id, acc -> Map.update!(acc, id, &%{&1 | group: group}) end)

        {group, %{s | group: group, tabs: tabs}}
      end)

    {:ok, group}
  end

  defp answer(_state, "chrome.tabGroups.update", [_group, _props]), do: {:ok, %{}}

  defp answer(state, "chrome.tabs.query", [%{"groupId" => group}]) do
    tabs =
      state
      |> tabs()
      |> Enum.filter(fn {_id, t} -> t.group == group end)
      |> Enum.map(fn {id, t} ->
        %{"id" => id, "url" => t.url, "title" => t.title, "active" => false}
      end)
      |> Enum.sort_by(& &1["id"])

    {:ok, tabs}
  end

  defp answer(state, "chrome.tabs.remove", [id]) do
    Agent.update(state, fn s -> %{s | tabs: Map.delete(s.tabs, id)} end)
    {:ok, %{}}
  end

  defp answer(_state, "chrome.debugger.attach", [_debuggee, _version]), do: {:ok, %{}}
  defp answer(_state, "chrome.debugger.detach", [_debuggee]), do: {:ok, %{}}

  defp answer(state, "chrome.debugger.sendCommand", [%{"tabId" => tab}, method, params]),
    do: cdp(state, tab, method, params || %{})

  defp answer(_state, method, _params), do: {:error, "fake chrome: no such method #{method}"}

  defp cdp(_state, _tab, method, _params)
       when method in ~w(Runtime.enable Page.enable Log.enable), do: {:ok, %{}}

  defp cdp(state, tab, "Page.navigate", %{"url" => url}) do
    Agent.update(state, fn s ->
      %{s | tabs: Map.update!(s.tabs, tab, &%{&1 | url: url, title: "Page at " <> url})}
    end)

    {:ok, %{"frameId" => "F#{tab}", "loaderId" => "L1"}}
  end

  defp cdp(state, tab, "Runtime.evaluate", %{"expression" => expression}) do
    t = tabs(state)[tab] || %{url: "about:blank", title: ""}

    cond do
      String.contains?(expression, "document.readyState") ->
        {:ok, %{"result" => %{"type" => "boolean", "value" => true}}}

      String.contains?(expression, "location.href") ->
        {:ok,
         %{"result" => %{"type" => "object", "value" => %{"url" => t.url, "title" => t.title}}}}

      String.contains?(expression, "throw") ->
        {:ok,
         %{
           "exceptionDetails" => %{
             "text" => "Uncaught",
             "exception" => %{"description" => "Error: page boom"}
           }
         }}

      true ->
        {:ok,
         %{
           "result" => %{
             "type" => "string",
             "value" => "evaluated: " <> String.slice(expression, 0, 40)
           }
         }}
    end
  end

  defp cdp(_state, _tab, "Accessibility.getFullAXTree", _params) do
    {:ok,
     %{
       "nodes" => [
         %{
           "nodeId" => "1",
           "ignored" => false,
           "backendDOMNodeId" => 7,
           "role" => %{"value" => "button"},
           "name" => %{"value" => "  Continue "}
         },
         %{
           "nodeId" => "2",
           "ignored" => true,
           "backendDOMNodeId" => 8,
           "role" => %{"value" => "none"}
         },
         %{
           "nodeId" => "3",
           "ignored" => false,
           "backendDOMNodeId" => 9,
           "role" => %{"value" => "checkbox"},
           "name" => %{"value" => "Agree"},
           "properties" => [%{"name" => "checked", "value" => %{"value" => "true"}}]
         }
       ]
     }}
  end

  defp cdp(_state, _tab, "Page.captureScreenshot", _params),
    do: {:ok, %{"data" => Base.encode64("not really a jpeg")}}

  defp cdp(_state, _tab, "Input.dispatchMouseEvent", _params), do: {:ok, %{}}

  defp cdp(_state, _tab, "DOM.getBoxModel", _params),
    do: {:ok, %{"model" => %{"content" => [10, 10, 30, 10, 30, 20, 10, 20]}}}

  defp cdp(_state, _tab, method, _params),
    do: {:error, "fake chrome: unknown CDP method #{method}"}
end
