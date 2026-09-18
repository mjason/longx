defmodule Longx.Credentials.AgentTest do
  @moduledoc """
  Credentials through a running agent (Bypass as the model, Bypass as the
  OAuth server): a login the person completes in the browser answers the
  waiting tool by itself; a key the person types into an ask never
  reaches the model.
  """
  use Longx.DataCase, async: false

  alias Longx.Agent
  alias Longx.Agent.ThreadState
  alias Longx.AI
  alias Longx.Credentials
  alias Longx.Credentials.{Credential, OAuth}
  alias Longx.Test.ResponsesFixture

  defmodule Pipeline do
    use Longx.Agent.Pipeline
    plug Longx.Agent.Plugs.Credentials
    plug Longx.Agent.Plugs.Request
  end

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Longx.Agent.Supervisor),
          is_pid(pid),
          do: safe_stop(pid)
    end)

    Ash.bulk_destroy!(Credential, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Model, :destroy, %{}, authorize?: false)
    Ash.bulk_destroy!(AI.Provider, :destroy, %{}, authorize?: false)

    model_bypass = Bypass.open()
    oauth = Bypass.open()
    # a login probes the authorize endpoint first (a rejected client is replaced)
    Bypass.stub(oauth, "GET", "/authorize", &Plug.Conn.send_resp(&1, 302, ""))

    for path <- ["/.well-known/oauth-authorization-server", "/.well-known/openid-configuration"],
        do: Bypass.stub(oauth, "GET", path, &Plug.Conn.send_resp(&1, 404, ""))

    n = System.unique_integer([:positive])

    provider =
      AI.create_provider!(%{
        name: "Upstream #{n}",
        slug: "upstream-#{n}",
        base_url: "http://localhost:#{model_bypass.port}/v1",
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

    dir = Path.join(System.tmp_dir!(), "longx-cred-agent-#{n}")
    File.mkdir_p!(dir)
    id = "cred-agent-#{n}"
    :ok = ThreadState.subscribe(id)

    on_exit(fn ->
      Agent.stop(id)
      ThreadState.stop(id)
      ThreadState.Store.delete(id)
      File.rm_rf!(dir)
    end)

    {:ok, _} = Agent.ensure(thread_id: id, cwd: dir, project_id: "p1", pipeline: Pipeline)
    %{model: model_bypass, oauth: oauth, base: "http://localhost:#{oauth.port}", id: id}
  end

  test "credential_login: the ask carries the authorize URL; the browser's return through /callback/credentials answers it; the model learns only that it worked",
       %{model: model, oauth: oauth, base: base, id: id} do
    {:ok, _} =
      Credentials.create_oauth2(%{
        name: "oa",
        allowed_hosts: ["localhost"],
        authorize_url: base <> "/authorize",
        token_url: base <> "/token",
        client_id: "cid"
      })

    route!(model, fn body ->
      if List.last(body["input"])["type"] == "function_call_output",
        do: ResponsesFixture.assistant_message("done"),
        else: ResponsesFixture.function_call("credential_login", nil, %{"credential" => "oa"})
    end)

    Bypass.expect_once(oauth, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{access_token: "at-secret", refresh_token: "rt", expires_in: 3600})
      )
    end)

    {:ok, _} = Agent.send(id, "log in to coros")

    assert %{"requestId" => rid, "title" => title, "url" => url, "meta" => %{"login" => state}} =
             await("longx/action/request")

    assert title =~ "oa"
    assert String.starts_with?(url, base <> "/authorize?")
    assert URI.decode_query(URI.parse(url).query)["state"] == state
    assert [%{id: ^rid}] = ThreadState.snapshot(id).pending_requests

    # the browser comes back (what LongxWeb.CallbackController does with the query)
    assert {:ok, %Credential{}} = OAuth.complete(state, %{"code" => "the-code", "state" => state})

    assert %{"status" => "completed"} = await_turn_end()
    assert ThreadState.snapshot(id).pending_requests == []

    requests = collect_requests([])
    last = List.last(requests)

    assert [%{"output" => output}] =
             Enum.filter(last["input"], &(&1["type"] == "function_call_output"))

    assert output =~ "logged in"
    refute Enum.any?(requests, &(inspect(&1) =~ "at-secret"))
    assert {:ok, %{access_token: "at-secret"}} = Credentials.reveal("oa")
  end

  test "credential_create: the key is typed into the ask's masked field and stored; the model never sees it",
       %{model: model, id: id} do
    route!(model, fn body ->
      if List.last(body["input"])["type"] == "function_call_output",
        do: ResponsesFixture.assistant_message("saved"),
        else:
          ResponsesFixture.function_call("credential_create", nil, %{
            "name" => "svc",
            "kind" => "api_key",
            "allowed_hosts" => ["api.example"],
            "header" => "x-api-key",
            "scheme" => ""
          })
    end)

    {:ok, _} = Agent.send(id, "store my key")

    assert %{"requestId" => rid, "fields" => [%{"id" => "secret", "secret" => true}]} =
             await("longx/action/request")

    assert :ok = Agent.respond(id, rid, %{"secret" => "sk-typed-by-person"})
    assert %{"status" => "completed"} = await_turn_end()

    requests = collect_requests([])
    refute Enum.any?(requests, &(inspect(&1) =~ "sk-typed-by-person"))
    last = List.last(requests)

    assert [%{"output" => output}] =
             Enum.filter(last["input"], &(&1["type"] == "function_call_output"))

    assert output =~ "svc"
    assert output =~ "api.example"

    assert {:ok, %{secret: "sk-typed-by-person", header: "x-api-key", scheme: ""}} =
             Credentials.reveal("svc")
  end

  test "credential_create for an OAuth2 public client: the client secret field is optional, left empty it stores none",
       %{model: model, id: id} do
    route!(model, fn body ->
      if List.last(body["input"])["type"] == "function_call_output",
        do: ResponsesFixture.assistant_message("saved"),
        else:
          ResponsesFixture.function_call("credential_create", nil, %{
            "name" => "coros",
            "kind" => "oauth2",
            "allowed_hosts" => ["mcpcn.coros.com"],
            "authorize_url" => "https://mcpcn.coros.com/oauth2/authorize",
            "token_url" => "https://mcpcn.coros.com/oauth2/token",
            "client_id" => "47c53db0"
          })
    end)

    {:ok, _} = Agent.send(id, "create the coros credential")

    assert %{"requestId" => rid, "fields" => [field]} = await("longx/action/request")
    assert %{"id" => "client_secret", "secret" => true, "required" => false} = field

    assert :ok = Agent.respond(id, rid, %{"client_secret" => ""})
    assert %{"status" => "completed"} = await_turn_end()
    assert {:ok, %{client_id: "47c53db0", client_secret: nil}} = Credentials.reveal("coros")
  end

  ## helpers (the agent test's, in short)

  defp sse(conn, chunks) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk, c ->
      {:ok, c} = Plug.Conn.chunk(c, chunk)
      c
    end)
  end

  defp route!(bypass, fun) do
    test = self()

    Bypass.expect(bypass, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      send(test, {:request, body})
      sse(conn, fun.(body))
    end)
  end

  defp await(method, timeout \\ 5_000) do
    receive do
      {:thread, _seq, ^method, params} -> params
    after
      timeout -> flunk("no #{method}")
    end
  end

  defp await_turn_end, do: await("turn/completed")["turn"]

  defp collect_requests(acc) do
    receive do
      {:request, body} -> collect_requests([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp safe_stop(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end
end
