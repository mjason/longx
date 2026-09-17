defmodule Longx.Agent.Plugs.Local do
  @moduledoc """
  What a trusted project's agent is told about itself: that its
  definition lives in `.longx/` (the description, the plugs), that it may
  change it when a workflow repeats or a tool would help, and the compact
  reference of the description and plug API (`priv/agent/reference.md`)
  — so it can. Mounted by `Longx.Agent.Loader`, never by hand.
  """

  use Longx.Agent.Plug

  @reference_path Path.join(:code.priv_dir(:longx), "agent/reference.md")
  @external_resource @reference_path
  @reference File.read!(@reference_path)

  @untrusted """
  **This project is not trusted yet**: `agent.exs` and `shared/` are not loaded (their code came with the clone) until the person turns on 信任并加载 .longx 里的定义 in the project settings. `local/` loads regardless — declare agents and plugs there; say so if something you need sits in `shared/`.
  """

  @impl true
  def init(opts), do: {Keyword.fetch!(opts, :root), Keyword.get(opts, :trusted, true)}

  @impl true
  def call(%Step{phase: :request} = step, {root, trusted?}) do
    step
    |> Step.instructions(models_section(step.assigns[:models]))
    |> Step.instructions("""
    # Your own definition

    This project's agent — the pipeline you run through, your prompt, your tools, the agents you may spawn — is defined in `#{Path.join(root, ".longx")}`: `agent.exs` (the shared description), `shared/` (agents, plugs, knowledge — in git, reviewed by the person) and `local/` (the same, gitignored — this machine's and yours). Write your own additions to `local/` (`local/agent.exs`, `local/plugs/*.exs`, `local/agents/<name>/`); the person promotes what they reviewed into `shared/`. Changes load at your next step — no restart; a file that fails to load comes back to you as a notice, so fix it. **A custom tool is two files**: the plug module in `local/plugs/<name>.exs` and a `plug <Module>` line in `local/agent.exs`; at the next step the tool is in your list (or a notice says what broke). When a workflow keeps repeating, write it as a plug with a tool; when an instruction should always hold, add it to the description's `prompt`; when a kind of task keeps being delegated, declare it as an agent. Record the difference to the default (`extends :default` + `plug` / `options` / `drop`), not a copy of the whole pipeline.

    #{if trusted?, do: "", else: @untrusted}

    #{@reference}
    """)
  end

  def call(step, _opts), do: step

  # the models a description may name: nothing else is known to Longx
  defp models_section(nil), do: nil
  defp models_section([]), do: nil

  defp models_section(models) do
    {aliases, concrete} = Enum.split_with(models, &Map.has_key?(&1, :alias))

    alias_lines =
      Enum.map_join(aliases, "\n", fn a ->
        chain = Enum.join(a.alias, ", then ")
        "- `#{a.slug}` (#{a.name}) → #{chain}"
      end)

    lines =
      Enum.map_join(concrete, "\n", fn m ->
        levels = if m.levels == [], do: "", else: "; levels " <> Enum.join(m.levels, ", ")
        level = if m.default_level, do: "; default level #{m.default_level}", else: ""
        default = if m.default?, do: "; the default model", else: ""
        "- `#{m.slug}` — #{m.name} (#{m.provider})#{levels}#{level}#{default}"
      end)

    tiers =
      if aliases == [],
        do: "",
        else: """
        **Tiers and aliases** — names the person maps to models in the settings; each is a chain (the first is used, the rest are fallbacks when it fails). Prefer a tier or alias in a description: it survives a change of provider, a concrete slug does not.

        #{alias_lines}

        **Models**

        """

    """
    # Models

    These are the names Longx can resolve — the only ones a description may use (`model "<name>", effort: "<level>"`, for an agent or a role); anything else fails to resolve. The person's own choice for a turn overrides the description.

    #{tiers}#{lines}
    """
  end
end
