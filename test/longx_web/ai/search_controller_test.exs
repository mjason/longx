defmodule LongxWeb.AI.SearchControllerTest do
  use LongxWeb.ConnCase, async: false

  alias Longx.AI
  alias Longx.AI.Gateway.Token

  @path "/ai/v1/alpha/search"

  setup do
    Ash.bulk_destroy!(AI.SearchProvider, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()
    %{bypass: bypass}
  end

  defp configure!(bypass, attrs \\ %{}) do
    sp =
      AI.create_search_provider!(
        Map.merge(
          %{
            name: "Tavily",
            slug: "tavily-#{System.unique_integer([:positive])}",
            kind: :tavily,
            base_url: "http://localhost:#{bypass.port}",
            api_key: "tvly-x"
          },
          attrs
        )
      )

    AI.make_default_search_provider!(sp)
  end

  defp post_search(conn, body) do
    conn
    |> put_req_header("authorization", "Bearer #{Token.current()}")
    |> put_req_header("content-type", "application/json")
    |> post(@path, Jason.encode!(body))
  end

  # what codex's SearchClient sends (codex-api/src/search.rs)
  @request %{
    "id" => "session-1",
    "model" => "longx",
    "input" => [],
    "commands" => %{"search_query" => [%{"q" => "elixir"}]},
    "max_output_tokens" => 2_000
  }

  test "requires the gateway token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(@path, Jason.encode!(@request))

    assert json_response(conn, 401)
  end

  test "runs the commands and answers with output + results", %{conn: conn, bypass: bypass} do
    configure!(bypass)

    Bypass.expect_once(bypass, "POST", "/search", fn up ->
      up
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "results" => [
            %{"title" => "Elixir", "url" => "https://elixir-lang.org", "content" => "A language"}
          ]
        })
      )
    end)

    conn = post_search(conn, @request)
    assert %{"output" => output, "results" => [result]} = json_response(conn, 200)
    assert output =~ "https://elixir-lang.org"
    assert result["type"] == "search"
    assert result["url"] == "https://elixir-lang.org"
  end

  test "without a configured search provider a search says so (200, not an error), while open still works through the browser",
       %{conn: conn} do
    conn2 = post_search(conn, @request)
    assert %{"output" => output, "results" => []} = json_response(conn2, 200)
    assert output =~ "no search provider"

    previous = Application.get_env(:longx, Longx.Browser, [])

    Application.put_env(
      :longx,
      Longx.Browser,
      Keyword.put(previous, :executable, Path.expand("test/support/fake_obscura.sh"))
    )

    on_exit(fn -> Application.put_env(:longx, Longx.Browser, previous) end)

    conn3 =
      post_search(conn, %{
        "id" => "s",
        "commands" => %{"open" => [%{"ref_id" => "https://spa.test/app"}]}
      })

    assert %{"output" => output3, "results" => [%{"type" => "open"}]} = json_response(conn3, 200)
    assert output3 =~ "<h1>Rendered</h1>"
  end

  test "a provider without a key is reported the same way", %{conn: conn, bypass: bypass} do
    configure!(bypass, %{api_key: nil})
    conn = post_search(conn, @request)
    assert %{"output" => output} = json_response(conn, 200)
    assert output =~ "no search provider"
  end

  test "400 for a body without commands", %{conn: conn, bypass: bypass} do
    configure!(bypass)
    conn = post_search(conn, %{"nope" => true})
    assert json_response(conn, 400)
  end
end
