defmodule Longx.AI.SearchTest do
  @moduledoc """
  `Longx.AI.Search` runs one query against the search backend for the
  kernel's `web_search` tool. Tavily is played by a Bypass.
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

  test "queries Tavily with the filters mapped and returns numbered results", %{
    bypass: bypass,
    target: target
  } do
    test_pid = self()

    tavily_search(bypass, fn headers, body ->
      send(test_pid, {:tavily, headers, body})
      {200, @tavily_results}
    end)

    assert {:ok, %{output: output, results: results}} =
             Search.search(target, "elixir 1.19 release",
               recency_days: 30,
               domains: ["elixir-lang.org"],
               max_results: 5
             )

    assert_receive {:tavily, headers, body}
    assert {"authorization", "Bearer tvly-test"} in headers
    assert body["query"] == "elixir 1.19 release"
    assert body["include_domains"] == ["elixir-lang.org"]
    assert body["time_range"] == "month"
    assert body["max_results"] == 5

    # the model sees numbered titles, urls, dates and snippets
    assert output =~ "1. Elixir 1.19 released"
    assert output =~ "http://127.0.0.1:1/blog/1.19"
    assert output =~ "type inference"
    assert output =~ "2026-06-01"
    assert output =~ "2. Hex.pm"

    # structured results for the UI
    assert [
             %{
               type: "search",
               query: "elixir 1.19 release",
               title: "Elixir 1.19 released",
               url: "http://127.0.0.1:1/blog/1.19",
               snippet: "Elixir 1.19 ships type inference...",
               published_at: "2026-06-01"
             },
             %{title: "Hex.pm", published_at: nil}
           ] = results
  end

  test "recency maps to Tavily time ranges", %{bypass: bypass, target: target} do
    test_pid = self()

    tavily_search(bypass, fn _h, body ->
      send(test_pid, {:range, body["time_range"]})
      {200, %{"results" => []}}
    end)

    for {days, range} <- [{1, "day"}, {7, "week"}, {31, "month"}, {365, "year"}, {nil, nil}] do
      {:ok, %{output: output, results: []}} = Search.search(target, "x", recency_days: days)
      assert output =~ "no results"
      assert_receive {:range, ^range}
    end
  end

  test "upstream failure becomes readable output for the model, not a crash", %{
    bypass: bypass,
    target: target
  } do
    tavily_search(bypass, fn _h, _b -> {401, %{"detail" => %{"error" => "Unauthorized"}}} end)

    {:ok, %{output: output, results: []}} = Search.search(target, "x")
    assert output =~ "search failed"
    assert output =~ "401"
  end

  test "an unreachable upstream is said in the output too", %{bypass: bypass, target: target} do
    Bypass.down(bypass)
    {:ok, %{output: output, results: []}} = Search.search(target, "x")
    assert output =~ "search failed"
  end

  test "no search provider says so instead of failing" do
    {:ok, %{output: output, results: []}} = Search.search(nil, "elixir")
    assert output =~ "no search provider"
    assert output =~ "web_fetch"
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

    {:ok, %{output: output, results: results}} =
      Search.search(target, "x", max_results: 20, max_output_tokens: 200)

    assert byte_size(output) < 1_000
    assert output =~ "truncated"
    assert length(results) == 20
  end
end
