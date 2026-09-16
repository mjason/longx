defmodule Longx.AI.Search do
  @moduledoc """
  Executes the commands codex's standalone `web.run` tool sends to
  `POST /ai/v1/alpha/search` (see `codex-rs/ext/web-search` and
  `codex-api/src/search.rs`) against a `Longx.AI.SearchTarget`.

  Supported: `search_query` (with `recency`/`domains`), `open` (by reference
  id from an earlier call in the same session, or a URL — rendered by the
  bundled headless browser, `Longx.Browser`, nothing else), `time`. The other
  commands (`image_query`, `click`, `find`, `screenshot`, `finance`,
  `weather`, `sports`) are answered with a "not supported" line so the model
  can adapt instead of retrying.

  Returns `%{output, results}`: `output` is the text handed back to the model
  (capped by `max_output_tokens`), `results` are structured records codex
  passes through to the UI unchanged.
  """

  alias Longx.AI.Search.{Refs, Tavily}
  alias Longx.Browser
  alias Longx.AI.SearchTarget

  require Logger

  @unsupported ~w(image_query click find screenshot finance weather sports)
  @max_results %{"short" => 5, "medium" => 8, "long" => 10}
  @default_max_results 5
  @default_output_tokens 4_000
  @chars_per_token 4
  @max_page_chars 24_000
  @concurrency 4

  @type result :: map
  @spec run(map, SearchTarget.t() | nil) :: {:ok, %{output: String.t(), results: [result]}}
  def run(request, target)
      when is_map(request) and (is_nil(target) or is_struct(target, SearchTarget)) do
    session = request["id"] || "anonymous"
    commands = request["commands"] || %{}
    budget = (request["max_output_tokens"] || @default_output_tokens) * @chars_per_token

    if commands == %{} do
      {:ok, %{output: "web.run: no commands given.", results: []}}
    else
      turn = Refs.next_turn(session)
      sections = execute(commands, turn, session, target)

      {:ok,
       %{
         output: sections |> Enum.map(& &1.output) |> Enum.join("\n\n") |> cap(budget),
         results: Enum.flat_map(sections, & &1.results)
       }}
    end
  end

  defp execute(commands, turn, session, target) do
    Enum.flat_map(commands, fn
      {"search_query", queries} when is_list(queries) ->
        search(queries, commands["response_length"], turn, session, target)

      {"open", opens} when is_list(opens) ->
        open(opens, turn, session, target)

      {"time", zones} when is_list(zones) ->
        [time(zones)]

      {"response_length", _} ->
        []

      {name, _} when name in @unsupported ->
        [
          %{
            output:
              "## #{name}\n#{name} is not supported by this search provider; use search_query or open instead.",
            results: []
          }
        ]

      {name, _} ->
        [%{output: "## #{name}\nunknown command.", results: []}]
    end)
  end

  ## search_query

  defp search(queries, _response_length, _turn, _session, nil) do
    Enum.map(queries, fn query ->
      %{
        output:
          "## search_query: #{inspect(query["q"] || "")}\nno search provider is configured in Longx; open URLs you already know instead.",
        results: []
      }
    end)
  end

  defp search(queries, response_length, turn, session, target) do
    max_results = Map.get(@max_results, response_length, @default_max_results)

    queries
    |> Task.async_stream(
      fn query -> Tavily.search(target, query["q"] || "", search_opts(query, max_results)) end,
      max_concurrency: @concurrency,
      timeout: :timer.seconds(70),
      on_timeout: :kill_task
    )
    |> Enum.zip(queries)
    |> Enum.map_reduce(0, fn {outcome, query}, offset ->
      q = query["q"] || ""

      case outcome do
        {:ok, {:ok, results}} ->
          {formatted, next} = format_results(results, q, turn, offset, session)
          {formatted, next}

        {:ok, {:error, reason}} ->
          Logger.warning("web search failed for #{inspect(q)}: #{inspect(reason)}")

          {%{
             output: "## search_query: #{inspect(q)}\nsearch failed: #{describe_error(reason)}",
             results: []
           }, offset}

        {:exit, reason} ->
          {%{
             output: "## search_query: #{inspect(q)}\nsearch failed: #{inspect(reason)}",
             results: []
           }, offset}
      end
    end)
    |> elem(0)
  end

  defp search_opts(query, max_results) do
    [
      max_results: max_results,
      time_range: time_range(query["recency"]),
      include_domains: query["domains"]
    ]
  end

  defp time_range(nil), do: nil
  defp time_range(days) when days <= 1, do: "day"
  defp time_range(days) when days <= 7, do: "week"
  defp time_range(days) when days <= 31, do: "month"
  defp time_range(_), do: "year"

  defp format_results([], q, _turn, offset, _session),
    do: {%{output: "## search_query: #{inspect(q)}\nno results.", results: []}, offset}

  defp format_results(results, q, turn, offset, session) do
    {entries, next} =
      Enum.map_reduce(results, offset, fn r, i ->
        ref_id = "turn#{turn}search#{i}"
        Refs.put(session, ref_id, %{url: r.url, title: r.title})

        line =
          "[#{ref_id}] #{r.title} — #{r.url}#{if r.published_date, do: " (#{r.published_date})", else: ""}\n#{r.content}"

        {{line,
          %{
            type: "search",
            query: q,
            ref_id: ref_id,
            title: r.title,
            url: r.url,
            snippet: r.content,
            published_at: r.published_date
          }}, i + 1}
      end)

    {lines, records} = Enum.unzip(entries)

    {%{output: "## search_query: #{inspect(q)}\n" <> Enum.join(lines, "\n\n"), results: records},
     next}
  end

  ## open

  defp open(opens, turn, session, target) do
    opens
    |> Enum.with_index()
    |> Enum.map(fn {op, j} ->
      ref = op["ref_id"] || ""

      case resolve(session, ref) do
        {:ok, url} ->
          fetch_page(url, "turn#{turn}fetch#{j}", op["lineno"], session, target)

        :error ->
          %{
            output:
              "## open: #{ref}\nunknown reference id #{ref}; give a URL or a ref_id from this session.",
            results: []
          }
      end
    end)
  end

  defp resolve(_session, "http://" <> _ = url), do: {:ok, url}
  defp resolve(_session, "https://" <> _ = url), do: {:ok, url}

  defp resolve(session, ref_id) do
    case Refs.fetch(session, ref_id) do
      {:ok, %{url: url}} -> {:ok, url}
      :error -> :error
    end
  end

  # the bundled headless browser renders the page (JavaScript run) and the
  # model gets the main element's html; a failure is reported as such — the
  # browser ships with every release, so there is nothing to fall back to
  defp fetch_page(url, ref_id, lineno, session, _target) do
    case Browser.fetch(url, format: :html, wait_until: :networkidle0) do
      {:ok, %{title: title, content: content}} ->
        page(url, ref_id, lineno, session, title, content)

      {:error, reason} ->
        Logger.warning("web open failed for #{url}: #{inspect(reason)}")

        %{
          output:
            "## open: #{url}\nopen failed: #{describe_browser_error(reason)}#{private_hint(reason)}",
          results: []
        }
    end
  end

  # a navigation error while private addresses are refused: on a fake-ip
  # network every site resolves to one — the switch in Settings → 工具
  defp private_hint({:navigation, _}) do
    if Longx.Browser.allow_private_network?(),
      do: "",
      else:
        " (if this Longx sits behind a fake-ip DNS / VPN, the page's address is a private one and the browser refuses it: turn on “允许访问私网 / 局域网地址” under 设置 → 工具)"
  end

  defp private_hint(_), do: ""

  defp describe_browser_error(:unavailable),
    do: "the headless browser is not installed on this Longx"

  defp describe_browser_error(:busy), do: "the browser is busy; try again in a moment"
  defp describe_browser_error(:timeout), do: "the page did not finish loading in time"
  defp describe_browser_error(:invalid_url), do: "only http(s) URLs can be opened"
  defp describe_browser_error({:navigation, message}), do: message
  defp describe_browser_error(other), do: inspect(other)

  defp page(url, ref_id, lineno, session, title, text) do
    Refs.put(session, ref_id, %{url: url, title: title})
    body = text |> from_line(lineno) |> String.slice(0, @max_page_chars)
    heading = if title, do: "#{title} — #{url}", else: url

    %{
      output: "## open: #{heading} [#{ref_id}]\n#{body}",
      results: [%{type: "open", ref_id: ref_id, url: url, title: title}]
    }
  end

  defp from_line(content, lineno) when is_integer(lineno) and lineno > 1 do
    content |> String.split("\n") |> Enum.drop(lineno - 1) |> Enum.join("\n")
  end

  defp from_line(content, _), do: content

  ## time

  defp time(zones) do
    now = DateTime.utc_now()

    lines =
      Enum.map(zones, fn zone ->
        offset = zone["utc_offset"] || "+00:00"

        case parse_offset(offset) do
          {:ok, seconds} ->
            local = DateTime.add(now, seconds, :second)

            "UTC#{offset}: #{Calendar.strftime(local, "%Y-%m-%dT%H:%M:%S")} (#{Calendar.strftime(local, "%A")})"

          :error ->
            "UTC#{offset}: invalid offset"
        end
      end)

    %{output: "## time\n" <> Enum.join(lines, "\n"), results: []}
  end

  defp parse_offset(<<sign, h1, h2, ?:, m1, m2>>) when sign in ~c"+-" do
    with {hours, ""} <- Integer.parse(<<h1, h2>>), {minutes, ""} <- Integer.parse(<<m1, m2>>) do
      seconds = hours * 3600 + minutes * 60
      {:ok, if(sign == ?-, do: -seconds, else: seconds)}
    else
      _ -> :error
    end
  end

  defp parse_offset(_), do: :error

  ## helpers

  defp cap(output, budget) when byte_size(output) <= budget, do: output

  defp cap(output, budget),
    do: String.slice(output, 0, budget) <> "\n\n[truncated: output exceeded the token budget]"

  defp describe_error({:status, status, body}),
    do: "upstream returned #{status}: #{inspect(body) |> String.slice(0, 200)}"

  defp describe_error(%{__exception__: true} = e), do: Exception.message(e)
  defp describe_error(other), do: inspect(other)
end
