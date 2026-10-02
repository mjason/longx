defmodule LongxWeb.ChromeChannelTest do
  # the extension's side of the bridge, played by the test process
  use LongxWeb.ChannelCase, async: false

  alias Longx.Chrome
  alias Longx.Chrome.Connection

  @device %{"name" => "Test Chrome", "platform" => "linux", "extension" => "0.1.0"}

  setup do
    for b <- Chrome.list_browsers!(), do: :ok = Chrome.destroy_browser(b)
    :ok
  end

  defp join!(install_id, token \\ nil) do
    params = %{"install_id" => install_id, "device" => @device}
    params = if token, do: Map.put(params, "token", token), else: params
    {:ok, socket} = connect(LongxWeb.ChromeSocket, params)
    subscribe_and_join(socket, "chrome:bridge", %{})
  end

  test "a new extension joins as pending, is told when the person allows it, and joins approved with the token" do
    assert {:ok, %{"status" => "pending", "browser_id" => id}, _socket} = join!("ext-1")
    refute Chrome.online?(id)
    assert Connection.connected?(id)

    assert {:ok, _, token} = Chrome.approve(id)
    assert_push "approved", %{"token" => ^token}
    assert Chrome.online?(id)

    # a fresh connection with the token (what the extension does after storing it)
    assert {:ok, %{"status" => "approved", "browser_id" => ^id}, _} = join!("ext-1", token)
    assert {:ok, %{"status" => "bad_token"}, _} = join!("ext-1", "wrong")
  end

  test "a command goes out as a cmd push and the result comes back to the caller" do
    {:ok, %{"browser_id" => id}, socket} = join!("ext-2")
    {:ok, _, _} = Chrome.approve(id)
    assert_push "approved", _

    task =
      Task.async(fn -> Connection.call(id, "chrome.tabs.query", [%{"groupId" => 3}], 5_000) end)

    assert_push "cmd", %{
      "id" => cmd_id,
      "method" => "chrome.tabs.query",
      "params" => [%{"groupId" => 3}]
    }

    push(socket, "result", %{"id" => cmd_id, "result" => [%{"id" => 12, "url" => "about:blank"}]})
    assert {:ok, [%{"id" => 12, "url" => "about:blank"}]} = Task.await(task)

    task =
      Task.async(fn ->
        Connection.call(id, "chrome.debugger.attach", [%{"tabId" => 12}, "1.3"], 5_000)
      end)

    assert_push "cmd", %{"id" => cmd_id, "method" => "chrome.debugger.attach"}
    push(socket, "result", %{"id" => cmd_id, "error" => "Cannot access a chrome:// URL"})
    assert {:error, "Cannot access a chrome:// URL"} = Task.await(task)
  end

  test "a pending browser takes no commands; an unknown one is offline; a gone one fails the waiting call" do
    {:ok, %{"browser_id" => id}, socket} = join!("ext-3")
    assert {:error, :pending} = Connection.call(id, "chrome.tabs.query", [%{}])
    assert {:error, :offline} = Connection.call("nobody", "chrome.tabs.query", [%{}])

    {:ok, _, _} = Chrome.approve(id)
    assert_push "approved", _
    task = Task.async(fn -> Connection.call(id, "chrome.tabs.query", [%{}], 5_000) end)
    assert_push "cmd", _
    Process.unlink(socket.channel_pid)
    ref = Process.monitor(socket.channel_pid)
    leave(socket)
    assert {:error, :offline} = Task.await(task)
    assert_receive {:DOWN, ^ref, :process, _, _}
    refute Connection.connected?(id)
  end

  test "the extension's events are broadcast on the browser's topic" do
    {:ok, %{"browser_id" => id}, socket} = join!("ext-4")
    Phoenix.PubSub.subscribe(Longx.PubSub, Chrome.events_topic(id))

    push(socket, "event", %{
      "method" => "chrome.debugger.onEvent",
      "params" => [%{"tabId" => 12}, "Runtime.consoleAPICalled", %{"type" => "log"}]
    })

    assert_receive {:chrome_event, ^id, "chrome.debugger.onEvent",
                    [%{"tabId" => 12}, "Runtime.consoleAPICalled", %{"type" => "log"}]}
  end

  test "revoking tells the extension" do
    {:ok, %{"browser_id" => id}, _socket} = join!("ext-5")
    {:ok, _, _} = Chrome.approve(id)
    assert_push "approved", _
    {:ok, _} = Chrome.revoke(id)
    assert_push "revoked", %{}
    refute Chrome.online?(id)
  end

  test "deleting an online browser tells the extension and refuses further commands" do
    {:ok, %{"browser_id" => id}, _socket} = join!("ext-delete")
    {:ok, _, _} = Chrome.approve(id)
    assert_push "approved", _
    assert :ok = Chrome.delete(id)
    assert_push "revoked", %{}
    assert {:error, :pending} = Connection.call(id, "chrome.tabs.query", [%{}])
    assert {:error, _} = Chrome.get_browser(id)
  end

  test "a socket without an install id is refused" do
    assert :error = connect(LongxWeb.ChromeSocket, %{"device" => @device})
  end

  test "connection IP comes from the transport, never from extension claims" do
    params = %{"install_id" => "ip-test", "device" => Map.put(@device, "peer_ip", "spoofed")}

    assert {:ok, socket} =
             connect(LongxWeb.ChromeSocket, params,
               connect_info: %{peer_data: %{address: {192, 168, 1, 42}}}
             )

    assert {:ok, %{"browser_id" => id}, _} = subscribe_and_join(socket, "chrome:bridge", %{})
    assert {:ok, %{device: %{"peer_ip" => "192.168.1.42"}}} = Chrome.get_browser(id)
  end
end
