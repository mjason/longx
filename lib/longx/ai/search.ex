defmodule Longx.AI.Search do
  @moduledoc """
  One web search against a `Longx.AI.SearchTarget` (Tavily) for the
  kernel's standalone `web_search` tool (`Longx.Agent.Plugs.WebSearch`).
  Reading a page is the browser's job (`Longx.Agent.Plugs.Browser`).

  `search/3` answers `{:ok, %{output, results}}`: `output` is the text
  handed to the model (numbered results with title, URL, date and
  snippet; capped at `max_output_tokens`), `results` the structured
  records the UI shows. Nothing here is ever an error: no provider, a
  refused request or a dead upstream are said inside the output so the
  model can adapt.
  """

  alias Longx.AI.Search.Tavily
  alias Longx.AI.SearchTarget

  require Logger

  @default_max_results 5
  @default_output_tokens 4_000
  @chars_per_token 4

  @type result :: %{
          type: String.t(),
          query: String.t(),
          title: String.t(),
          url: String.t(),
          snippet: String.t(),
          published_at: String.t() | nil
        }
  @type option ::
          {:recency_days, pos_integer | nil}
          | {:domains, [String.t()] | nil}
          | {:max_results, pos_integer}
          | {:max_output_tokens, pos_integer}

  @spec search(SearchTarget.t() | nil, String.t(), [option]) ::
          {:ok, %{output: String.t(), results: [result]}}
  def search(target, query, opts \\ [])

  def search(nil, query, _opts) do
    {:ok,
     %{
       output:
         "## search: #{inspect(query)}\nno search provider is configured in Longx; open URLs you already know with web_fetch instead.",
       results: []
     }}
  end

  def search(%SearchTarget{} = target, query, opts) when is_binary(query) do
    budget = Keyword.get(opts, :max_output_tokens, @default_output_tokens) * @chars_per_token

    tavily_opts = [
      max_results: Keyword.get(opts, :max_results, @default_max_results),
      time_range: time_range(opts[:recency_days]),
      include_domains: opts[:domains]
    ]

    case Tavily.search(target, query, tavily_opts) do
      {:ok, []} ->
        {:ok, %{output: "## search: #{inspect(query)}\nno results.", results: []}}

      {:ok, results} ->
        {:ok, format(query, results, budget)}

      {:error, reason} ->
        Logger.warning("web search failed for #{inspect(query)}: #{inspect(reason)}")

        {:ok,
         %{
           output: "## search: #{inspect(query)}\nsearch failed: #{describe_error(reason)}",
           results: []
         }}
    end
  end

  defp time_range(nil), do: nil
  defp time_range(days) when days <= 1, do: "day"
  defp time_range(days) when days <= 7, do: "week"
  defp time_range(days) when days <= 31, do: "month"
  defp time_range(_), do: "year"

  defp format(query, results, budget) do
    {lines, records} =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} ->
        date = if r.published_date, do: " (#{r.published_date})", else: ""

        {"#{i}. #{r.title} — #{r.url}#{date}\n#{r.content}",
         %{
           type: "search",
           query: query,
           title: r.title,
           url: r.url,
           snippet: r.content,
           published_at: r.published_date
         }}
      end)
      |> Enum.unzip()

    %{
      output: cap("## search: #{inspect(query)}\n" <> Enum.join(lines, "\n\n"), budget),
      results: records
    }
  end

  defp cap(output, budget) when byte_size(output) <= budget, do: output

  defp cap(output, budget),
    do: String.slice(output, 0, budget) <> "\n\n[truncated: output exceeded the token budget]"

  defp describe_error({:status, status, body}),
    do: "upstream returned #{status}: #{inspect(body) |> String.slice(0, 200)}"

  defp describe_error(%{__exception__: true} = e), do: Exception.message(e)
  defp describe_error(other), do: inspect(other)
end
