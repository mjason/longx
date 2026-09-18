---
title: Writing watches (schedules, monitors, coming back later)
summary: A watch is a script in .longx/local/watches/<name>.exs that Oban runs on a cron, once, or on a webhook, and that sends messages to sessions; the head DSL, run/1, the helpers, send and :self, wait_until, the session directory and addresses
tags: [longx, watches, schedule, monitor, sessions]
---

A **watch** is how something happens without you being in a turn: a check every five minutes, a look tomorrow at eight, a reaction to a webhook. It is a plain script Longx runs on a clock (no model call), and the only thing it can do to a conversation is put a message in a session's mailbox — which starts a turn there once that session is idle. There is no policy in the runtime: the script decides what to check, what changed, whom to tell.

## The file

```elixir
# .longx/local/watches/deploy_health.exs   (shared/watches/ once the person promoted it)
defmodule DeployHealth do
  use Longx.Agent.Watch

  every "*/5 * * * *"                     # five-field cron, the machine's local time
  # once "2026-09-19T08:00:00+08:00"      # or one instant (no offset = local time)
  # webhook true                          # or POST /hooks/<token> (watch_list shows the token)
  expires "2026-09-20T00:00:00+08:00"     # optional; or max_runs 24
  timeout 30_000                          # optional, ms, the default
  budget 6                                # optional: sends per hour, the default

  def run(ctx) do
    {code, out} = shell(ctx, "curl -fsS -m 5 http://localhost:8080/health")
    status = if code == 0, do: :ok, else: :fail
    log(ctx, "health #{status}")

    if status != ctx.state[:status],
      do: send(ctx, "main", "health went from #{ctx.state[:status] || :unknown} to #{status}:\n#{out}")

    {:ok, %{status: status}}
  end
end
```

- One module per file, `use Longx.Agent.Watch`, one schedule (`every` | `once` | `webhook`).
- `run/1` answers `{:ok, state}` — a map kept as `ctx.state` for the next run (that is how "only when it changed" is written: compare, then remember) — or `{:error, why}`. A raise is an error too; both land on the watch's row and in `watch_list`.
- `ctx`: `name`, `project_root`, `state`, `payload` (a webhook's JSON body or text), `run_at`.
- Helpers: `shell(ctx, cmd, timeout: ms)` → `{exit_code, output}` (bash in the project root, as the person, stdout and stderr together); `http(ctx, url, method:, headers:, body:)` → `{:ok, %{status, body}}`; `credential_request(ctx, credential_name, url, method:, …)` for an API that needs a stored credential (the secret never enters the script); `knowledge_read(ctx, "local/monitor/normal.md")` for the normal state to compare against; `log(ctx, line)` for what the person sees as the last output.
- `send(ctx, to, text)`: `to` is a session's address — a handle (`"main"`, `"ops"`), `~` + the last six characters of its id, `"<project>:<handle>"` — or **`:self`**, the session named `watch-<name>`, started the first time and kept (its history is the watch's own memory; the person can open it). The message is delivered when that session is idle, never in the middle of its turn. At most `budget` sends per hour; past it the watch is switched off and the person told.

## Three uses, one shape

| Want | Write |
|---|---|
| Come back to this task later (a loop) | `send(ctx, "<your address>", "continue: …")` — or just call `wait_until(at | every, message)` and end your turn |
| Monitor something | check, compare with `ctx.state` (or the knowledge), send only when it matters, return the new state |
| A standing duty with its own history | `send(ctx, :self, "…")` — the `watch-<name>` session accumulates what it saw |

Never `sleep` or poll inside a turn to wait for time to pass: write the watch, say when you will look again, end the turn.

## After writing it

The file loads by itself within a minute (or at once when you call a watch tool); a broken head or a compile error comes back as a `⚠` notice naming the file. **Run `watch_run(name)` once** — a dry run: what it logged, what it would send, its result — before leaving it. `watch_list` shows every watch with its schedule, next and last run, last output, state and errors; `watch_enable(name, false)` keeps one without running it. A `once` watch is consumed (file removed) when it ran; an expired one stays, marked expired, until deleted. Deleting the file deletes the watch.

## Sessions and addresses

Every conversation in the project is a session with an address; `agents_directory` lists them with their state (running, waiting on the person, idle, asleep), goal and team. `send_message(to, message)` reaches any of them (`deliver: "idle"` to wait for it to be idle); the answer comes back to you as a message from it. `claim_handle("ops")` gives this session a name others can use — do that for a session that is meant to be found (a duty, a long task). A watch's `send` is the same mechanism from outside a session.
