---
title: Writing plugs and the agent description
summary: The .longx layout (shared/ and local/), the agent.exs description DSL, declared agents (roles), the Longx.Agent.Plug module API, phases and effects
tags: [longx, plugs, agent]
---

The project's agent definition lives in `.longx/`, in two trees:

```
.longx/
  agent.exs            # the shared description (in git)
  shared/              # in git — reviewed, for the team
    agents/<name>/     # declared agents (roles): agent.exs + prompt.md (+ plugs/, knowledge/)
    plugs/*.exs
    knowledge/<topic>/*.md
  local/               # gitignored — this machine, this person, your drafts
    agent.exs          # optional: a local override (another model, an extra plug)
    agents/  plugs/  knowledge/
```

Write new things to `local/` by default; `shared/` is for what a person reviewed. A local declaration of the same name replaces the shared one; both apply after the person's global directory and the shipped defaults.

`.longx/agent.exs` (and `local/agent.exs`) must return a description:

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

The shipped pipeline: `Environment`, `Base`, `Shell` (exec_command), `Patch` (apply_patch), `ViewImage`, `Knowledge`, `WebSearch`, `Browser` (web_fetch), `Agents` (spawn_agent / send_message / close_agent), `Request` (all under `Longx.Agent.Plugs`).

**Declared agents (roles)** — `shared/agents/<name>/agent.exs` (or `local/agents/<name>/`) is a description of its own, applied on top of the project's when that agent is spawned:

```elixir
import Longx.Agent.Config

agent do
  summary "searches the web and reports with sources — changes nothing"   # what the parent reads when choosing
  prompt_file "prompt.md"        # the long prompt, next to this file
  model "deepseek-flash", effort: "low"
  drop Longx.Agent.Plugs.Patch   # a researcher edits nothing
  agents []                      # whom it may spawn in turn ([] nobody; unset: every declared agent)
end
```

Longx ships no agents: a project grows its own. When a kind of task keeps being delegated, declare it in `local/agents/<name>/` (the declaration loads at your next step); a local declaration of a name replaces a shared one. `spawn_agent(agent, task)` starts one as a separate process; its final message comes back as a message `[agent <name>] …`. Prefer declaring a role over improvising one in a task.

A plug (`.longx/shared/plugs/<name>.exs` or `local/plugs/<name>.exs`, one or more modules; names are private to this project):

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

At any phase `Step.spawn(step, "researcher", "task")` starts a declared agent, and `Step.put_state(step, key, value)` keeps something in `step.state` for the rest of the turn (a strategy counting its rounds). `step.assigns` carries `parent`, `name`, `role`, `depth`, `children` (`%{id, name}`), `agents` (the declared roles) — what a strategy needs to see its team.

Top-level code in these files must be pure (no processes, no writes at load time).
