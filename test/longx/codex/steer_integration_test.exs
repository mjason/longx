defmodule Longx.Codex.SteerIntegrationTest do
  @moduledoc """
  `turn/steer` against the real binary through our gateway (a `Bypass`
  plays the model): a message sent while a turn runs is shown on that turn
  as a user message and reaches the model at its next request — no second
  turn. This is what the Codex app does when you type during a run.
  """
  use Longx.DataCase, async: false

  import Longx.Test.CodexHarness

  alias Longx.Codex.{Connection, Thread, ThreadState}
  alias Longx.Test.ResponsesFixture

  @moduletag :integration

  setup do
    Ash.bulk_destroy!(Longx.AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(Longx.AI.Provider, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()

    {:ok, provider} =
      Longx.AI.create_provider(%{
        name: "Fake",
        slug: "fake",
        base_url: "http://localhost:#{bypass.port}/v1",
        api_key: "k"
      })

    {:ok, model} =
      Longx.AI.create_model(%{
        name: "Fake",
        upstream_id: "fake-model",
        provider_id: provider.id,
        context_window: 128_000
      })

    {:ok, _} = Longx.AI.make_default_model(model)
    %{bypass: bypass, gateway_url: serve_endpoint!()}
  end

  defp send_sse(conn, frames) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    Enum.reduce(frames, conn, fn frame, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, frame)
      conn
    end)
  end

  defp drain_requests(acc) do
    receive do
      {:request, body} -> drain_requests([body | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end

  defp user_texts(input) do
    for %{"role" => "user", "content" => c} <- input, is_list(c), %{"text" => t} <- c, do: t
  end

  test "a message steered into a running turn shows on that turn and reaches the model at its next request",
       %{bypass: bypass, gateway_url: gateway_url} do
    test_pid = self()

    # the first answer is held until the test has steered, then it is a tool
    # call (so codex asks the model again); the second answer ends the turn
    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:request, body})

      if Enum.any?(body["input"], &(&1["type"] == "function_call_output")) do
        send_sse(conn, ResponsesFixture.assistant_message("done"))
      else
        receive do
          :go -> :ok
        after
          20_000 -> :ok
        end

        send_sse(conn, ResponsesFixture.function_call("echo", "test", %{message: "hi"}))
      end
    end)

    home = prepare_home!(gateway_url)
    conn = start_connection!(home)

    params =
      Thread.start_params(
        cwd: home.dir,
        sandbox: :workspace_write,
        tools: [Longx.Test.Tools.Echo]
      )

    {:ok, %{"thread" => %{"id" => thread_id}}} = Connection.request(conn, "thread/start", params)
    {:ok, _} = ThreadState.ensure(thread_id)
    :ok = Thread.subscribe(thread_id)

    {:ok, turn_id} = Thread.send(thread_id, "start the work", conn: conn)
    assert_receive {:request, _first}, 20_000

    # while the model "thinks": the second message goes into the turn
    assert :ok = Thread.steer(thread_id, turn_id, "also check the README", conn: conn)
    send(test_pid, :go)

    # the model's second request carries it; then the turn ends
    assert_receive {:codex, _, "turn/completed", %{"turn" => %{"id" => ^turn_id}}}, 30_000

    # the steered message is a user message on the same turn, after the tool call
    items = ThreadState.snapshot(thread_id).items
    assert Enum.uniq(Enum.map(items, & &1["turnId"])) == [turn_id]
    texts = for %{"type" => "userMessage", "content" => c} <- items, %{"text" => t} <- c, do: t
    assert texts == ["start the work", "also check the README"]

    # the request after the tool call carries the steered message as user input
    requests = drain_requests([])

    assert Enum.any?(requests, fn %{"input" => input} ->
             "also check the README" in user_texts(input)
           end),
           "no request carried the steered text; inputs: #{inspect(Enum.map(requests, &user_texts(&1["input"])))}"

    # a steer after the turn is refused
    assert {:error, %Longx.Codex.Error{message: message}} =
             Thread.steer(thread_id, turn_id, "late", conn: conn)

    assert message =~ "no active turn"
  end
end
