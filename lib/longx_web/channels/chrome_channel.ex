defmodule LongxWeb.ChromeChannel do
  @moduledoc """
  `chrome:bridge` — one connected Longx Chrome extension. The join pairs
  (`Longx.Chrome.connect/3`) and answers `%{browser_id, status, name}`;
  `status` is `pending` until the person allows the browser (an
  `"approved"` push carries the token then), `approved`, or `bad_token`
  (the extension forgets its token and joins again).

  From then on this process is the browser's line
  (`Longx.Chrome.Connection`): a `{:cmd, method, params}` call pushes
  `"cmd"` `%{id, method, params}` to the extension and is answered when its
  `"result"` `%{id, result | error}` comes back; the extension's `"event"`
  pushes (`chrome.debugger.onEvent`, tab events) are broadcast as
  `{:chrome_event, browser_id, method, params}` on
  `Longx.Chrome.events_topic/1`.
  """

  use Phoenix.Channel

  alias Longx.Chrome
  alias Longx.Chrome.Connection
  alias LongxWeb.Wire

  @impl true
  def join("chrome:bridge", _payload, socket) do
    %{install_id: install_id, token: token, device: device} = socket.assigns

    case Chrome.connect(install_id, token, device) do
      {:ok, browser} ->
        status = if browser.status == :approved, do: :approved, else: :pending
        :ok = Connection.register(browser.id, status)
        Chrome.changed()

        {:ok,
         %{
           "browser_id" => browser.id,
           "status" => Atom.to_string(status),
           "name" => browser.name
         }, assign(socket, browser_id: browser.id, pending: %{}, next: 0)}

      {:error, :bad_token} ->
        {:ok, %{"status" => "bad_token"}, assign(socket, browser_id: nil, pending: %{}, next: 0)}

      {:error, :bad_request} ->
        {:error, %{reason: "install_id and device are needed"}}
    end
  end

  @impl true
  def handle_in("result", %{"id" => id} = payload, socket) do
    {from, pending} = Map.pop(socket.assigns.pending, id)

    if from do
      reply =
        case payload do
          %{"error" => error} when is_binary(error) -> {:error, error}
          %{"result" => result} -> {:ok, result}
          _ -> {:ok, nil}
        end

      GenServer.reply(from, reply)
    end

    {:noreply, assign(socket, :pending, pending)}
  end

  def handle_in("event", %{"method" => method} = payload, %{assigns: %{browser_id: id}} = socket)
      when is_binary(id) do
    params = Map.get(payload, "params") || []

    Phoenix.PubSub.broadcast(
      Longx.PubSub,
      Chrome.events_topic(id),
      {:chrome_event, id, method, params}
    )

    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_call({:cmd, method, params}, from, socket) do
    id = "k#{socket.assigns.next + 1}"
    push(socket, "cmd", Wire.clean(%{"id" => id, "method" => method, "params" => params}))

    {:noreply,
     socket
     |> assign(:next, socket.assigns.next + 1)
     |> assign(:pending, Map.put(socket.assigns.pending, id, from))}
  end

  @impl true
  def handle_info({:push, event, payload}, socket) do
    push(socket, event, Wire.clean(payload))
    {:noreply, socket}
  end

  # approved or revoked while connected (Longx.Chrome.Connection.mark/2)
  def handle_info({:mark, status}, %{assigns: %{browser_id: id}} = socket) when is_binary(id) do
    Connection.mark_here(id, status)
    {:noreply, socket}
  end

  # another connection of the same extension took over (Longx.Chrome.Connection.register/2)
  def handle_info(:superseded, socket), do: {:stop, :normal, socket}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    for {_id, from} <- Map.get(socket.assigns, :pending, %{}),
        do: GenServer.reply(from, {:error, :offline})

    if socket.assigns[:browser_id], do: Chrome.changed()
    :ok
  end
end
