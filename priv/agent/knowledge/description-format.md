---
title: Agent description format versions
summary: What changed in each version of the agent.exs format and how to update a description
tags: [longx, agent, versions]
---

# Version 1 (current)

The first format: `agent do … end` with `version`, `extends :default`, `model`, `prompt`, `prompt_file`, `summary`, `agents`, `plug` (with `before:` / `after:`), `options`, `drop`, and an explicit `pipeline do … end` that replaces the base.

To update a description from an older version: keep it as a difference to the default (`extends :default`), set `version` to the current one, and check that every plug it names still exists in the shipped set (`Environment`, `Base`, `AgentsMd` (the project's AGENTS.md), `Shell` (exec_command), `Jobs` (start_job / jobs / job_output / wait_job / stop_job), `Patch` (apply_patch), `ViewImage`, `Knowledge`, `WebSearch`, `Browser` (web_fetch), `Agents` (spawn_agent / send_message / close_agent), `Request` (all under `Longx.Agent.Plugs`)).
