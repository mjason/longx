defmodule Longx.Agent.Plugs.WebSearch do
  @moduledoc """
  Web search, two ways, one plug. `mode:` is `:auto` (the default),
  `:hosted`, `:standalone` or `:off`:

    * **hosted** — the model's provider searches (and reads) on its side:
      OpenAI's `web_search`, 百炼 for Qwen 3.5+ / DeepSeek-v4 / glm-5.2
      (`Longx.AI.web_search_mode/1`: `Model.hosted_web_search`, else the
      provider's `supports_hosted_web_search`). The request carries codex's
      `{"type": "web_search", "external_web_access": true}` and no function;
      the kernel shows the provider's `web_search_call` items as `webSearch`
      rows and hangs the message's `url_citation`s on them as results.
    * **standalone** — every other model gets `web_search(query)` over
      `Longx.AI.Search` (Tavily, the search provider of Settings → 联网搜索);
      no provider configured is said inside the result, never an error.

  The thread's own switch (a new chat's 联网搜索) arrives as
  `assigns.web_search`; `false` mounts nothing. Reading a page is
  `Longx.Agent.Plugs.Browser`'s `web_fetch`, in every mode.
  """

  use Longx.Agent.Plug

  alias Longx.AI
  alias Longx.AI.Search

  @hosted_tool %{"type" => "web_search", "external_web_access" => true}

  tool :web_search,
       "Searches the web and returns the top results (title, URL, snippet). Open a result with web_fetch.",
       show: :web_search,
       timeout: 90_000 do
    param :query, :string, "What to search for", required: true
    param :recency_days, :integer, "Only results from the last N days"
    param :domains, {:array, :string}, "Only results from these domains"
  end

  @impl true
  def init(opts), do: Keyword.get(opts, :mode, :auto)

  @impl true
  def call(%Step{phase: :request, assigns: %{web_search: false}} = step, _mode), do: step

  def call(%Step{phase: :request} = step, mode) do
    case resolve(mode, step.model) do
      :hosted -> Step.raw_tool(step, @hosted_tool)
      :standalone -> Longx.Agent.Plug.mount(step, __MODULE__)
      :off -> step
    end
  end

  def call(step, _mode), do: step

  defp resolve(:auto, model), do: AI.web_search_mode(model)
  defp resolve(mode, _model), do: mode

  def web_search(%{"query" => query} = args, ctx) do
    target =
      case AI.resolve_search_target() do
        {:ok, target} -> target
        {:error, _} -> nil
      end

    q =
      %{"q" => query}
      |> put_if("recency", args["recency_days"])
      |> put_if("domains", args["domains"])

    {:ok, %{output: output, results: results}} =
      Search.run(
        %{"id" => ctx.thread_id || "agent", "commands" => %{"search_query" => [q]}},
        target
      )

    {:ok, output,
     %{
       "results" =>
         Enum.map(results, &%{"title" => &1.title, "url" => &1.url, "snippet" => &1.snippet})
     }}
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
