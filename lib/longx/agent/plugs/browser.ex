defmodule Longx.Agent.Plugs.Browser do
  @moduledoc """
  `web_fetch`: a page rendered by the bundled headless browser (obscura,
  `Longx.Browser.fetch/2` — the same code as codex's `builtin.browser_fetch`)
  and handed to the model as markdown (or text / reduced HTML), capped.
  In every search mode: a provider that searches on its side still cannot
  read the URL the person named. `drop Browser` in a description turns it
  off; the private-network switch of Settings → 工具 applies.
  """

  use Longx.Agent.Plug

  alias Longx.Tools.Builtin.BrowserFetch

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

  def web_fetch(%{"url" => _} = args, ctx) do
    args
    |> Map.put_new("format", "markdown")
    |> BrowserFetch.call(ctx)
    |> case do
      {:ok, text} ->
        {:ok, text, %{"results" => [%{"title" => title_of(text), "url" => args["url"]}]}}

      {:error, message} ->
        {:error, message}
    end
  end

  defp title_of("# " <> rest),
    do: rest |> String.split("\n", parts: 2) |> hd() |> String.split(" — ") |> hd()

  defp title_of(_), do: ""
end
