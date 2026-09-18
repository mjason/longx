## Reference: agent description and plugs

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

Write new things to `local/` by default; `shared/` is for what a person reviewed. A local declaration of the same name replaces the shared one; both apply on top of the shipped defaults. There is nothing global but knowledge: an agent, a plug, a skill lives in a project.

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

The shipped pipeline: `Environment`, `Base`, `Shell` (exec_command), `Patch` (apply_patch), `ViewImage`, `Knowledge`, `WebSearch`, `Browser` (web_fetch), `Agents` (spawn_agent / send_message / close_agent), `Goal` (create_goal / update_goal / get_goal), `Compaction` (get_context_remaining / new_context_window; folds the context at 90 % of the window), `Request` (all under `Longx.Agent.Plugs`).

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

Longx ships no agents: a project grows its own. When a kind of task keeps being delegated, declare it in `local/agents/<name>/` (the declaration loads at your next step); a local declaration of a name replaces a shared one. `spawn_agent(agent, task)` starts one as a separate process; its final message comes back as a message `[agent <name>] …`. An agent stays in your team after it reported, with its whole context: `send_message(agent, message)` asks it a follow-up on what it already did and learned (cheaper and better than a fresh spawn — the provider caches the unchanged prefix), redirects one still working, or reaches a teammate (a sibling under the same parent); the answer comes back as a message from it. `close_agent` forgets one for good. Prefer declaring a role over improvising one in a task.

**A custom tool is a plug: two files, then it is there at your next step.** (1) The module in `local/plugs/<name>.exs`; (2) `plug <Module>` in `local/agent.exs` (create it if missing — `import Longx.Agent.Config` + `agent do … end`). Nothing else: no restart, no registration. A file that fails to compile, or a plug the description names but no file defines, comes back to you at the next step as a `⚠` notice with the error — fix it and go on. Look at your tool list at the next step to see the tool.

```elixir
defmodule Deploy do
  use Longx.Agent.Plug

  instructions "Deploy with the deploy tool, never by hand."

  tool :deploy, "Ships the current branch to an environment", show: :command, timeout: 300_000 do
    param :env, {:enum, ["staging", "prod"]}, "Target environment", required: true
  end

  def deploy(%{"env" => env}, ctx) do
    Context.emit(ctx, "deploying…\n")          # live output for the person
    {output, status} = System.cmd("./deploy.sh", [env], cd: ctx.cwd, stderr_to_stdout: true)
    if status == 0, do: {:ok, output, %{"exitCode" => 0}}, else: {:error, "deploy failed (#{status}):\n" <> output}
  end
end
```

The tool function is ordinary Elixir run in a task under the tool's `timeout:` (60 s by default): `System.cmd`, `File`, `Req` (HTTP), `Jason` are all fine there — only the file's *top level* must stay pure. It gets the decoded arguments (string keys) and a `ctx` (`ctx.cwd` the working directory, `ctx.project_id`, `ctx.thread_id`, `Context.path(ctx, rel)` resolves a path against the cwd). It answers `{:ok, text}` (what the model reads), `{:ok, text, meta}` or `{:error, why}` (the model reads the error and retries or explains). `meta` keys the kernel understands: `"exitCode"` (shown on a `:command` row), `"image"` (a data URL the model then sees, like `view_image`), `"present"` (a card for the person, below), `"compact" => true` (fold the context before the next step). Parameter types: `:string`, `:integer`, `:number`, `:boolean`, `{:enum, [..]}`, `{:array, type}`; a `param` without `required: true` is optional. `show:` decides the row in the UI: `:command` (a terminal block — give it the output), `:file_change` (a diff, with `"changes"` in meta), `:tool` (a plain call). Mount a plug where it should read the pipeline: `plug Deploy` alone goes just before `Request`; `plug Guard, after: Longx.Agent.Plugs.Shell` places it.

**When the person has to act** (log in somewhere, type a code, confirm out of band) the tool asks and waits — never prints a link and polls:

```elixir
case Context.ask(ctx,
       title: "登录 COROS", text: "用存有训练数据的账号登录",
       callback: true,
       url: fn callback -> "https://…/authorize?client_id=…&redirect_uri=" <> URI.encode_www_form(callback) end
     ) do
  {:ok, %{"query" => %{"code" => code}}} -> exchange(code)      # the browser came back through Longx
  {:ok, answer} -> …                                              # 已完成 pressed, or the fields typed (%{"code" => "…"})
  {:error, :cancelled} -> {:error, "the person cancelled the login"}
  {:error, :timeout} -> {:error, "no login within the time"}
end
```

The person sees a card on the thread (title, text, a link button, the `fields:` to type — `[%{id: "code", label: "验证码"}]`), the rail says 等待你操作, the phone is notified. With `callback: true` Longx makes a URL for the third party to send the browser back to (`<outside address>/callback/<id>`) and hands you `%{"query" => params}` when it arrives. **Never listen on a local port for a browser redirect**: the person is often on another machine; Longx's own address is what reaches them (the settings' 外部访问地址, else where their browser connected from). `timeout:` in ms (10 minutes by default); the tool's own `timeout:` must be at least as long.

