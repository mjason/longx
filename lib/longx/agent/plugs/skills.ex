defmodule Longx.Agent.Plugs.Skills do
  @moduledoc """
  Default, removable Skills capability. Project instruction text is readable
  independently of the `.longx` executable-code trust switch, like AGENTS.md.
  No scripts, dependencies or tool permissions are activated by discovery.

  Options: `roots:`, `root_markers:`, `disabled:` (SKILL.md paths),
  `catalog_chars:` and the scanning limits accepted by `Longx.Agent.Skills`.
  No personal/global directory is scanned implicitly.

  Usage prompt aligned to Codex 3e238776's host catalog prompt; the only changes
  are absolute paths instead of root aliases (locked by a fixture test).
  """
  use Longx.Agent.Plug
  alias Longx.Agent.Skills, as: Files

  @path Path.join(:code.priv_dir(:longx), "agent/skills/prompt.md")
  @external_resource @path
  @prompt @path |> File.read!() |> String.trim()
  def prompt, do: @prompt

  @impl true
  def call(%Step{phase: phase} = step, _opts) when phase != :request, do: step
  def call(%Step{cwd: nil} = step, _opts), do: step

  def call(step, opts) do
    snapshot =
      Map.get_lazy(step.state, :skills_snapshot, fn -> Files.snapshot(step.cwd, opts) end)

    inputs = Map.get(step.state, :user_inputs, [])
    {selected, warnings} = Files.select(snapshot, inputs)
    # The directory is cached for this turn. Explicit bodies enter the transcript
    # once, preserving cache prefixes and history without retaining every body
    # from discovery in memory.
    budget =
      Keyword.get(
        opts,
        :catalog_chars,
        if(step.context_window, do: trunc(step.context_window * 0.08), else: 8_000)
      )

    step = Step.put_state(step, :skills_snapshot, snapshot)

    step =
      if snapshot.skills == [] do
        step
      else
        step
        |> Step.instructions(Files.catalog(snapshot, budget))
        |> Step.instructions(@prompt)
        |> Step.instructions(
          "Use skill_read with a listed SKILL.md path to read it completely. For references, pass resource relative to that skill directory. skill_list also lists explicit-only skills; do not implicitly activate those. Skill metadata does not install dependencies or grant tool permissions."
        )
        |> Step.tool(read_tool(snapshot))
        |> Step.tool(list_tool(snapshot))
      end

    step = Step.instructions(step, Enum.map(snapshot.warnings ++ warnings, &("⚠ " <> &1)))
    activated = Map.get(step.state, :skills_activated, MapSet.new())

    Enum.reduce(selected, step, fn entry, step ->
      if MapSet.member?(activated, entry.id) do
        step
      else
        case Files.read(entry) do
          {:ok, body} ->
            input = %{
              "type" => "message",
              "role" => "user",
              "content" => [
                %{
                  "type" => "input_text",
                  "text" =>
                    "<skill>\n<name>#{entry.name}</name>\n<path>#{entry.path}</path>\n#{body}\n</skill>"
                }
              ]
            }

            step
            |> Step.context_input(input)
            |> Step.put_state(
              :skills_activated,
              MapSet.put(Map.get(step.state, :skills_activated, activated), entry.id)
            )

          {:error, reason} ->
            Step.instructions(step, "⚠ skill #{entry.name}: #{reason}")
        end
      end
    end)
  end

  defp read_tool(snapshot) do
    tool =
      Tool.declare(
        __MODULE__,
        :skill_read,
        "Reads a skill's complete SKILL.md or a relative resource; never executes it.",
        [
          {:path, :string, "Listed absolute SKILL.md path", [required: true]},
          {:resource, :string, "Relative resource path; defaults to SKILL.md", []}
        ],
        []
      )

    %{
      tool
      | fun: fn %{"path" => path} = args, ctx ->
          case Enum.find(snapshot.skills, &(&1.enabled and (&1.path == path or &1.id == path))) do
            nil ->
              {:error, "skill path missing or disabled; use skill_list"}

            entry ->
              case Files.read(entry, Map.get(args, "resource", "SKILL.md")) do
                {:ok, text} ->
                  Context.emit(ctx, "read skill #{entry.name}\n")
                  {:ok, "read skill #{entry.name}\n" <> text}

                error ->
                  error
              end
          end
        end
    }
  end

  defp list_tool(snapshot) do
    tool =
      Tool.declare(
        __MODULE__,
        :skill_list,
        "Lists enabled skill paths, descriptions and implicit-invocation policy for this turn.",
        [],
        []
      )

    %{
      tool
      | fun: fn _args, _ctx ->
          entries =
            for entry <- snapshot.skills, entry.enabled do
              %{
                name: entry.name,
                path: entry.path,
                description: entry.description,
                implicit: entry.implicit
              }
            end

          {:ok, Jason.encode!(%{skills: entries, warnings: snapshot.warnings})}
        end
    }
  end
end
