defmodule Longx.Agent.Plugs.Browser do
  @moduledoc """
  `web_fetch`: a page rendered by the headless browser (obscura,
  `Longx.Browser.fetch/2`) and handed to the model as markdown (or text /
  reduced HTML), capped.
  In every search mode: a provider that searches on its side still cannot
  read the URL the person named. `drop Browser` in a description turns it
  off; the browser's private-network switch in the settings applies.
  """

  use Longx.Agent.Plug

  alias Longx.Browser

  tool :web_fetch,
       "Opens a web page in a headless browser (JavaScript rendered) and returns its content as markdown. Use it to read documentation, issues, articles — any URL you have.",
       show: :web_search,
       timeout: 60_000 do
    param :url, :string, "The http(s) URL to open", required: true

    param :format,
          {:enum, ["markdown", "text", "html"]},
          "How to return the page (default markdown)"

    param :selector, :string, "A CSS selector to wait for before reading the page"
  end

  def web_fetch(%{"url" => url} = args, _ctx) do
    format =
      case Map.get(args, "format", "markdown") do
        "text" -> :text
        "html" -> :html
        _ -> :markdown
      end

    opts =
      [format: format, wait_until: :networkidle0, timeout: 30_000]
      |> then(&if(args["selector"], do: Keyword.put(&1, :selector, args["selector"]), else: &1))

    case Browser.fetch(url, opts) do
      {:ok, page} ->
        heading =
          if page.title, do: "# #{page.title} — #{page.url}\n\n", else: "# #{page.url}\n\n"

        note = if page.truncated, do: "\n\n[truncated]", else: ""

        {:ok, heading <> page.content <> note,
         %{"results" => [%{"title" => page.title || "", "url" => url}]}}

      {:error, :invalid_url} ->
        {:error, "only http(s) URLs can be opened"}

      {:error, :unavailable} ->
        {:error,
         "the headless browser is not available on this Longx (no build for this platform)"}

      {:error, {:installing, %{stage: :installed}}} ->
        {:error, "the headless browser has just been installed; call web_fetch again"}

      {:error, {:installing, %{stage: :failed, error: error}}} ->
        {:error,
         "the headless browser could not be downloaded (#{error}); the person can retry from the settings"}

      {:error, {:installing, %{received: received, total: total}}} ->
        percent =
          if is_integer(total) and total > 0, do: " (#{div(received * 100, total)}%)", else: ""

        {:error, "the headless browser is being downloaded#{percent}; try again in a moment"}

      {:error, :busy} ->
        {:error, "the browser is busy with other pages; try again in a moment"}

      {:error, :timeout} ->
        {:error, "the page did not finish loading in time"}

      {:error, {:navigation, message}} ->
        {:error, "could not open #{url}: #{message}"}

      {:error, reason} ->
        {:error, "could not open #{url}: #{inspect(reason)}"}
    end
  end
end
