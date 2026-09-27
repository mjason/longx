defmodule Longx.Agent.Plugs.Browser do
  @moduledoc """
  The person's own browser, through the Longx Chrome extension
  (`docs/browser-design.md`, `Longx.Chrome`): one tool, `javascript(title,
  code)`, whose code runs in the conversation's persistent JavaScript realm
  (`Longx.Chrome.Session` → `Longx.Chrome.Runtime`, `shim js`) with the
  primitives of `priv/agent/browser/prelude.js` — `page`, `tabs`,
  `snapshot()`, `screenshot()`, raw CDP. The prompt is browser-use-pi's
  (MIT) adapted to Longx (`prompt.md`); when to ask the person is codex's
  Browser Use confirmation policy (`policy.md`).

  **Not in the shipped pipeline**: a project turns it on in its description
  — `plug Browser` (the default alias) or `plug Browser, browser:
  "qa-chrome", max_tabs: 3`. The alias is a name for a paired browser
  (`Longx.Chrome.Aliases`), resolved when the first cell runs; the prompt
  names it and nothing live, so the prefix stays cached. Screenshots go to
  the model as images (`"images"` on the result → a `:screenshot` user
  message; `Longx.Agent.Transcript.input/1` keeps only the last two) and
  to the person. The turn's end detaches the debugger from the session's
  tabs (`Session.turn_ended/1`).
  """

  use Longx.Agent.Plug

  alias Longx.Chrome.Session

  @external_resource "priv/agent/browser/prelude.js"
  @external_resource "priv/agent/browser/prompt.md"
  @external_resource "priv/agent/browser/policy.md"
  @prelude File.read!("priv/agent/browser/prelude.js")
  @prompt File.read!("priv/agent/browser/prompt.md")
  @policy File.read!("priv/agent/browser/policy.md")

  @cell_timeout_ms 30_000
  @output_cap 12_000
  @defaults [browser: nil, max_tabs: 1]

  tool :javascript,
       "Execute JavaScript in the persistent browser realm with raw CDP to the person's Chrome (see the Browser section). Cell deadline: 30000 ms; a longer wait belongs in a later cell. Console output comes back as text, screenshot() as images, `return` as the cell's value.",
       show: :tool,
       timeout: @cell_timeout_ms + 30_000 do
    param :title,
          :string,
          "What this cell does, in a few words — shown to the person beside the code.",
          required: true

    param :code,
          :string,
          "The JavaScript to run: the body of an async function (top-level await allowed).",
          required: true
  end

  @impl true
  def init(opts), do: Keyword.merge(@defaults, opts)

  @impl true
  def call(%Step{phase: :request} = step, opts) do
    tool = Enum.find(__agent_tools__(), &(&1.name == "javascript"))

    step
    |> Step.instructions([@prompt, browser_line(opts), @policy])
    |> Step.tool(%{tool | fun: fn args, ctx -> javascript(args, ctx, opts) end})
  end

  def call(%Step{phase: :turn_end, thread_id: thread_id} = step, _opts)
      when is_binary(thread_id) do
    Session.turn_ended(thread_id)
    step
  end

  def call(step, _opts), do: step

  defp browser_line(opts) do
    case Keyword.get(opts, :browser) do
      nil ->
        "This project uses the person's default browser (Settings → 浏览器). Tab limit for this project: #{Keyword.get(opts, :max_tabs)}."

      name ->
        "This project's browser is the one named `#{name}` (Settings → 浏览器). Tab limit for this project: #{Keyword.get(opts, :max_tabs)}."
    end
  end

  @doc "The prelude the realm starts with."
  def prelude, do: @prelude

  ## The tool

  def javascript(args, ctx), do: javascript(args, ctx, @defaults)

  def javascript(_args, %{thread_id: nil}, _opts),
    do: {:error, "the browser belongs to a conversation; there is none here"}

  def javascript(%{"code" => code} = args, ctx, opts) do
    title = Map.get(args, "title", "")

    with {:ok, _pid} <-
           Session.ensure(ctx.thread_id,
             project_id: ctx.project_id,
             alias: Keyword.get(opts, :browser),
             max_tabs: Keyword.get(opts, :max_tabs) || 1,
             prelude: @prelude
           ),
         {:ok, result} <-
           Session.execute(ctx.thread_id, code, @cell_timeout_ms,
             emit: fn text -> Context.emit(ctx, text) end
           ) do
      format(result, title, code, ctx)
    else
      {:error, :busy} -> {:error, "a cell of this conversation is still running; wait for it"}
      {:error, :timeout} -> {:error, "the cell did not answer in time"}
      {:error, reason} -> {:error, "the browser runtime could not start: #{inspect(reason)}"}
    end
  end

  defp format(result, title, code, ctx) do
    {output, saved} = clip_output(result.output, ctx)

    parts =
      [
        if(result.reset,
          do:
            "JavaScript state was reset: the realm started over (the prelude is back, earlier variables are gone). Inspect before retrying actions."
        ),
        if(output != "", do: output),
        if(saved,
          do: "[output truncated to #{@output_cap} characters; the whole text is in #{saved}]"
        ),
        if(result.value != nil, do: "→ " <> Jason.encode!(result.value)),
        if(result.interrupted and result.error == nil,
          do:
            "The cell was interrupted at its deadline (#{div(@cell_timeout_ms, 1000)} s). Actions may already have happened."
        ),
        if(result.error, do: "Error: " <> result.error),
        if(result.images != [], do: "#{length(result.images)} screenshot(s) attached.")
      ]
      |> Enum.reject(&is_nil/1)

    text = if parts == [], do: "(no output)", else: Enum.join(parts, "\n")
    images = Enum.map(result.images, &("data:#{&1.mime};base64," <> &1.data))

    details = %{
      "title" => title,
      "code" => code,
      "images" => length(images),
      "reset" => result.reset,
      # the person sees the screenshots too: kept as attachments of the project,
      # drawn inline by the chat (`/files/<project>/_attachments/<name>?inline=1`)
      "screenshots" => store_screenshots(result.images, ctx)
    }

    if result.error do
      {:error, text, %{"images" => images, "details" => details}}
    else
      {:ok, text, %{"images" => images, "details" => details}}
    end
  end

  defp store_screenshots(images, %{project_id: project_id}) when is_binary(project_id) do
    images
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {%{mime: mime, data: data}, n} ->
      ext = if mime == "image/png", do: "png", else: "jpg"

      with {:ok, bytes} <- Base.decode64(data),
           {:ok, %{name: name, bytes: size}} <-
             Longx.Projects.Attachments.store_bytes(project_id, "screenshot-#{n}.#{ext}", bytes) do
        [%{"name" => name, "path" => name, "attachment" => true, "mime" => mime, "bytes" => size}]
      else
        _ -> []
      end
    end)
  end

  defp store_screenshots(_images, _ctx), do: []

  # the whole output kept in the data dir when the model gets a clipped one
  defp clip_output(output, ctx) do
    if String.length(output) <= @output_cap do
      {output, nil}
    else
      path = Longx.Chrome.cell_output_path(ctx.thread_id, ctx.call_id || "cell")

      case File.mkdir_p(Path.dirname(path)) do
        :ok ->
          File.write!(path, output)
          {String.slice(output, 0, @output_cap), path}

        _ ->
          {String.slice(output, 0, @output_cap), nil}
      end
    end
  end
end
