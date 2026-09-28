defmodule Longx.Chrome.Session do
  @moduledoc """
  One conversation's hold on the person's browser: which browser (an alias
  resolved on first use), its own **tab group** there (`Longx · <session>`;
  the tabs it opens go in, a tab the person drags in is handed over, one
  dragged out is taken back), the tabs' debugger attachments, a bounded
  console buffer per tab, and the JavaScript runtime (`Longx.Chrome.Runtime`)
  whose cells drive it all.

  The runtime's host calls come here (`cdp/2`, from the runtime's task):
  `tab:<id>` targets are checked (this session's tab, an allowed method, an
  http(s) URL for `Page.navigate` — no site is asked about: the browser is
  the person's and they paired it) and then sent to the extension as
  `chrome.debugger.sendCommand`;
  `longx` targets are the session's own methods (`longx.tabs.open / list /
  close`, `longx.console`). Tabs are counted against the project's
  `max_tabs` (all its sessions together) and the browser's.

  One `:temporary` process per thread (`Longx.Chrome.SessionSupervisor`,
  `Longx.Chrome.SessionRegistry`). The turn's end detaches the debugger
  from every tab (the person's browser stops saying it is being debugged;
  the tabs stay). The agent leaving idle for good closes the session: its
  tabs are closed, its runtime stopped.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Longx.Chrome
  alias Longx.Chrome.{Aliases, Connection, Runtime, Tabs}

  @registry Longx.Chrome.SessionRegistry
  @supervisor Longx.Chrome.SessionSupervisor
  @console_keep 200
  @cdp_timeout 30_000
  @close_grace_ms 60_000
  @colors ~w(blue red yellow green pink purple cyan orange)
  @refused_prefixes ~w(Target. Fetch. Browser. Storage. Tethering. SystemInfo.)
  @refused_methods ~w(Network.getCookies Network.getAllCookies Network.setCookie Network.setCookies Network.clearBrowserCookies Network.deleteCookies)

  ## Public API

  @doc "The session of a thread, started when there is none. Options: `alias:`, `max_tabs:`, `prelude:`, `project_id:`."
  @spec ensure(String.t(), keyword) :: {:ok, pid} | {:error, term}
  def ensure(thread_id, opts) when is_binary(thread_id) do
    case whereis(thread_id) do
      nil ->
        spec = {__MODULE__, Keyword.put(opts, :thread_id, thread_id)}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        GenServer.cast(pid, {:options, opts})
        {:ok, pid}
    end
  end

  def whereis(thread_id) do
    case Registry.lookup(@registry, thread_id) do
      # the registry drops a dead session a moment after it exits: never hand it out
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc "Runs a cell in the session's runtime (the call blocks for the cell)."
  @spec execute(String.t(), String.t(), pos_integer, keyword) ::
          {:ok, Runtime.result()} | {:error, term}
  def execute(thread_id, code, timeout_ms, opts \\ []) do
    case whereis(thread_id) do
      nil ->
        {:error, :no_session}

      pid ->
        case GenServer.call(pid, :runtime) do
          {:ok, rt} -> Runtime.execute(rt, code, timeout_ms, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The turn ended: the debugger lets go of every tab, the turn's allowances lapse."
  def turn_ended(thread_id) do
    case whereis(thread_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, :turn_ended)
    end
  end

  @doc "Closes the session: its tabs, its runtime. Answers once the session is gone."
  def close(thread_id) do
    case whereis(thread_id) do
      nil ->
        :ok

      pid ->
        # the reply comes before the process has exited: wait for it to be gone,
        # so the caller's next `whereis` finds nothing (a test on CI's slower
        # runner once saw the session still there right after its close)
        ref = Process.monitor(pid)
        result = GenServer.call(pid, :close, 30_000)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> result
        after
          5_000 ->
            Process.demonitor(ref, [:flush])
            result
        end
    end
  end

  @doc "What the session holds, for the page."
  def info(thread_id) do
    case whereis(thread_id) do
      nil -> nil
      pid -> GenServer.call(pid, :info)
    end
  end

  @doc "A host call from the runtime (`%{target, method, params, runtime}`), answered as the cell sees it."
  @spec cdp(pid, map) :: {:ok, term} | {:error, String.t()}
  def cdp(session, %{target: target, method: method, params: params, runtime: _rt}) do
    case GenServer.call(session, {:prepare, target, method, params}, 60_000) do
      {:reply, value} -> {:ok, value}
      {:send, browser_id, args} -> send_command(browser_id, args)
      {:error, message} -> {:error, message}
    end
  catch
    :exit, _ -> {:error, "the browser session is gone"}
  end

  defp send_command(browser_id, args) do
    case Connection.call(browser_id, "chrome.debugger.sendCommand", args, @cdp_timeout) do
      {:ok, value} ->
        {:ok, value}

      {:error, :timeout} ->
        {:error, "the browser did not answer within #{div(@cdp_timeout, 1000)} s"}

      {:error, :offline} ->
        {:error, "the browser is not connected"}

      {:error, :pending} ->
        {:error, "the browser is not approved yet"}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, other} ->
        {:error, inspect(other)}
    end
  end

  ## GenServer

  defstruct thread_id: nil,
            project_id: nil,
            alias: nil,
            max_tabs: 1,
            prelude: "",
            browser_id: nil,
            group_id: nil,
            # tab id => %{attached, refused, url, title, console}
            tabs: %{},
            runtime: nil,
            agent_ref: nil,
            close_timer: nil

  def start_link(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, thread_id}})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state =
      %__MODULE__{thread_id: Keyword.fetch!(opts, :thread_id)}
      |> apply_options(opts)
      |> watch_agent()

    {:ok, state}
  end

  defp apply_options(state, opts) do
    %{
      state
      | project_id: Keyword.get(opts, :project_id, state.project_id),
        alias: Keyword.get(opts, :alias, state.alias),
        max_tabs: Keyword.get(opts, :max_tabs, state.max_tabs) || 1,
        prelude: Keyword.get(opts, :prelude, state.prelude) || ""
    }
  end

  @impl true
  def handle_call(:runtime, _from, state) do
    state = watch_agent(state)

    case ensure_runtime(state) do
      {:ok, state} -> {:reply, {:ok, state.runtime}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       browser_id: state.browser_id,
       alias: state.alias,
       group_id: state.group_id,
       tabs:
         Enum.map(state.tabs, fn {id, t} ->
           %{id: id, url: t.url, title: t.title, attached: t.attached}
         end),
       max_tabs: state.max_tabs
     }, state}
  end

  def handle_call(:close, _from, state) do
    {:stop, :normal, :ok, close_everything(state)}
  end

  def handle_call({:prepare, target, method, params}, _from, state) do
    {reply, state} = prepare(state, target, method, params)
    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:options, opts}, state), do: {:noreply, apply_options(state, opts)}

  def handle_cast(:turn_ended, state) do
    state =
      Enum.reduce(state.tabs, state, fn {id, tab}, acc ->
        if tab.attached, do: detach(acc, id), else: acc
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:chrome_event, browser_id, method, params}, %{browser_id: browser_id} = state),
    do: {:noreply, on_event(state, method, params)}

  def handle_info({:chrome_event, _other, _method, _params}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{agent_ref: ref} = state) do
    timer = Process.send_after(self(), :maybe_close, @close_grace_ms)
    {:noreply, %{state | agent_ref: nil, close_timer: timer}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:maybe_close, state) do
    state = %{state | close_timer: nil}

    case Longx.Agent.whereis(state.thread_id) do
      nil -> {:stop, :normal, close_everything(state)}
      _pid -> {:noreply, watch_agent(state)}
    end
  end

  def handle_info({:EXIT, pid, _reason}, %{runtime: pid} = state),
    do: {:noreply, %{state | runtime: nil}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.runtime && Process.alive?(state.runtime), do: Runtime.stop(state.runtime)
    :ok
  end

  ## The agent's life

  defp watch_agent(%{agent_ref: ref} = state) when ref != nil, do: state

  defp watch_agent(state) do
    if state.close_timer, do: Process.cancel_timer(state.close_timer)

    case Longx.Agent.whereis(state.thread_id) do
      nil -> %{state | close_timer: nil}
      pid -> %{state | agent_ref: Process.monitor(pid), close_timer: nil}
    end
  end

  defp ensure_runtime(%{runtime: pid} = state) when is_pid(pid), do: {:ok, state}

  defp ensure_runtime(state) do
    me = self()

    case Runtime.start_link(prelude: state.prelude, cdp: fn call -> cdp(me, call) end) do
      {:ok, pid} -> {:ok, %{state | runtime: pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_everything(state) do
    state =
      Enum.reduce(Map.keys(state.tabs), state, fn id, acc ->
        acc = if acc.tabs[id].attached, do: detach(acc, id), else: acc
        _ = Connection.call(acc.browser_id, "chrome.tabs.remove", [id], 5_000)
        forget_tab(acc, id)
      end)

    if state.runtime && Process.alive?(state.runtime), do: Runtime.stop(state.runtime)
    %{state | runtime: nil}
  end

  ## Preparing a host call

  defp prepare(state, "longx", method, params) do
    with {:ok, state} <- resolve_browser(state) do
      longx_method(state, method, params)
    else
      {:error, message} -> {{:error, message}, state}
    end
  end

  defp prepare(state, "tab:" <> id, method, params) do
    with {:ok, tab_id} <- tab_id(id),
         {:ok, state} <- resolve_browser(state),
         {:ok, tab} <- owned(state, tab_id),
         :ok <- refused(tab),
         :ok <- allowed_method(method),
         {:ok, state} <- attach(state, tab_id) do
      case method do
        "Page.navigate" -> prepare_navigation(state, tab_id, params)
        _ -> {{:send, state.browser_id, [%{"tabId" => tab_id}, method, params]}, state}
      end
    else
      {:error, message} -> {{:error, message}, state}
    end
  end

  defp prepare(state, target, _method, _params),
    do: {{:error, "unknown target #{inspect(target)}: use \"tab:<id>\" or \"longx\""}, state}

  # any http(s) page, or a blank one: the browser is the person's own, no site is asked about
  defp prepare_navigation(state, tab_id, %{"url" => url} = params) when is_binary(url) do
    if navigable?(url) do
      {{:send, state.browser_id, [%{"tabId" => tab_id}, "Page.navigate", params]}, state}
    else
      {{:error, "not an http(s) URL: #{url}"}, state}
    end
  end

  defp prepare_navigation(state, _tab_id, _params),
    do: {{:error, "Page.navigate needs a url"}, state}

  defp navigable?(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        host != ""

      _ ->
        String.trim(url) in ["about:blank", ""]
    end
  end

  defp tab_id(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "bad tab id #{inspect(id)}"}
    end
  end

  defp owned(state, tab_id) do
    case Map.fetch(state.tabs, tab_id) do
      {:ok, tab} ->
        {:ok, tab}

      :error ->
        {:error,
         "tab #{tab_id} is not this session's — open one with tabs.open(url), or the person drags a tab into the session's tab group"}
    end
  end

  defp refused(%{refused: true}),
    do:
      {:error,
       "the person detached the debugger from this tab; do not go on with it unless they ask"}

  defp refused(_tab), do: :ok

  defp allowed_method(method) do
    cond do
      Enum.any?(@refused_prefixes, &String.starts_with?(method, &1)) ->
        {:error,
         "#{method} is managed by Longx (tabs through tabs.open / tabs.close; no browser-level or fetch interception commands)"}

      method in @refused_methods ->
        {:error, "#{method}: cookies stay the person's"}

      true ->
        :ok
    end
  end

  # the browser an alias names, kept once resolved while it stays online
  defp resolve_browser(%{browser_id: id} = state) when is_binary(id) do
    if Connection.online?(id),
      do: {:ok, state},
      else:
        {:error,
         "the browser #{browser_name(id)} is not connected: open Chrome on that machine and check the Longx extension"}
  end

  defp resolve_browser(state) do
    case Aliases.resolve(state.alias) do
      {:ok, browser} ->
        Phoenix.PubSub.subscribe(Longx.PubSub, Chrome.events_topic(browser.id))
        {:ok, %{state | browser_id: browser.id}}

      {:error, :no_default} ->
        {:error,
         "no browser: this project's description names none (`plug Browser, browser: \"<alias>\"`) and no default alias is set in Settings → 浏览器"}

      {:error, {:unknown_alias, name}} ->
        {:error,
         "no browser is named #{inspect(name)}: the person maps the alias to a paired browser in Settings → 浏览器"}

      {:error, {:offline, name, []}} ->
        {:error, "the alias #{inspect(name)} names no browser yet (Settings → 浏览器)"}

      {:error, {:offline, name, rows}} ->
        names = Enum.map_join(rows, ", ", & &1.name)

        {:error,
         "no browser of #{inspect(name)} is connected (#{names}): open Chrome there and check the Longx extension"}
    end
  end

  defp browser_name(id) do
    case Chrome.get_browser(id) do
      {:ok, %{name: name}} -> name
      _ -> id
    end
  end

  ## The session's own methods

  defp longx_method(state, "longx.tabs.open", _params) do
    with :ok <- quota(state),
         {:ok, tab} <-
           Connection.call(state.browser_id, "chrome.tabs.create", [
             %{"url" => "about:blank", "active" => false}
           ]),
         tab_id when is_integer(tab_id) <- tab["id"],
         {:ok, state} <- group(state, tab_id) do
      state = claim_tab(state, tab_id, "about:blank", "")

      case attach(state, tab_id) do
        {:ok, state} -> {{:reply, %{"tabId" => tab_id}}, state}
        {:error, message} -> {{:error, message}, state}
      end
    else
      {:error, message} when is_binary(message) -> {{:error, message}, state}
      {:error, other} -> {{:error, describe(other)}, state}
      other -> {{:error, "chrome.tabs.create answered #{inspect(other)}"}, state}
    end
  end

  defp longx_method(state, "longx.tabs.list", _params) do
    case reconcile(state) do
      {:ok, state, tabs} ->
        list =
          Enum.map(tabs, fn t ->
            %{
              "id" => t["id"],
              "url" => t["url"] || "",
              "title" => t["title"] || "",
              "active" => t["active"] == true
            }
          end)

        {{:reply, list}, state}

      {:error, message} ->
        {{:error, message}, state}
    end
  end

  defp longx_method(state, "longx.tabs.close", %{"id" => id}) when is_integer(id) do
    case owned(state, id) do
      {:ok, tab} ->
        state = if tab.attached, do: detach(state, id), else: state
        _ = Connection.call(state.browser_id, "chrome.tabs.remove", [id], 5_000)
        {{:reply, %{"closed" => id}}, forget_tab(state, id)}

      {:error, message} ->
        {{:error, message}, state}
    end
  end

  defp longx_method(state, "longx.console", params) do
    with {:ok, tab_id} <- Map.fetch(params, "tab"),
         {:ok, tab} <- owned(state, tab_id) do
      entries = Enum.reverse(tab.console)

      state =
        if params["clear"] == true, do: put_tab(state, tab_id, %{tab | console: []}), else: state

      {{:reply, entries}, state}
    else
      :error -> {{:error, "longx.console needs a tab"}, state}
      {:error, message} -> {{:error, message}, state}
    end
  end

  defp longx_method(state, method, _params),
    do: {{:error, "unknown longx method #{method}"}, state}

  defp quota(state) do
    project_count =
      if state.project_id, do: Tabs.of_project(state.project_id), else: map_size(state.tabs)

    browser_max =
      case Chrome.get_browser(state.browser_id) do
        {:ok, %{max_tabs: max}} -> max
        _ -> 6
      end

    cond do
      project_count >= state.max_tabs ->
        {:error,
         "tab limit (#{state.max_tabs}) reached for this project — reuse the current tab with page.goto, close one with tabs.close, or the person raises max_tabs (`plug Browser, max_tabs: N`)"}

      Tabs.count_of_browser(state.browser_id) >= browser_max ->
        {:error,
         "the browser's tab limit (#{browser_max}) is reached across all projects (Settings → 浏览器)"}

      true ->
        :ok
    end
  end

  # the session's tab group: made with the first tab, the rest join it
  defp group(%{group_id: nil} = state, tab_id) do
    with {:ok, group_id} when is_integer(group_id) <-
           Connection.call(state.browser_id, "chrome.tabs.group", [%{"tabIds" => [tab_id]}]) do
      title = "Longx · " <> session_title(state.thread_id)
      color = Enum.at(@colors, :erlang.phash2(state.thread_id, length(@colors)))

      _ =
        Connection.call(state.browser_id, "chrome.tabGroups.update", [
          group_id,
          %{"title" => title, "color" => color}
        ])

      {:ok, %{state | group_id: group_id}}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      other -> {:error, "chrome.tabs.group answered #{inspect(other)}"}
    end
  end

  defp group(state, tab_id) do
    case Connection.call(state.browser_id, "chrome.tabs.group", [
           %{"tabIds" => [tab_id], "groupId" => state.group_id}
         ]) do
      {:ok, _} -> {:ok, state}
      # the group is gone (its last tab closed): a new one
      {:error, _} -> group(%{state | group_id: nil}, tab_id)
    end
  end

  defp session_title(thread_id) do
    case Longx.Projects.get_thread_by_kernel_id(thread_id) do
      {:ok, thread} -> Longx.Projects.agent_name(thread)
      _ -> "~" <> String.slice(thread_id, -6, 6)
    end
  rescue
    _ -> "~" <> String.slice(thread_id, -6, 6)
  end

  # what the group holds now: tabs dragged in are the session's, dragged out are not
  defp reconcile(%{group_id: nil} = state), do: {:ok, state, []}

  defp reconcile(state) do
    case Connection.call(state.browser_id, "chrome.tabs.query", [%{"groupId" => state.group_id}]) do
      {:ok, tabs} when is_list(tabs) ->
        ids = for %{"id" => id} <- tabs, is_integer(id), do: id
        gone = Map.keys(state.tabs) -- ids
        state = Enum.reduce(gone, state, fn id, acc -> acc |> detach_if(id) |> forget_tab(id) end)

        state =
          Enum.reduce(tabs, state, fn %{"id" => id} = t, acc ->
            if Map.has_key?(acc.tabs, id),
              do:
                put_tab(acc, id, %{acc.tabs[id] | url: t["url"] || "", title: t["title"] || ""}),
              else: claim_tab(acc, id, t["url"] || "", t["title"] || "")
          end)

        {:ok, state, tabs}

      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, other} ->
        {:error, describe(other)}
    end
  end

  ## Attaching

  defp attach(state, tab_id) do
    case state.tabs[tab_id] do
      %{attached: true} ->
        {:ok, state}

      _ ->
        debuggee = %{"tabId" => tab_id}

        with {:ok, _} <-
               Connection.call(state.browser_id, "chrome.debugger.attach", [debuggee, "1.3"]),
             {:ok, _} <-
               Connection.call(state.browser_id, "chrome.debugger.sendCommand", [
                 debuggee,
                 "Runtime.enable",
                 %{}
               ]),
             {:ok, _} <-
               Connection.call(state.browser_id, "chrome.debugger.sendCommand", [
                 debuggee,
                 "Page.enable",
                 %{}
               ]),
             {:ok, _} <-
               Connection.call(state.browser_id, "chrome.debugger.sendCommand", [
                 debuggee,
                 "Log.enable",
                 %{}
               ]) do
          {:ok, put_tab(state, tab_id, %{state.tabs[tab_id] | attached: true})}
        else
          {:error, message} when is_binary(message) ->
            {:error, "could not attach to tab #{tab_id}: #{message}"}

          {:error, other} ->
            {:error, "could not attach to tab #{tab_id}: #{describe(other)}"}
        end
    end
  end

  defp detach(state, tab_id) do
    _ = Connection.call(state.browser_id, "chrome.debugger.detach", [%{"tabId" => tab_id}], 5_000)
    put_tab(state, tab_id, %{state.tabs[tab_id] | attached: false})
  end

  defp detach_if(state, tab_id),
    do: if(state.tabs[tab_id].attached, do: detach(state, tab_id), else: state)

  ## Tabs

  defp claim_tab(state, tab_id, url, title) do
    Tabs.claim(
      state.project_id || state.thread_id,
      state.browser_id,
      tab_id,
      state.thread_id,
      session_title(state.thread_id)
    )

    tab = %{attached: false, refused: false, url: url, title: title, console: []}
    %{state | tabs: Map.put(state.tabs, tab_id, tab)}
  end

  defp forget_tab(state, tab_id) do
    Tabs.release(state.project_id || state.thread_id, state.browser_id, tab_id)
    %{state | tabs: Map.delete(state.tabs, tab_id)}
  end

  defp put_tab(state, tab_id, tab), do: %{state | tabs: Map.put(state.tabs, tab_id, tab)}

  ## Events from the extension

  defp on_event(state, "chrome.debugger.onEvent", [%{"tabId" => tab_id}, method, params]) do
    case state.tabs[tab_id] do
      nil -> state
      tab -> put_tab(state, tab_id, console(tab, method, params))
    end
  end

  defp on_event(state, "chrome.debugger.onDetach", [%{"tabId" => tab_id}, reason]) do
    case state.tabs[tab_id] do
      nil ->
        state

      tab ->
        put_tab(state, tab_id, %{tab | attached: false, refused: reason == "canceled_by_user"})
    end
  end

  defp on_event(state, "chrome.tabs.onRemoved", [tab_id | _]) when is_integer(tab_id) do
    if Map.has_key?(state.tabs, tab_id), do: forget_tab(state, tab_id), else: state
  end

  defp on_event(state, "chrome.tabs.onUpdated", [tab_id, _change, tab])
       when is_integer(tab_id) and is_map(tab) do
    case state.tabs[tab_id] do
      nil -> state
      t -> put_tab(state, tab_id, %{t | url: tab["url"] || t.url, title: tab["title"] || t.title})
    end
  end

  defp on_event(state, _method, _params), do: state

  defp console(tab, "Runtime.consoleAPICalled", %{"type" => type} = params) do
    text = params["args"] |> List.wrap() |> Enum.map_join(" ", &remote_object/1)
    push_console(tab, %{"kind" => "console", "level" => type, "text" => text})
  end

  defp console(tab, "Runtime.exceptionThrown", %{"exceptionDetails" => details}) do
    text = details["exception"]["description"] || details["text"] || "exception"
    push_console(tab, %{"kind" => "exception", "level" => "error", "text" => text})
  end

  defp console(tab, "Log.entryAdded", %{"entry" => entry}) do
    push_console(tab, %{
      "kind" => "log",
      "level" => entry["level"] || "info",
      "text" => entry["text"] || "",
      "source" => entry["source"],
      "url" => entry["url"]
    })
  end

  defp console(tab, _method, _params), do: tab

  defp push_console(tab, entry) do
    entry = Map.put(entry, "at", DateTime.utc_now() |> DateTime.to_iso8601())
    %{tab | console: Enum.take([entry | tab.console], @console_keep)}
  end

  defp remote_object(%{"value" => value}) when is_binary(value), do: value
  defp remote_object(%{"value" => value}), do: Jason.encode!(value)
  defp remote_object(%{"description" => d}) when is_binary(d), do: d
  defp remote_object(%{"unserializableValue" => u}), do: to_string(u)
  defp remote_object(%{"type" => type}), do: "[#{type}]"
  defp remote_object(other), do: inspect(other)

  defp describe(:offline), do: "the browser is not connected"
  defp describe(:timeout), do: "the browser did not answer in time"
  defp describe(:pending), do: "the browser is not approved yet"
  defp describe(other), do: inspect(other)
end
