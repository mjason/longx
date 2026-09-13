defmodule Longx.Tools.Builtin.BrowserFetch do
  @moduledoc """
  Lets the agent read a web page as a browser renders it (JavaScript run,
  `Longx.Browser`), independent of the sandbox's network: the fetch happens
  in Longx, not inside the agent's command sandbox. Available only when the
  bundled obscura is installed (`mix obscura.fetch`).
  """
  @behaviour Longx.Codex.Tool

  alias Longx.Browser

  @impl true
  def name, do: "browser_fetch"

  @impl true
  def namespace, do: "builtin"

  @impl true
  def description,
    do:
      "Opens a URL in a headless browser (JavaScript executed) and returns the page's main content — " <>
        "as cleaned HTML (default), markdown or plain text. Use it for pages that need rendering or " <>
        "when curl is blocked; it runs outside the sandbox."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "The http(s) URL to open."},
        "format" => %{
          "type" => "string",
          "enum" => ["html", "markdown", "text"],
          "description" =>
            "What to return: the main element's cleaned html (default), markdown, or text."
        },
        "selector" => %{
          "type" => "string",
          "description" => "Optional CSS selector to wait for before reading the page."
        }
      },
      "required" => ["url"],
      "additionalProperties" => false
    }
  end

  @impl true
  def available?(_ctx), do: Browser.available?()

  # navigation deadline + settle + queueing; beyond the runner's default
  @impl true
  def timeout, do: 60_000

  @impl true
  def call(%{"url" => url} = args, _ctx) do
    format =
      case Map.get(args, "format", "html") do
        "markdown" -> :markdown
        "text" -> :text
        _ -> :html
      end

    opts =
      [format: format, wait_until: :networkidle0, timeout: 30_000]
      |> then(&if(args["selector"], do: Keyword.put(&1, :selector, args["selector"]), else: &1))

    case Browser.fetch(url, opts) do
      {:ok, page} ->
        heading =
          if page.title, do: "# #{page.title} — #{page.url}\n\n", else: "# #{page.url}\n\n"

        note = if page.truncated, do: "\n\n[truncated]", else: ""
        {:ok, heading <> page.content <> note}

      {:error, :invalid_url} ->
        {:error, "only http(s) URLs can be opened"}

      {:error, :unavailable} ->
        {:error, "the headless browser is not installed on this Longx"}

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
