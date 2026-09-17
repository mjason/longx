---
title: Writing plugs and the agent description
summary: The .longx/agent.exs description DSL, the Longx.Agent.Plug module API, phases and effects
tags: [longx, plugs, agent]
---

`.longx/agent.exs` must return a description:

```elixir
import Longx.Agent.Config

agent do
  version 1
  extends :default                 # the shipped pipeline is the base
  model "deepseek-flash", effort: "low"   # optional defaults
  prompt "Always run mix test after editing lib/."
  plug Deploy, env: "staging"      # a plug from .longx/plugs/, before Request unless placed
  plug Guard, after: Longx.Agent.Plugs.Shell
  options Longx.Agent.Plugs.Shell, timeout_ms: 300_000
  drop Longx.Agent.Plugs.ViewImage
end
```

The shipped pipeline: `Environment`, `Base`, `Shell` (exec_command), `Patch` (apply_patch), `ViewImage`, `Request` (all under `Longx.Agent.Plugs`).

A plug (`.longx/plugs/<name>.exs`, one or more modules; names are private to this project):

```elixir
defmodule Deploy do
  use Longx.Agent.Plug

  instructions "Deploy with the deploy tool, never by hand."

  tool :deploy, "Ships the current branch to an environment", show: :command, timeout: 300_000 do
    param :env, {:enum, ["staging", "prod"]}, "Target environment", required: true
  end

  def deploy(%{"env" => env}, ctx) do
    Context.emit(ctx, "deploying…\n")          # live output for the person
    {:ok, "deployed to #{env}"}                # or {:ok, text, %{"exitCode" => 0}} / {:error, "why"}
  end
end
```

Parameter types: `:string`, `:integer`, `:number`, `:boolean`, `{:enum, [..]}`, `{:array, type}`. `show:` is `:command`, `:file_change` or `:tool`. `ctx.cwd` is the working directory.

The same pipeline runs at three phases; a plug may pattern-match on `step.phase`:

- `:request` (default `call/2` mounts instructions and tools here) — `Step.instructions/2`, `Step.tool/2`, `Step.halt/2`, `Step.compact/2`, and `step.model` / `step.effort` may be set;
- `:response` — the model answered; `step.calls` are its tool calls; `Step.enqueue_call(step, "exec_command", %{"cmd" => "mix test"})` adds one of yours;
- `:turn_end` — nothing left; `Step.continue(step, "text")` runs another step with that text instead of ending.

Top-level code in these files must be pure (no processes, no writes at load time).
