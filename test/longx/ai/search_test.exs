defmodule Longx.AI.SearchTest do
  @moduledoc """
  `Longx.AI.Search` executes codex's `web.run` commands against a search
  backend. Tavily is played by a Bypass.
  """
  use ExUnit.Case, async: true

  alias Longx.AI.{Search, SearchTarget}

  setup do
    bypass = Bypass.open()

    target = %SearchTarget{
      kind: :tavily,
      base_url: "http://localhost:#{bypass.port}",
      api_key: "tvly-test",
      provider_slug: "tavily"
    }

    %{bypass: bypass, target: target}
  end

  defp tavily_search(bypass, fun) do
    Bypass.expect(bypass, "POST", "/search", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      {status, resp} = fun.(conn.req_headers, body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(resp))
    end)
  end

  @tavily_results %{
    "results" => [
      %{
        "title" => "Elixir 1.19 released",
        "url" => "http://127.0.0.1:1/blog/1.19",
        "content" => "Elixir 1.19 ships type inference...",
        "score" => 0.91,
        "published_date" => "2026-06-01"
      },
      %{
        "title" => "Hex.pm",
        "url" => "https://hex.pm",
        "content" => "Package manager",
        "score" => 0.5
      }
    ],
    "response_time" => 0.4
  }

  describe "search_query" do
    test "queries Tavily with the codex filters mapped and returns referenced results", %{
      bypass: bypass,
      target: target
    } do
      test_pid = self()

      tavily_search(bypass, fn headers, body ->
        send(test_pid, {:tavily, headers, body})
        {200, @tavily_results}
      end)

      request = %{
        "id" => "session-#{System.unique_integer([:positive])}",
        "model" => "longx",
        "commands" => %{
          "search_query" => [
            %{"q" => "elixir 1.19 release", "recency" => 30, "domains" => ["elixir-lang.org"]}
          ]
        },
        "max_output_tokens" => 2_000
      }

      assert {:ok, %{output: output, results: results}} = Search.run(request, target)

      assert_receive {:tavily, headers, body}
      assert {"authorization", "Bearer tvly-test"} in headers
      assert body["query"] == "elixir 1.19 release"
      assert body["include_domains"] == ["elixir-lang.org"]
      assert body["time_range"] == "month"

      # the model sees reference ids, titles, urls and snippets
      assert output =~ "turn0search0"
      assert output =~ "Elixir 1.19 released"
      assert output =~ "http://127.0.0.1:1/blog/1.19"
      assert output =~ "type inference"
      assert output =~ "2026-06-01"

      # structured results for the UI
      assert [
               %{
                 type: "search",
                 query: "elixir 1.19 release",
                 ref_id: "turn0search0",
                 title: "Elixir 1.19 released",
                 url: "http://127.0.0.1:1/blog/1.19"
               }
               | _
             ] = results
    end

    test "recency maps to Tavily time ranges", %{bypass: bypass, target: target} do
      test_pid = self()

      tavily_search(bypass, fn _h, body ->
        send(test_pid, {:range, body["time_range"]})
        {200, %{"results" => []}}
      end)

      for {days, range} <- [{1, "day"}, {7, "week"}, {31, "month"}, {365, "year"}, {nil, nil}] do
        {:ok, _} =
          Search.run(
            %{"id" => "t", "commands" => %{"search_query" => [%{"q" => "x", "recency" => days}]}},
            target
          )

        assert_receive {:range, ^range}
      end
    end

    test "multiple queries run and are numbered per query", %{bypass: bypass, target: target} do
      tavily_search(bypass, fn _h, body ->
        {200,
         %{
           "results" => [
             %{
               "title" => "R for #{body["query"]}",
               "url" => "https://x/#{body["query"]}",
               "content" => "c"
             }
           ]
         }}
      end)

      {:ok, %{output: output, results: results}} =
        Search.run(
          %{
            "id" => "session-#{System.unique_integer([:positive])}",
            "commands" => %{"search_query" => [%{"q" => "a"}, %{"q" => "b"}]}
          },
          target
        )

      assert output =~ "turn0search0"
      assert output =~ "turn0search1"
      assert Enum.map(results, & &1.query) == ["a", "b"]
    end

    test "response_length controls how many results are asked for", %{
      bypass: bypass,
      target: target
    } do
      test_pid = self()

      tavily_search(bypass, fn _h, body ->
        send(test_pid, {:max, body["max_results"]})
        {200, %{"results" => []}}
      end)

      for {len, n} <- [{"short", 5}, {"medium", 8}, {"long", 10}, {nil, 5}] do
        cmds = %{"search_query" => [%{"q" => "x"}]}
        cmds = if len, do: Map.put(cmds, "response_length", len), else: cmds
        {:ok, _} = Search.run(%{"id" => "t", "commands" => cmds}, target)
        assert_receive {:max, ^n}
      end
    end

    test "upstream failure becomes readable output for the model, not a crash", %{
      bypass: bypass,
      target: target
    } do
      tavily_search(bypass, fn _h, _b -> {401, %{"detail" => %{"error" => "Unauthorized"}}} end)

      {:ok, %{output: output, results: []}} =
        Search.run(%{"id" => "t", "commands" => %{"search_query" => [%{"q" => "x"}]}}, target)

      assert output =~ "search failed"
      assert output =~ "401"
    end
  end

  describe "open" do
    test "resolves a ref_id from an earlier search in the same session and extracts the page", %{
      bypass: bypass,
      target: target
    } do
      tavily_search(bypass, fn _h, _b -> {200, @tavily_results} end)

      Bypass.expect_once(bypass, "POST", "/extract", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert %{"urls" => ["http://127.0.0.1:1/blog/1.19"], "format" => "markdown"} =
                 Jason.decode!(raw)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "results" => [
              %{
                "url" => "http://127.0.0.1:1/blog/1.19",
                "raw_content" => "# Elixir 1.19\n\nBig release."
              }
            ],
            "failed_results" => []
          })
        )
      end)

      session = "session-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Search.run(
          %{"id" => session, "commands" => %{"search_query" => [%{"q" => "elixir"}]}},
          target
        )

      {:ok, %{output: output, results: results}} =
        Search.run(
          %{"id" => session, "commands" => %{"open" => [%{"ref_id" => "turn0search0"}]}},
          target
        )

      assert output =~ "Big release."
      assert output =~ "http://127.0.0.1:1/blog/1.19"
      assert [%{type: "open", url: "http://127.0.0.1:1/blog/1.19"}] = results
    end

    test "opens a bare URL by fetching it ourselves — no search provider involved", %{
      bypass: bypass,
      target: target
    } do
      site = Bypass.open()

      Bypass.expect_once(site, "GET", "/page", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(
          200,
          "<html><title>Hex</title><body><main><p>hex packages</p></main></body></html>"
        )
      end)

      # Tavily must not be asked
      Bypass.stub(bypass, "POST", "/extract", fn conn -> Plug.Conn.send_resp(conn, 500, "no") end)
      url = "http://localhost:#{site.port}/page"

      {:ok, %{output: output, results: [result]}} =
        Search.run(%{"id" => "t", "commands" => %{"open" => [%{"ref_id" => url}]}}, target)

      assert output =~ "hex packages"
      assert output =~ "Hex"
      assert %{type: "open", url: ^url, title: "Hex"} = result

      # and it works with no search provider configured at all
      Bypass.expect_once(site, "GET", "/page", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "plain")
      end)

      {:ok, %{output: output2}} =
        Search.run(%{"id" => "t2", "commands" => %{"open" => [%{"ref_id" => url}]}}, nil)

      assert output2 =~ "plain"
    end

    test "when our fetch fails the search provider's extractor is the fallback; without one the failure is reported",
         %{bypass: bypass, target: target} do
      site = Bypass.open()
      Bypass.expect(site, "GET", "/blocked", fn conn -> Plug.Conn.send_resp(conn, 403, "bot") end)
      url = "http://localhost:#{site.port}/blocked"

      Bypass.expect_once(bypass, "POST", "/extract", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "results" => [%{"url" => url, "raw_content" => "via tavily"}],
            "failed_results" => []
          })
        )
      end)

      {:ok, %{output: output}} =
        Search.run(%{"id" => "t", "commands" => %{"open" => [%{"ref_id" => url}]}}, target)

      assert output =~ "via tavily"

      {:ok, %{output: output2, results: []}} =
        Search.run(%{"id" => "t", "commands" => %{"open" => [%{"ref_id" => url}]}}, nil)

      assert output2 =~ "403"
    end

    test "search_query without a search provider says so instead of failing" do
      {:ok, %{output: output, results: []}} =
        Search.run(%{"id" => "t", "commands" => %{"search_query" => [%{"q" => "elixir"}]}}, nil)

      assert output =~ "no search provider"
    end

    test "an unknown ref_id is reported, not fetched", %{target: target} do
      {:ok, %{output: output, results: []}} =
        Search.run(
          %{
            "id" => "fresh-#{System.unique_integer()}",
            "commands" => %{"open" => [%{"ref_id" => "turn9search9"}]}
          },
          target
        )

      assert output =~ "unknown reference"
    end
  end

  describe "other commands" do
    test "time is answered locally", %{target: target} do
      {:ok, %{output: output}} =
        Search.run(
          %{"id" => "t", "commands" => %{"time" => [%{"utc_offset" => "+08:00"}]}},
          target
        )

      assert output =~ "+08:00"
      assert output =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/
    end

    test "unsupported commands are named so the model can adapt", %{target: target} do
      {:ok, %{output: output}} =
        Search.run(
          %{
            "id" => "t",
            "commands" => %{
              "weather" => [%{"location" => "SF"}],
              "finance" => [%{"ticker" => "AMD"}]
            }
          },
          target
        )

      assert output =~ "weather"
      assert output =~ "finance"
      assert output =~ "not supported"
    end

    test "an empty command set is a no-op", %{target: target} do
      assert {:ok, %{output: output, results: []}} =
               Search.run(%{"id" => "t", "commands" => %{}}, target)

      assert output =~ "no commands"
    end
  end

  test "output is capped by max_output_tokens", %{bypass: bypass, target: target} do
    tavily_search(bypass, fn _h, _b ->
      {200,
       %{
         "results" =>
           for(
             i <- 1..20,
             do: %{
               "title" => "T#{i}",
               "url" => "https://x/#{i}",
               "content" => String.duplicate("word ", 300)
             }
           )
       }}
    end)

    {:ok, %{output: output}} =
      Search.run(
        %{
          "id" => "t",
          "commands" => %{"search_query" => [%{"q" => "x", "response_length" => "long"}]},
          "max_output_tokens" => 200
        },
        target
      )

    assert String.length(output) <= 200 * 4 + 100
    assert output =~ "truncated"
  end
end