**Surfaces for the person** — besides cards, the shipped `Present` plug opens things: `show_file(path, line)` and `show_diff(path, sha)` open a tab of the person's workbench (the editor, the diff view), `send_file(path, title)` hands them a file to download (inside the project, or one of the message's attachments; served by `GET /files/<project id>/<path>`), `show_html(title, html | url)` opens an artifact — a self-contained html page the model wrote (a chart, a report; inline css / js, at most 512 KB) or a URL — in a sandboxed frame. A tool of yours that produced a file writes it under the project and says so in its result — the model then opens or sends it with these tools — or pushes a card with `Context.present`. Every path is checked to stay inside the project; the client opens a surface only when its item arrives live, never on a replay.

**Cards for the person** — a table, a few numbers, a chart, a form — come from the `present` vocabulary (`$type`: Card, Row, Col, Fact, Table, Chart, Markdown, Alert, Badge, ListView, Image, Button, Select, Input, Form, …; nest with `children`; the exact schema is what the `present` tool declares). A tool pushes one of its own, without the model, with `Context.present(ctx, %{"$type" => "Table", "columns" => [%{"label" => "文件"}, %{"label" => "行数"}], "rows" => [["a.ex", 12]]})` mid-run (a progress table), or with `"present" => tree` in the result's meta once it ends; it shows on the thread at once and is never in the model's context (the model reads the result text only). To let the person *choose* inside a tool, ask with a tree: `Context.ask(ctx, title: "选一个", spec: %{"$type" => "Card", "asForm" => true, "confirm" => %{"label" => "好", "$action" => %{"type" => "pick"}}, "children" => [%{"$type" => "Select", "name" => "env", "options" => [%{"label" => "预发", "value" => "staging"}]}]})` answers `{:ok, %{"action" => %{"type" => "pick", "$input" => %{"env" => "staging"}}}}` — what they fired, `$input` carrying the control's value or the form's values by `name`.

**Secrets never pass through you.** An authenticated API — an HTTP API, an MCP server over HTTP — is called with `http_request(credential, url, …)` from inside your own tools too: a plug's Elixir code calls `Longx.Credentials.request("coros", :post, "https://mcpcn.coros.com/mcp", headers: %{"content-type" => "application/json"}, body: json)` and gets `{:ok, %{status: 200, headers: %{…}, body: text}}` with the value injected by Longx (the row's header, or a `{{credential:coros}}` placeholder in the URL / headers / body), only for a host the credential allows, an expired OAuth2 token refreshed first, and the answer scrubbed of the value; `{:error, :needs_login | :expired | {:host_not_allowed, host} | {:refresh_failed, why}}` otherwise. `credentials_list` / `credential_create` / `credential_rotate` / `credential_login` (the tools) declare, rotate and log one in. A key that is already on the machine — an environment variable, a `.env` or config file — is copied by the tool with `secret_from` (`env:NAME`, `file:PATH`, `file:PATH#KEY`) without the model seeing it; otherwise the person types it into a masked field of an ask (`Context.ask(ctx, fields: [%{id: "secret", label: "API Key", secret: true}])` — `secret: true` masks the input, `required: false` lets a field stay empty; the answer goes to the tool, never to the model). Never read a token into your own context (no `cat ~/.zshrc`, no `echo $KEY`), never listen on a local port for an OAuth redirect: the redirect URI is Longx's own `/callback/credentials` (https when the public URL is, else Longx's loopback `http://127.0.0.1:<port>`, since a provider takes no remote http address — a browser on another machine then pastes the redirected address into the login ask).

**When to write one**: a workflow you repeat by hand every turn (the same three commands, a deploy, a data export), something a shell one-liner cannot do cleanly (an HTTP API with a token from the environment, a structured result), or a rule the pipeline should enforce (a `:response` plug that appends `mix test` after every `apply_patch`, a `:turn_end` strategy). Not for one-off commands — `exec_command` is there for those.

The same pipeline runs at three phases; a plug may pattern-match on `step.phase`:

- `:request` (default `call/2` mounts instructions and tools here) — `Step.instructions/2`, `Step.tool/2`, `Step.halt/2`, `Step.compact/2`, and `step.model` / `step.effort` may be set;
- `:response` — the model answered; `step.calls` are its tool calls; `Step.enqueue_call(step, "exec_command", %{"cmd" => "mix test"})` adds one of yours;
- `:turn_end` — nothing left; `Step.continue(step, "text")` runs another step with that text instead of ending.

At any phase `Step.spawn(step, "researcher", "task")` starts a declared agent, and `Step.put_state(step, key, value)` keeps something in `step.state` for the rest of the turn (a strategy counting its rounds). `step.assigns` carries `parent`, `name`, `role`, `depth`, `children` (`%{id, name}`), `agents` (the declared roles) — what a strategy needs to see its team.

Top-level code in these files must be pure (no processes, no writes at load time).
