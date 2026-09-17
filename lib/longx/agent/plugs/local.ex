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

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :root)

  @impl true
  def call(%Step{phase: :request} = step, root) do
    Step.instructions(step, """
    # Your own definition

    This project's agent — the pipeline you run through, your prompt, your tools — is defined in `#{Path.join(root, ".longx")}`: `agent.exs` (the description) and `plugs/*.exs` (Longx.Agent.Plug modules). Changes load at the start of your next turn; a file that fails to load comes back to you as a notice, so fix it. When a workflow keeps repeating, write it as a plug with a tool; when an instruction should always hold, add it to the description's `prompt`. Record the difference to the default (`extends :default` + `plug` / `options` / `drop`), not a copy of the whole pipeline.

    #{@reference}
    """)
  end

  def call(step, _root), do: step
end
