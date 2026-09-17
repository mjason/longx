defmodule Longx.Agent.WebSearchTest do
  # the default search provider is a row: not async
  use Longx.DataCase, async: false

  alias Longx.Agent.{Context, Step, Tool}
  alias Longx.Agent.Plugs.{Browser, WebSearch}
  alias Longx.AI

  setup do
    Ash.bulk_destroy!(AI.SearchProvider, :destroy, %{}, authorize?: false)
    bypass = Bypass.open()
    %{bypass: bypass, ctx: %Context{cwd: System.tmp_dir!(), thread_id: "t1"}}
  end

  defp tavily!(bypass) do
    sp =
      AI.create_search_provider!(%{
        name: "Tavily",
        slug: "tavily-#{System.unique_integer([:positive])}",
        kind: :tavily,
        base_url: "http://localhost:#{bypass.port}",
        api_key: "tvly-x"
      })

    AI.make_default_search_provider!(sp)
  end

  defp tool!(module, name),
    do: Enum.find(module.__agent_tools__(), &(&1.name == name)) || flunk("no tool #{name}")

  test "standalone: web_search asks the search provider and returns titled results", %{
    bypass: bypass,
    ctx: ctx
  } do
    tavily!(bypass)

    Bypass.expect_once(bypass, "POST", "/search", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert %{"query" => "elixir 1.19", "max_results" => 5} = Jason.decode!(raw)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          results: [
            %{title: "Elixir 1.19", url: "https://elixir-lang.org/x", content: "the release"}
          ]
        })
      )
    end)

    tool = tool!(WebSearch, "web_search")
    assert tool.show == :web_search

    assert {:ok, output,
            %{
              "results" => [
                %{
                  "title" => "Elixir 1.19",
                  "url" => "https://elixir-lang.org/x",
                  "snippet" => "the release"
                }
              ]
            }} =
             Tool.call(tool, %{"query" => "elixir 1.19"}, ctx)

    assert output =~ "Elixir 1.19 — https://elixir-lang.org/x"
  end

  test "standalone without a search provider says so in the result, no error", %{ctx: ctx} do
    assert {:ok, output, %{"results" => []}} =
             Tool.call(tool!(WebSearch, "web_search"), %{"query" => "x"}, ctx)

    assert output =~ "no search provider"
  end

  test "the plug picks the mode from the model: hosted puts the provider's tool on the request, standalone the function" do
    hosted = WebSearch.call(Step.new(phase: :request), WebSearch.init(mode: :hosted))
    assert hosted.raw_tools == [%{"type" => "web_search", "external_web_access" => true}]
    assert hosted.tools == %{}

    standalone = WebSearch.call(Step.new(phase: :request), WebSearch.init(mode: :standalone))
    assert Map.keys(standalone.tools) == ["web_search"]
    assert standalone.raw_tools == []

    off =
      WebSearch.call(Step.new(phase: :request, assigns: %{web_search: false}), WebSearch.init([]))

    assert off.tools == %{} and off.raw_tools == []

    # auto with the seeded default model (no hosted search): standalone
    auto = WebSearch.call(Step.new(phase: :request), WebSearch.init([]))
    assert Map.keys(auto.tools) == ["web_search"]
  end

  test "web_fetch renders a page through the browser and returns markdown with the page as a result",
       %{ctx: ctx} do
    previous = Application.get_env(:longx, Longx.Browser, [])

    Application.put_env(
      :longx,
      Longx.Browser,
      Keyword.put(previous, :executable, Path.expand("test/support/fake_obscura.sh"))
    )

    on_exit(fn -> Application.put_env(:longx, Longx.Browser, previous) end)

    tool = tool!(Browser, "web_fetch")
    assert tool.show == :web_search

    assert {:ok, text, %{"results" => [%{"url" => "https://example.test/page"}]}} =
             Tool.call(tool, %{"url" => "https://example.test/page"}, ctx)

    assert text =~ "# "
    assert {:error, message} = Tool.call(tool, %{"url" => "ftp://nope"}, ctx)
    assert message =~ "http"
  end
end
