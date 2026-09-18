# Longx

Agent application. **Ash 3 + Phoenix 1.8 (Bandit, SQLite)** backend running **Longx's own
agent kernel** (`Longx.Agent`: one OTP process per thread, plugs for everything else) and
rendering the agent UI with **React 19** (Vite, shadcn/Tailwind v4, assistant-ui for the
chat), mobile-first, with a React Native client planned on the same core code. Every model
request goes through `Longx.AI` to the providers the person configured (DeepSeek, GLM, 阿里云
百炼, OpenAI, any OpenAI-compatible endpoint). Nothing is bundled in `priv/` but the Go shim
it builds: git is the machine's, the headless browser is downloaded on first use.

## Architecture

- `lib/longx/` — Ash domains & resources (`AshSqlite`). Business logic lives in Ash actions
  and domain functions called through code interfaces — never in controllers.
- `lib/longx/shim.ex` + `native/shim/` (Go) — `Longx.Shim`: runs external programs through
  our own port middleware (adapted from ex_cmd/odu, see `NOTICE`). Back-pressured
  stdin/stdout, a separate stderr stream, `close_stdin` independent of stdout, a pty
  (`pty: true`, Linux/macOS), and clean termination: `kill/2` SIGTERMs the child's whole
  process group then SIGKILLs after a grace period; if the owner or the BEAM dies the shim
  sees its stdin close and does the same. Output is pull-based (a chunk per `read` credit),
  so `await_exit` closes what nobody read — except with `close_streams: false`, which
  `run/2` uses (its drain tasks may not have asked yet when a fast child is already gone).
  Protocol defined twice — `native/shim/proto.go` and `lib/longx/shim/proto.ex` — keep them
  in sync and bump the version in both when it changes (now 3). Built by
  `Mix.Tasks.Compile.Shim` into `priv/bin/` (gitignored) on `mix compile`; **Go must be on
  PATH**. `mix precommit` runs `gofmt`, `go vet`, `go test` in `native/shim`; Windows/macOS
  code is `GOOS=windows|darwin go vet`-checked (no machine here to run it). Windows: process
  groups + CTRL_BREAK + `taskkill /T` plus a Job object per child. Resource guards
  (`native/shim/guard_*.go`, options `oom_score_adj:` / `memory_limit:`, `Shim.stats/1`):
  Linux `oom_score_adj` is written to the shim so the whole tree inherits it; `memory_limit`
  is `RLIMIT_AS` (Linux) or the Job's limit (Windows), ignored on macOS — RLIMIT_AS counts
  address space, so runtimes that reserve it (BEAM, JVM, Go) need generous caps.
- **Git is the machine's git** — `Longx.Git` runs whatever `git` is on PATH (`LONGX_GIT`
  overrides; `Longx.Git.available?/0`) via `Longx.Shim.run/2` with `GIT_TERMINAL_PROMPT=0`,
  `LC_ALL=C` and, for anything that may commit, the Longx identity as `-c user.*` when the
  person has none. **Nothing bundled, no reimplementation** (go-git/gitoxide/libgit2 lack
  hooks/LFS fidelity — evaluated and rejected). Without git every call answers
  `{:error, :no_git}` and the callers degrade: a project without git still works, the
  global knowledge is not versioned, the UI says so. `Longx.Git`: `repository?/toplevel/
  init/head`, `status` (porcelain v1 -z), `commit_all`, `log`, `diff`, `restore_tree` (files
  back to a commit, branch untouched), `reset_hard`, `lfs?`; and for the git tool: `commit/3`
  (named paths; during a merge the merge is committed whole), `file_diff/2`, `discard/2`,
  `show/2`, `commit_file_diff/3`, `undo_commit/1` (`reset --soft HEAD~1`, never the root),
  `branches/1` / `create_branch` / `switch` / `delete_branch`, `stash` / `stash_pop` /
  `stashes`, `remotes` / `set_remote` / `ahead_behind` / `fetch` / `pull` / `push` (upstream
  set on first push; 120 s), `ignored/1`, `merging?/1` / `abort_merge/1`, `file_versions/3`,
  `merge/3` (`{:error, :conflict}` leaves the merge in progress). Auth for remotes is the
  machine's SSH agent / credential helpers; never a prompt, an error instead. The suite plays
  the remote with a bare repository on disk. `Longx.Git.Ignore.default/0` is the `.gitignore`
  `init_git/1` writes.
- `lib/longx/platform.ex` — `Longx.Platform`: runtime-safe os/arch detection and the Rust
  triple / GOOS-GOARCH naming. Anything resolving a binary at runtime goes through this,
  never through `Mix.*` (absent in releases). `Longx.Bundle` downloads / verifies / extracts
  a tar.gz or zip with progress (the browser and the upgrade share it).
- `lib/longx/projects/` — Ash domain `Longx.Projects` (single-user; no thread ↔ user mapping):
  - `Project` = a working directory (absolute, existing, unique `root_path`, `slug`) +
    defaults for its threads: `model_id` (nil → global default), `web_search`,
    `dirty_start` (`:commit` | `:ask` | `:off`), `trust_local_agent` (loads
    `.longx/agent.exs` + `.longx/shared/`, below), `agent_settings` (a map overriding the
    global kernel settings), `archived_at`. Whether it is a git repo is read live
    (`git_info/1`), never stored; `init_git/1` sets git up with a first commit. The UI warns
    when a project has no git. `delete_project/2` needs `confirm: true`: threads, turns,
    transcripts and attachments go first (`Changes.DeleteThreads` /
    `DeleteAttachments`), never the working directory.
  - `Thread` = kernel thread ↔ project (`kernel_thread_id`, `title`, `preview`, `cwd`,
    `model_slug`, `reasoning_effort`, `web_search`, `parent_thread_id` / `agent_path` for a
    sub-agent's row, `status`, `last_activity_at`). Statuses: `:idle`, `:active`,
    `:unrecoverable`, `:archived`. `start_thread/2` → `Longx.Agent.ensure/2` + the row +
    `Tracker.track`.
  - `Turn` = one turn with git bookmarks (`kernel_turn_id`, `user_text`, `model_slug`,
    `reasoning_effort`, `status`, `started/completed_at`, `commit_before/after`,
    `dirty_start`, `diff`, `error`). `send_message/3` does the **git preflight** first:
    clean tree → `commit_before = HEAD`; dirty → per `dirty_start` (`:commit` makes a
    `longx: before turn — …` commit; `:off` records `dirty_start: true`; `:ask` returns
    `{:error, {:dirty_tree, changes}}` unless `dirty: :commit | :ignore`), writes the Turn
    row **first** with a generated `turn_<uuid>`, then `Longx.Agent.send/3`
    (`{:error, :turn_in_progress}` while one runs; `model:` / `effort:` / `images:` — data
    urls from the composer, passed through as `input_image` parts). A message while a turn
    runs is a **steer** (`steer_message/3` → `Agent.send/3` on a running thread; no new
    row; `{:error, :not_running}` once the turn is over). `interrupt_turn/2` kills the
    tasks; `retract_turn/3` takes back a turn that had no side effect yet (only words in
    its items, no pending ask — else `{:error, :has_output}`): row `:reverted` first, then
    `Agent.retract/2` truncates the transcript and `ThreadState.drop_turns` (clients
    re-snapshot), the text comes back to the composer. `compact_thread/2` = `/compact`.
    `delete_thread/1` removes the row, its turns and its transcript (not while a turn runs).
  - `Longx.Projects.Tracker` (in the tree) follows every thread's `"thread:<id>"` topic:
    fills `status` / `completed_at` / `commit_after` / `diff` from `turn/completed`, the
    thread `preview` from the first user message, gives a turn the kernel started by itself
    (a goal continuation, a sub-agent's report waking an idle parent) a row via
    `record_external_turn/2`, turns a parent's first `subAgentActivity` into a Thread row
    under it (`parent_thread_id`, `agent_path` `/root/<name>`; hidden from the project's
    list, `list_subagents/1`), pushes the notify feed, and runs the **stall watchdog**: no
    event for `stall_after` (10 min; `config :longx, Longx.Projects.Tracker, stall_after:,
    tick:`) → interrupt, turn `:interrupted`. Its followed list is in memory: `host_thread/1`
    (a `ThreadChannel` join) and `send_message/3` both `Tracker.track/1` (idempotent), and
    `Projects.settle_after_restart/0` (a boot `Task`) fails every `:in_progress` turn and
    idles every `:active` thread a previous boot left.
  - **Going back**: `restore_proposal/1` (commit, dirty now?, changed files, later turns) is
    what the UI shows; `restore_files/2` needs `confirm: true`, makes a safety commit of any
    uncommitted work first, then `restore_tree` (default) or `reset_hard`. Nothing touches
    ignored files or side effects outside the repo; say so in the UI.
  - **Files and git for the UI** — two data-less resources, one generic action per
    operation, wire-tested in `test/longx_web/rpc/workspace_rpc_test.exs`:
    `Longx.Projects.Files` over `Longx.Projects.Workspace` (`list_files` one level,
    directories first, `.git` never; `read_file` 1 MB cap → `truncated`, binaries flagged;
    `write_file`, `create_entry`, `rename_entry`, `delete_entry`; every path resolved inside
    the root) and `Longx.Projects.Repo` over `Longx.Git` (`git_changes` — the whole sync
    state in one call —, `git_file_diff`, `git_commit`, `git_discard`, `git_undo_commit`,
    `git_abort_merge`, `git_log`, `git_show`, `git_commit_file_diff`, `git_file_versions`,
    `git_branches`, `git_create_branch`, `git_switch` (`stash: true`), `git_delete_branch`,
    `git_stash_pop`, `git_set_remote`, `git_fetch` / `git_pull` / `git_push`). git's own
    words come back as the error on the argument they concern; no repository →
    `repository: false` on `git_changes`, an error on `project_id` for the rest.
    `search_files/3` walks the tree (the query as a subsequence, 20 best) for `@` mentions.
  - **Attachments** (`Longx.Projects.Attachments`, `POST /attachments/:project_id`,
    `LongxWeb.AttachmentController`, multipart, 512 MB): a non-image, non-text file dropped
    on the composer is stored as `<stamp>-<name>` under `<attachments dir>/<project id>/`
    (`config :longx, Longx.Projects.Attachments, dir:`; dev `data/attachments`, prod
    `$LONGX_DATA_DIR/attachments` — never the working directory) and the message carries
    `<attachment name path size />`; the agent reads or unzips the path itself.
  - **The notify feed — `Longx.Notify`**: one event shape across projects,
    `%{kind, title, body, url, project_id, thread_id, at}`, `kind` `approval` (an ask
    waiting on the person) | `turn_completed` | `turn_failed`; `url` is an SPA path
    `/p/<slug>/t/<root thread id>` (a sub-agent's event points at its parent's page —
    `Projects.notify/3`, `thread_label/1`). `LongxWeb.NotifyChannel` (`notify` on the user
    socket): the join reply carries `running` (`Projects.running_threads/0`, `waiting`
    marked), then one `"event"` push per event — what the Android shell joins to raise
    notifications without FCM. `PubSub.broadcast(topic/0, {:notify, event})`.
- **The agent kernel — `lib/longx/agent/`.** The kernel is four things — the process, the
  transcript, the execution of model and tool calls, and an interpreter of *phases and
  effects* — and everything else is a **plug**, the one concept. **No sandbox, no approvals,
  no policy**: commands run on the machine as the person (isolation is the deployment's job
  — the whole of Longx in a container — never the kernel's). Directory layout, one per
  concern: `agent.ex` (the loop), `agent/kernel/` (`State`, `UI`, `Team`, `Goal`, `Asks`,
  `Calls`, `Compaction`, `Specs`, `Stream` — the pieces the loop calls), `agent/definition/`
  (`Config`, `Loader`, `Layout`, `Settings`), `agent/plugs/`, `agent/pipelines/default.ex`,
  `agent/tools/` (`Patch`, `ShellEnv`), `agent/model.ex` + `model/sse.ex`,
  `agent/thread_state.ex` + `thread_state/store.ex`, `agent/transcript.ex` +
  `transcript/item.ex`, `context.ex`, `knowledge.ex`, `pipeline.ex`, `plug.ex`, `step.ex`,
  `tool.ex`.
  - `Longx.Agent` — one GenServer per thread (`Longx.Agent.Registry`, under
    `Longx.Agent.Supervisor`, `restart: :temporary`), **the loop as OTP recursion**: a step
    runs the pipeline at `:request` (pure: prompt, tools, the request), the model streams
    from a task (`Longx.Agent.Model.run/3`; `Model.prepare/1` — target, gateway shaping, a
    DB read — runs in the kernel process so a killed task never leaves SQLite mid-query) as
    `{:model, ref, event}` messages, the pipeline runs at `:response` (the model's calls
    known, none run yet), tool calls run as tasks under `Longx.Agent.TaskSupervisor` and
    answer as messages, `handle_continue(:step)` recurses until the model answers without a
    call, then the pipeline runs at `:turn_end`. **Never a blocking receive or a
    synchronous model call in a callback**: the mailbox is how steer, interrupt and
    `/compact` get in. `send/3` (`turn_id:`, `model:`, `effort:`, `images:`, `from:`)
    starts a turn when idle and is a *steer* while one runs (into the context at the next
    step after the tool outputs, and shown then; a step is added when the model had already
    stopped); `interrupt/1` kills the tasks (a command's shim tree dies with its task) and
    ends the turn `interrupted`; `retract/2`; `compact/1`; `status/1`; `respond/3` answers
    an ask; `set_goal/2` / `clear_goal/1`. Guards: `max_steps` per turn (500, `config
    :longx, Longx.Agent, max_steps:`) and 20 continuations. **The process is light and
    leaves when idle** (`idle_ms:`, 30 min; `{:stop, :normal}`): `Longx.Agent.Kernel.Specs`
    (ETS, in the tree) keeps what every agent was `ensure`d with, `ensure_alive/1` starts
    it again from that and its transcript, `send/3` does so by itself. `Agent.stop/1` is a
    graceful `GenServer.stop` that stops the children first (a supervisor kill left writes
    mid-transaction). A BEAM restart forgets the specs; `Projects.host_thread` rebuilds
    from the row.
  - **A team is more processes of the same loop, talking through the mailbox** — no wait
    tool, no shared inbox: `Agent.spawn/4` (`spawn(parent_id, name, task, role:/model:/
    effort:/cwd:/depth:/path:)`, or the `Step.spawn/4` effect from any phase) starts a
    child `Longx.Agent` (`parent:` + `name:` options; `info/1`, `children/1`; names made
    unique — `helper-2`) and sends it the task; the child's final message is its report,
    **a message in the parent's mailbox**: a steer while the parent runs, a new turn when
    it is idle (the Tracker gives it a row). Words between agents are **user messages
    prefixed `[agent <name>] `** (the Responses API has no agent role every provider reads)
    with `"from"` on the UI item. `subAgentActivity` items (started / interacted /
    completed / interrupted; `Agent.interacted/2`) are `:activity` transcript items — UI
    only, `append(…, context?: false)`, never in the model's context. **A finished child
    stays in the team** (`children/1`: `id`, `name`, `status` working / done / failed,
    `role`, `task`, in the order made): its transcript is kept, so a follow-up
    `send/3` (`from:` the asker's name, `reply_to:` its thread id) continues it on the
    same prefix — the provider caches it, a fresh spawn would start from nothing — and
    the answer of the turn a message starts goes to `reply_to`, the parent otherwise.
    A child's idle exit (`:normal`, `:noproc`) keeps it a member with `pid` nil; `send/3`
    revives it through `Specs` and `Agent.interacted/2` re-monitors the new process; a
    crash marks it `failed` and is a message "[agent X] exited: reason"; only
    `forget_child/2` (the `close_agent` tool, which also stops it and deletes its spec)
    removes one. `max_children` counts working members. The team survives the parent
    leaving idle: `init` rebuilds it from `Specs.children_of/1` (specs carry `parent:`,
    `task:`, `spawned_at:`), and after a BEAM restart `Projects.ensure_agent` registers
    the children's specs from their rows (`register_team_specs/1`) before starting the
    parent, so `host_thread/1` lists the team again and a follow-up revives a child from
    its row. Siblings — the parent's other children, read from `Specs`, never a call to
    the parent (it may be calling this agent) — are `step.assigns.siblings`; a child may
    `send_message` one and gets its answer itself. A child monitors its parent but goes
    on when it leaves idle or crashes (the child's report brings it back from its spec);
    it stops with the parent only when the parent's spec is gone for good (`Agent.stop`
    stops the children first anyway). **Depth guard**: a spawn past `max_depth`
    (settings; `config :longx, Longx.Agent, max_depth:` 2) answers `{:error, :too_deep}` —
    a strategy plug inherited by every child recursed for ever without it. How a child is
    made is the `spawner:` function the agent was `ensure`d with
    (`Longx.Projects.spawn_native_agent/4`: a Thread row under the parent, the task as its
    first Turn row). `step.assigns` carries `parent`, `name`, `children`, `siblings`;
    **`step.state`** (`Step.put_state/3`) is a map kept across the phases and steps of
    one turn. `Plugs.Agents` offers `spawn_agent` / `send_message` (every member and
    sibling) / `close_agent` (own members) over the **declared roles**
    (`.longx/shared/agents/<name>/agent.exs`, `local/agents/<name>/`); the prompt lists
    the team with status, role and task and says to ask a finished agent again rather
    than spawn anew; with no role declared the spawn tool is absent and the prompt
    teaches the model to declare one (`local/agents/<name>/agent.exs` + `prompt.md`) —
    **Longx ships no roles**: they grow in the project and are promoted to `shared/`.
    Prefix stability is what makes a follow-up cheap: nothing in the request varies per
    step but the transcript itself (Environment's date changes daily, the knowledge
    index and the model list only when they do).
  - **Effects are what a plug asks the kernel to do**, data on the step interpreted after
    each phase: `Step.enqueue_call/3` (`:response`; a synthetic `function_call` with a
    `longx_` id, run with the model's), `Step.continue/2` (`:turn_end`; another step with
    that text instead of ending), `Step.compact/2` (`:request`), `Step.halt/2` (end the
    turn `failed`), `Step.spawn/4`, `Step.goal/2`. `step.usage` (`last` / `total`) and
    `step.context_window` let a plug judge the context; `step.calls` are the model's calls
    at `:response`; `Step.instructions/2`, `Step.tool/2`, `Step.raw_tool/2` build the
    request.
  - **Events keep codex's vocabulary** (`turn/started`, `item/started`,
    `item/agentMessage/delta`, `item/reasoning/summaryTextDelta`,
    `item/commandExecution/outputDelta`, `item/completed`, `thread/tokenUsage/updated`,
    `turn/completed`, `thread/goal/updated`, a `contextCompaction` marker,
    `longx/action/request` for an ask), fed to `Longx.Agent.ThreadState.ingest/3`. A
    tool's `show` decides the item: `:command` → `commandExecution`, `:file_change` →
    `fileChange` (a unified `diff` per change), `:tool` → `dynamicToolCall`,
    `:web_search` → `webSearch`.
  - **The tool set is codex's by name and parameters** — models tuned for codex call them
    as they know them: `exec_command` (`Plugs.Shell`: `cmd`, `workdir`, `tty` (a pty through
    the shim), `timeout_ms` (default 2 min, max 30 min; the command runs to completion —
    `write_stdin` sessions are not offered), `max_output_tokens`, `shell`, `login`;
    stdout+stderr interleaved, head+tail kept, exit code reported; `Longx.Agent.Tools.
    ShellEnv` builds the environment), `apply_patch` (`Plugs.Patch` over
    `Longx.Agent.Tools.Patch`: codex's patch grammar parsed and applied in Elixir — all
    hunks matched first, then written; for a provider of `kind: :openai` the same tool as a
    grammar-constrained `custom` tool from `priv/agent/apply_patch.lark`; instructions from
    `priv/agent/apply_patch.md`), `view_image` (an `input_image` user message after the
    result). There is no `read_file` / `list_dir` / `grep_files`: reading is `exec_command`
    (`cat`, `sed -n`, `rg`).
  - **The base prompt is codex's, trimmed** (`Plugs.Base` reads `priv/agent/base_prompt.md`
    at compile time: sandbox / approvals / plans / AGENTS.md sections out, our tool names
    in, "reply in the user's language" added). `Plugs.Environment` adds the working
    directory, OS and architecture, the shell and today's date; `Plugs.Prompt` the
    description's prompt or a loader notice; `Plugs.Local` what the agent is told about its own definition
    (the reference `priv/agent/reference.md`, its layout, and a `# Models` section from
    `Longx.AI.model_choices/0` — aliases first, then slugs with levels and the default).
  - `Longx.Agent.Transcript` (Ash domain) / `Longx.Agent.Transcript.Item` (`agent_items`):
    the append-only log — every Responses input item (`input`: user / assistant message,
    reasoning, `function_call`, `function_call_output`, `compaction`) with its UI item
    (`ui`), `seq` / `turn_id` / `model` and a `kind` (`:activity` rows — sub-agent
    activity — are UI only and never part of the context). The
    model's context is `Transcript.input/1`: from the last `:compaction` boundary, the
    user's own messages before it verbatim (newest first within `keep_user_bytes`, 80 KB),
    the summary, then everything after; a `function_call` without an output gets a
    synthetic "interrupted" output. A boot replays the `ui` items through
    `ThreadState.backfill`; a retract is a truncation.
  - **Descriptions: `Longx.Agent.Config`** (the DSL: `version` / `extends` / `model` /
    `prompt` / `prompt_file` / `summary` / `agents` / `plug` / `options` / `drop` /
    `pipeline`), data evaluated before anything runs, the same format in every layer.
    `import Longx.Agent.Config; agent do version 1; extends :default; model "pro", effort:
    "high"; prompt "…"; plug Deploy, after: Shell; options Shell, timeout_ms: …; drop Patch
    end` — a description records the **difference** to the layer below (`Config.resolve/2`
    applies the ops; a short name means the shipped plug, `Config.builtin/1`), so a release
    that changes the shipped pipeline (`Longx.Agent.Pipelines.Default.config/0`:
    Environment, Base, Shell, Patch, ViewImage, Knowledge, WebSearch, Browser, Agents,
    Goal, Request; a description's `prompt` becomes a `Plugs.Prompt` after them —
    `Config.with_prompts/2`) reaches every project; an
    explicit `pipeline do … end` replaces the base and freezes it. `version` is the format
    version (`current_version/0`, `outdated?/1` → a notice). The DSL words are paren-free in
    `.formatter.exs`. **Layers** (`Longx.Agent.Definition.Loader`): the shipped default →
    the project's `.longx/agent.exs` + `.longx/shared/` (agents, plugs, knowledge; in git;
    **behind `Project.trust_local_agent`**, default off — a cloned repo executes nothing
    until the person looked) → `.longx/local/` (the same three plus an optional
    `agent.exs`; gitignored via `Layout.ensure_ignored/1`; **always loaded**: it is what
    the agent wrote on this machine) → the settings layer (`Longx.Agent.Definition.
    Settings`: `max_depth` 2, `max_children` 4, `idle_minutes` 30, `child_model` /
    `child_effort`, the reviewer model — global in `Longx.System.Setting`, overridden per
    project by `Project.agent_settings`). **No global code layer**: no global agents, plugs
    or skills; the only thing shared across projects is the global knowledge. A layer is
    `agent.exs` + `plugs/**/*.exs` + `agents/<name>/agent.exs`; every `defmodule` of a layer
    and every reference to it is renamed under `Longx.Agent.Local.<tag>` before
    `Code.compile_quoted`, so two projects may both define `Deploy`; cached per layer by the
    files' mtimes and sizes (`Loader.Cache`), recompiled on change; a file that fails to
    load leaves the layer below in force and becomes a **notice** in front of the model
    (`⚠ … failed to load …`), as does an outdated version, a plug nobody defines, and a
    description naming a model Longx does not have (the default runs instead —
    `description_model/3`). `Layout.promote/2` (`Projects.promote_local/2`, RPC
    `promote_local`) moves a local file into `shared/`. `Projects.agent_definition/1` (RPC
    `agent_definition`) lists the files, the resolved plugs, the notices and the
    description's model (`definitionModel`, what the composer shows). `Longx.Agent` loads
    per step when no `pipeline:` module is given (tests give one).
  - **Knowledge instead of memory — `Plugs.Knowledge` over `Longx.Agent.Knowledge`**:
    markdown with front matter (`title`, `summary`, `tags`, `always: true`) in four roots —
    `longx/` shipped read-only (`priv/agent/knowledge/`: `writing-plugs.md`,
    `description-format.md`), `global/` the person's (`config :longx,
    Longx.Agent.Knowledge, global_dir:`; dev `data/agent/knowledge`, prod
    `$LONGX_DATA_DIR/agent/knowledge`; **a git repository only when `Longx.Git.available?/0`**,
    a commit per write under a lock; plain files otherwise), `project/`
    (`.longx/shared/knowledge/`, committed with the code), `local/`
    (`.longx/local/knowledge/`, where the agent writes by default). **Every doc belongs to
    a topic** (`<root>/<topic>/<name>.md`); the index folds a topic into one line (its
    `README.md` stands for it), `knowledge_read("local/deploy")` lists the topic. Always-docs
    go into every prompt (`always_cap:` 16 KB), the rest as an index line each
    (`index_cap:` 200); tools `knowledge_read`, `knowledge_search`, `knowledge_write`
    (front matter required; `longx/` refused; paths stay inside their root);
    `Knowledge.promote/2` moves local → project. Skills are docs; AGENTS.md is not read
    (`Plugs.AgentsMd` exists, out of the shipped pipeline).
  - **Models are named by tier or alias, never hard-wired** — `Longx.AI.Aliases`: three
    tiers `ultra` (旗舰) / `pro` (高级) / `plus` (普通), case-insensitive, plus custom
    aliases (青龙…), each mapping to a **chain** of slugs (`resolve_targets/1`); a
    description, a child's default model, the composer and RPC all take a tier, an alias or
    a slug. `Longx.Agent.Model` walks the chain: a refusal for quota (429 or
    `quota|exhaust|insufficient|balance|credit|billing|payment|exceeded your` — final, no
    retry), a rejected key or a dead upstream moves to the next target and emits
    `{:fallback, from, to, why}` → `model/rerouted` (a toast "模型已切换"). Other 429 / 5xx /
    transport errors before anything streamed are retried (`retry_ms:` `[5_000, 15_000,
    30_000]`; `[10, 10]` in tests); a 4xx is final. The task monitors its owner and dies
    with it. `Longx.Agent.Model.SSE` parses the stream into `{:item_added | :text_delta |
    :reasoning_delta | :reasoning_text_delta | :item_done | :completed | :failed}`. Every
    request goes through `Gateway.prepare/2` (reasoning items sanitised per provider, the
    output cap), a `Limiter` slot and a `Gateway.Log` entry (`request_kind` `agent` /
    `compaction`).
  - **Asks — a formal channel for "the person must do something"** (`Plugs.Request`,
    `Longx.Agent.Kernel.Asks`): a plug calls `Context.ask(ctx, title:, text:, url: | url:
    fn callback_url -> … end, fields:, callback: true, timeout:)`; the thread gets a
    `longx/action/request` request (`ThreadState.put_request`, an `action` part in the
    chat: title, text, 打开链接, 已完成 / 取消 or the fields; the rail says 等待你操作; the
    Tracker notifies); `Agent.respond/3` (RPC `answer_request`) or a third party hitting
    `GET /callback/:id` (`LongxWeb.CallbackController`, `Longx.Agent.Registry {:ask, id}`)
    hands the answer to the waiting tool. The callback base is `Longx.System.public_url/0`:
    the `public_url` setting, else the address the last browser connected from
    (`LongxWeb.Origins.last/0`, from the socket's `connect_info: [:uri]`), else
    `Endpoint.url()` — never a port opened on the server for a browser elsewhere.
  - **Web search and reading pages** are two plugs. `Plugs.WebSearch` (`mode:` `:auto` /
    `:hosted` / `:standalone` / `:off`): *hosted* when the model's provider searches on its
    side (`Longx.AI.web_search_mode/1` — OpenAI, 百炼 Qwen 3.5+ / DeepSeek-v4 / glm-5.2; the
    model dialog's 联网搜索) — the request carries `{"type": "web_search",
    "external_web_access": true}` through `Step.raw_tool/2` and the kernel turns the
    provider's `web_search_call` items and `url_citation` annotations into `webSearch`
    rows (kept as `:hosted_call`; `Gateway.prepare` drops them for a target that does not
    search) — *standalone* for every other model: `web_search(query, recency_days,
    domains)` over `Longx.AI.Search` (Tavily; no provider → said inside the result). The
    thread's 联网搜索 switch reaches the kernel as `web_search:`; `false` mounts nothing.
    `Plugs.Browser` is `web_fetch(url, format, selector)` in every mode — obscura through
    `Longx.Browser.fetch/2`, markdown by default; while the browser is still being
    downloaded the tool answers "being downloaded (N%)".
  - **Compaction, codex's shape** (`Plugs.Compaction` policy; `Kernel.Compaction`
    execution): the kernel folds on its own when the person types `/compact`
    (`Agent.compact/1`: at once when idle, before the next step when running) and when the
    provider refused the request for its length (`assigns.context_overflow`, `:request`
    re-run once); the plug — in the shipped pipeline since 2026-09-18; a project may
    `drop` it or set `options Compaction, at: …` — asks (`Step.compact/2`) when the
    context passed `at:` (0.9) of the window or the model called `new_context_window`,
    and offers `get_context_remaining`.
    The kernel streams a summary from a
    task (`priv/agent/compact/prompt.md`, no tools), appends a `:compaction` item
    (`summary_prefix.md` + the summary as a user message), emits the `contextCompaction`
    marker, reloads the context and continues the step. A failed summary: the step goes on
    without folding, or fails the turn when the provider had refused the length.
  - **Goal mode** (`Plugs.Goal`, `Kernel.Goal`): `create_goal` / `update_goal` / `get_goal`;
    with the goal `active` the `:turn_end` phase continues the turn with a step naming the
    objective until the model marks it `complete` / `blocked`, the token budget is spent
    or `max_rounds:` (8) continuations happened (then `blocked`, never a loop).
    `Agent.set_goal/2` (RPC `set_goal` / `clear_goal`, the `/goal` command, `GoalBar`)
    sets the same goal; `thread/goal/updated` is the view's `goal`.
  - `Longx.Agent.ThreadState` + `.Store`: the Store (in the tree) owns three public ETS
    tables (meta / items / requests) holding every live thread's materialised view; a
    ThreadState (`Longx.Agent.ThreadRegistry` + `ThreadState.Supervisor`, one per live
    thread) is the **single writer**: folds each event (deltas append in place —
    reasoning `summary` / `content` are `string[]` addressed by index —, `item/completed`
    replaces), allocates a strictly increasing `seq` (a seqlock via `Store.event/2`;
    `snapshot/1` retries a torn read), broadcasts `{:thread, seq, method, params}` on
    `"thread:<id>"`. Reads go straight to ETS. Pending asks are in the view with a
    `"requestId"`. **Page refresh / late join: `subscribe` → `snapshot` (has `seq`) →
    render → apply only events with `seq > snapshot.seq`.**
  - Tests: `test/longx/agent/` (`pipeline_test` the DSL and phases, `definition/{config,
    loader,settings}_test`, `knowledge_test`, `web_search_test` (Tavily by Bypass, the fake
    obscura), `tools/{patch,shell_env}_test`, `model/sse_test`, `plugs_test` runs real bash,
    `transcript_test`, `thread_state_test`, `model_test` and `agent_test` with **Bypass as
    the model** — a held reply for steer / interrupt / retract, `Bypass.pass/1` after a
    reply the interrupt cut off, a restart rebuild, effects, teams, asks, the step limit,
    compaction by effect / overflow / hand), `test/longx/projects/threads_test` (through
    `Projects`, the Tracker completing rows, the trust switch). Every test that starts
    agents ends with `Longx.Test.Agents.stop_all!/0` (stops them gracefully and drains the
    Tracker before the sandbox ends).
- **Model access — `lib/longx/ai/`**, Ash domain `Longx.AI`:
  - `Provider` (base_url + `api_key` encrypted at rest via `AshCloak` + `Longx.Vault`; key
    from `LONGX_CLOAK_KEY` in prod, fixed keys in dev/test; `kind` `:openai` |
    `:openai_compatible` derived from the base_url unless given; `request_timeout_ms` (10
    min) and `max_concurrent_requests`; `last_error` / `last_error_at` / `last_checked_at`
    written by `check_model/1` and on upstream 401/403) and `Model` (`upstream_id`, `slug`,
    `context_window`, one `default`, `reasoning_levels` (ordered; DeepSeek / GLM `low /
    high / max`), optional `reasoning_effort` (one of the levels — `EffortInLevels`),
    `reasoning_summary`, `max_output_tokens`, `hosted_web_search`). `AI.check_effort/2`
    refuses a level the model does not declare; unknown slugs are refused in
    `Longx.Projects`. `resolve_target/1` (`longx` = the default model) = model + its
    provider's decrypted key.
  - **Presets** (`Longx.AI.Presets`, pure data + `apply/2`, idempotent): DeepSeek, GLM,
    阿里云百炼 Token Plan (个人版 / 团队版) and OpenAI with endpoint / kind / hosted search /
    key url / docs url and their models. **Any provider's own list**: `discover_models/1`
    asks `GET <base_url>/models` and normalises each entry (window, levels, default level,
    image input, `installed`). Over RPC via the data-less `Longx.AI.Preset` (`list_presets`,
    `apply_preset`) and `discover_models` on `Provider`. Seeds (`priv/repo/seeds.exs` →
    `Longx.AI.Seeds`, run by `mix ash.setup` / `mix test`, never by a release) apply the
    DeepSeek preset without a key (`deepseek-flash` the default) and the OpenAI provider
    alone — keys are entered in Settings, not read from the environment. A new NOT NULL
    column needs a `default:` in the migration (SQLite).
  - `Longx.AI.Aliases` (above): RPC `model_aliases` / `set_model_alias` /
    `delete_model_alias`; `model_choices/0` is what the agent is told.
  - `Longx.AI.Gateway.prepare/2` shapes a Responses request for its target: the
    placeholder `longx` swapped for the `upstream_id`, `stream: true`, `max_output_tokens`
    from the row, the hosted `web_search` tool kept only for a provider that searches.
    **Reasoning items never cross providers**: an `:openai` target keeps only its own
    `rs_`-prefixed items intact; every other target gets **no** `encrypted_content`;
    readable `summary` / `reasoning_text` stay; an empty item is dropped. Degraded path: an
    `:openai` target answering 4xx about `encrypted` / `reasoning` gets one retry with
    `strip_all_encrypted/1`. The module keeps its gateway name; there is no HTTP gateway
    route any more — the kernel calls the upstream itself.
  - `Longx.AI.Gateway.Limiter` (ETS counters, in the tree) caps in-flight requests per
    provider (`acquire/2` → `:busy`; the model task sleeps through `retry_ms` and then
    fails the turn); `Longx.AI.Gateway.Log` (in the tree; an ETS ring of the last 1000, `keep:`)
    remembers every model request — `begin/2` with the thread / turn / `request_kind`, the
    model and what it resolved to, effort / summary, the tools' names, input size —
    `finish/2` with status / error; RPC `gateway_requests(limit)`; Settings → 请求记录.
  - `Longx.AI.Search` (`search/3` over `Longx.AI.SearchProvider`, Tavily, key encrypted);
    `Longx.AI.ensure_search_provider/0` creates the row at boot (a `Task` after the
    migrator) so a fresh install has a 联网搜索 section to enter the key in.
  - Upstreams are all OpenAI **Responses API**: OpenAI `https://api.openai.com/v1`,
    DeepSeek `https://api.deepseek.com/v1`, GLM `https://open.bigmodel.cn/api/v1`, Bailian
    Token Plan `https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`.
    Adding a provider = a DB row, no code.
- **The headless browser is obscura, downloaded on first use** (`h4ckf0r0day/obscura`,
  Rust + embedded V8, Apache-2.0; nothing in `priv/`, no mix task, no release step).
  `Longx.Browser.Runtime` pins the version (five targets; sha256s computed once when
  pinning, verified on every download; only windows arm64 has no build);
  `Longx.Browser.Installer` (GenServer + `Longx.Browser.TaskSupervisor`, in the tree)
  downloads into `config :longx, Longx.Browser, dir:` (dev `data/obscura`, prod
  `$LONGX_DATA_DIR/obscura`) as `<dir>/<version>/<target>/`, stages `idle` /
  `downloading` (`received`, `total`) / `verifying` / `extracting` / `installed` /
  `failed` broadcast as `{:browser_install, status}`; the first `Browser.fetch/2`
  auto-installs; RPC `browser_status` / `browser_install` / `browser_settings` /
  `set_browser_private_network`; the card in Settings → Agent 内核 and the status strip
  draw the bar (`DownloadBar`, shared with the upgrade). `LONGX_OBSCURA` overrides.
  - `Longx.Browser.fetch(url, format: :html | :markdown | :text, timeout:, wait_until:,
    selector:, wait:, max_bytes:)` — **one short-lived `obscura fetch` process per page**
    under `Longx.Shim.run/2` (killed with its tree at the deadline, `oom_score_adj` 600),
    so an idle system runs no browser. `:html` is the page reduced by
    `Longx.Browser.Html.main/1` (the main element without scripts, styles, nav, forms;
    only meaningful attributes). obscura keeps its SSRF guard unless
    `allow_private_network: true` (the setting; tests against Bypass set it).
  - `Longx.Browser.Pool` (in the tree) hands out permits: at most `max_concurrent`
    (`min(4, schedulers)`) fetches at once, FIFO waiting up to `queue_timeout` (10 s →
    `{:error, :busy}`), permits tied to the caller by monitor.
  - Tests: `test/support/fake_obscura.sh` plays the CLI; `config/test.exs` points
    `executable:` at a nonexistent path and `dir:` at a tmp dir so the unit suite never
    runs or downloads the real one; `test/longx/browser_integration_test.exs`
    (`:integration`) downloads the real binary (~60 MB) into a tmp dir and renders a
    Bypass SPA.
- **System** — `Longx.System` (domain) → `Longx.System.Status` generic actions:
  `list_directory` / `create_directory` (`Longx.System.Directory`, the project wizard's
  picker), `knowledge_docs` / `knowledge_read` / `knowledge_write` / `knowledge_delete`
  (the global knowledge), `agent_settings` / `set_agent_settings`, `public_url` /
  `set_public_url`, `dependencies` / `check_dependencies`, `upgrade_status` /
  `upgrade_check` / `upgrade_apply` / `set_github_token`, `gateway_requests`, the browser
  actions. `Longx.System.Setting` is the key/value store (`:encrypted_value` — upsert
  names that column, else a second put never updates).
  - **`Longx.System.Dependencies`** — the command-line tools the agent leans on: `rg`,
    `fd` (`fdfind` on Debian), `fzf`, `bat` (`batcat`), `jq`, `tree`, `git`, `gh`, `delta`;
    `check/1` runs `--version` through the shim (2 s cap), cached in `persistent_term` for
    10 min (`force: true`, `forget/0`); each entry carries the apt / brew / winget package
    so the UI can print one install line per platform. **Detect and tell, never install.**
    Settings → 系统依赖; the status strip says "缺少 N 个依赖".
  - **Self-upgrade** — `Longx.Upgrade` (GenServer + `Longx.Upgrade.TaskSupervisor`):
    `check/1` asks GitHub's `releases/latest` (`config :longx, Longx.Upgrade, repo:` —
    `mjason/longx` —, `api_url:`; `LONGX_UPDATE_REPO` / `LONGX_UPDATE_API`; the saved
    `github_token` as bearer), refreshes every `tick` (6 h; nil in tests). `apply/0` works
    only inside an install (`RELEASE_ROOT/bin/longx` exists, or `app_dir:` in tests):
    tarball + `.sha256` into `<home>/downloads` with progress (`Longx.Bundle` streaming,
    `progress: %{received, total}`), verify, `VACUUM INTO <home>/backups/longx-<current>-
    <stamp>.db`, unpack to `app.new`, swap `app` → `app.old` → `app`, then
    `restart_command` (`systemctl --user restart --no-block $LONGX_SERVICE`); no way to
    restart → stage `:installed`. Every stage is `{:upgrade, status}` on `Upgrade.topic/0`;
    the SPA polls while a stage runs and reloads once another version answers.
- `lib/longx_web/` — Phoenix web layer. **The React SPA owns the URL space**:
  `LongxWeb.PageController.spa/2` serves the shell for `/` and, as the router's **last**
  route (`get "/*path"`, pipeline `:spa`), for every other HTML navigation; it answers 404
  for non-HTML `Accept`s and file-looking paths. `/rpc/*`, `/attachments/*`, `/callback/*`,
  `/socket`, `/dev/*` are matched before it. No LiveView pages.
  - `LongxWeb.Actor` is the single place an actor comes from (RPC conn, socket params) —
    `nil` today; AshAuthentication plugs in there later without touching the client.
  - **RPC** = ash_typescript: domains `Longx.Projects`, `Longx.AI`, `Longx.System` declare
    `typescript_rpc` blocks; work that lives in domain functions is exposed as **generic
    actions** whose `run` calls the existing function and whose return is a typed map or
    `:struct`. `POST /rpc/run` is tested at the wire in `test/longx_web/rpc/` so the
    generated client's contract is what is tested. Every call carries Phoenix's CSRF token
    via the lifecycle hook (`assets/js/core/rpcHooks.ts`). Thread RPC: `list_threads`,
    `get_thread`, `list_subagents`, `start_thread`, `send_message`, `steer_turn`,
    `interrupt_turn`, `retract_turn`, `compact_thread`, `answer_request`,
    `list_running_threads`, `set_goal` / `clear_goal`, `rename_thread`, `archive_thread`,
    `delete_thread`; Project: `list_projects`, `get_project` (by slug), `create` / `update`
    / `archive` / `delete_project`, `git_info`, `init_git`, `search_files`,
    `agent_definition`, `promote_local`; Turn: `list_turns`, `restore_proposal`,
    `restore_files`.
  - **Channels** (`LongxWeb.UserSocket` at `/socket`, `connect_info: [:uri, session]` — the
    uri feeds `LongxWeb.Origins`): `LongxWeb.ThreadChannel` (`thread:<kernel_thread_id>`,
    join → `Projects.host_thread/1` starts the agent again after a restart) replies with
    the snapshot (`seq`), then pushes `"event"` `%{seq, method, params}`, `"snapshot"` on
    demand. `LongxWeb.ProjectChannel` (`project:<id>`) pushes `"changed"` (rows changed →
    refetch; `Projects.broadcast_changed/1`) and `"files"` (`broadcast_files_changed/2`).
    `LongxWeb.NotifyChannel` above. Tests: `LongxWeb.ChannelCase`.
  - **Vite ↔ Phoenix is ours** (`LongxWeb.Vite`, `LongxWeb.Vite.Watcher`; phoenix_vite was
    rejected as immature). `<LongxWeb.Vite.assets />` renders, in dev, the React Fast
    Refresh preamble + `@vite/client` + the entry from the Vite dev server (`config :longx,
    LongxWeb.Vite, dev_server:`; `LONGX_DEV_HOST=<lan-ip>` for phone testing — Vite listens
    on `0.0.0.0:7799`, `strictPort`) — otherwise the hashed files from
    `priv/static/assets/.vite/manifest.json`. The dev watcher runs `npm run dev` **through
    `Longx.Shim`** so Vite dies with the BEAM. `mix assets.build` = compile +
    `ash_typescript.codegen` + `npm run build` → `priv/static/assets/` (gitignored); no
    `phx.digest`. PWA bits are committed static files.
- `assets/` — Vite + TypeScript + React 19, tests with vitest/testing-library
  (`npm run check` = `tsc --noEmit` + `vitest run`, part of `mix precommit`). Layout:
  - `js/core/` — **DOM-free**, the part a React Native app will reuse: the generated client
    (`ash_rpc.ts`, `ash_types.ts` — **generated** by `mix ash_typescript.codegen`, never
    edited; `codegen --check` runs in precommit), `rpcHooks.ts`, `socket.ts`,
    `projectChannel.ts`, TanStack Query hooks (`projects.ts` — `RpcFailure` carries field
    errors —, `ai.ts`, `agent.ts` (definition, settings, public URL), `browser.ts`,
    `dependencies.ts`, `upgrade.ts`, `workspace.ts`), `frame.ts` / `workbench.ts` /
    `viewport.ts` / `theme.ts`, and `core/chat/`: `thread.ts` (the client half of
    `Longx.Agent.ThreadState`: snapshot + `applyEvent` with the Store's fold rules;
    `thread/reverted` drops turns; a `requestId` means a pending ask), `threadChannel.ts`,
    `useThreadView.ts` (**events fold once per animation frame** — `batch.ts`; a React
    commit per delta died as "Maximum update depth exceeded"), `messages.ts` (kernel items →
    assistant-ui `ThreadMessageLike`: one assistant message per turn, split at each steered
    user message; `metadata.timing`; agentMessage → text, reasoning → reasoning,
    commandExecution / fileChange / webSearch / action / subagent → tool-call parts;
    `"from"` on an agent's message; a sub-agent's activities folded into one `subagent`
    part whose `messages` is the child's own conversation), `adapter.ts` (`buildAdapter` →
    `ExternalStoreAdapter`: `onNew` → `steerTurn` while `runningTurnId(view)`, else `sendMessage`
    (a `dirty_tree` error asks `onDirtyTree`); `/goal <objective>` typed past the popover
    sets the goal; `onCancel` → `retractTurn` + `onRetract(text)` while `turnHadEffects`
    is false, else `interruptTurn`; `extras.answerAction`), `threadList.ts`, `runtime.ts` (**`useLongxRuntime({ projectId, defaults, threadId,
    onOpenThread })`** — the whole thing as one hook; everything the adapter is built
    from must be referentially stable — `runtime.test.tsx`; assistant-ui's
    `createMessageQueue` is the runtime's queue: a message sent while a turn runs waits
    above the composer (the `message-queue` element: 取消 / 插入) and goes out as a new
    turn when the turn ends, 插入 → `insertQueued` steers it into the running turn now),
    `mentions.ts`,
    `fileAttachments.ts`, `reasoningSteps.ts`.
  - `js/ui/` — React DOM, **shaped like an IDE with the chat where the editor would be**.
    `routes.tsx`: `/` (`pages/WelcomePage`: recent projects, what is running now —
    `useRunningThreads`, waiting ones first and amber), `/new` (`pages/ProjectWizard`:
    `components/DirectoryPicker` on the server's file system, then name / initialise git /
    model), `/p/:slug` and `/p/:slug/t/:threadId` (`frame/ProjectWindow` + `chat/ThreadPage`),
    `/p/:slug/settings` (`pages/ProjectSettingsPage`: name, description, defaults, the
    definition with the trust switch and 提升到 shared, `AgentSettingsFields` overrides,
    `GitCard`, danger zone), `/settings/:section` (`pages/SettingsPage`: `models` 模型与
    Provider — providers as cards, presets first, `LevelsEditor`, 档位与别名 —,
    `dependencies` 系统依赖, `knowledge` 知识 (global docs in the CodeEditor, a save is a
    commit when git is there), `agent` Agent 内核 (settings, public URL, the browser card,
    private network), `update` 版本与更新, `requests` 请求记录, `appearance` 外观).
    `ProjectWindow`: desktop = icon rail + docked resizable tool window + status strip;
    phone = chat full-screen, bottom toolbar, tools as bottom sheets. Tool windows
    `frame/tools/{Threads,Git,Turns,Agents,Files}Tool` toggled with ⌘1–5 (`core/frame.ts`,
    remembered per device): Threads is the `thread-list` element; Git is GitHub Desktop's
    shape (branch popover, sync button, Changes, History); Turns is the history with the
    per-turn diff, restore (proposal → confirm → `restore_files`) and the
    `checkpoint-history` element; Agents is the thread's sub-agents as `background-inbox`;
    Files is the IDE tree (git status coloured, ignored dimmed, new / rename / delete, a
    filter over `search_files`). `frame/StatusStrip`: HEAD and dirty count, missing
    dependencies, the browser download, a new version — every item `whitespace-nowrap
    shrink-0`. **The centre is an editor area** (`ui/workbench/Workbench`, state in
    `core/workbench.ts`): the chat tab first and always, files and diffs from the tools;
    `EditorTab` = `ui/editor/CodeEditor` (CodeMirror 6, lazy languages + Elixir, our tokens
    as the theme, ⌘S), `DiffTab` = `ui/editor/DiffView` (`@codemirror/merge`, side by side
    or unified, collapsed unchanged stretches). `components/CommandPalette` (⌘K),
    `components/DownloadBar` (browser and upgrade), `ThemeToggle`, `Logo`; `strings.ts`
    (all UI copy, zh-CN); `core/theme.ts` follows the OS by default; `core/viewport.ts`
    (phone < 768 ≤ tablet < 1024 ≤ desktop). **The native-shell bridge**
    (`ui/shell/longxShell.ts`, mounted as `ShellBridge`): the Android app
    (github.com/mjason/longx-android) injects `LongxAndroid.post(json)` — page → shell
    `ready`, `theme`, `openExternal`, `pick` (a native single-choice list; the composer's
    model and level picker inside a shell); shell → page `LongxShell.back()`,
    `navigate(path)`, `resume()`. `<html data-shell="android">` while installed;
    `--app-height` follows `visualViewport.height`.
  - **Mobile first**: one column; `TopBar` respects the notch, `Page` keeps ≥16 px gutters,
    the primary action sits in a fixed `BottomBar` on phones; touch targets ≥ 44 px; 16 px
    base font; the page never scrolls sideways; dark is the default theme,
    `[data-theme="light"]` the override. **Palette** (`css/app.css`): the transcript on a
    white / near-black ground, the frame one step off it, the LX logo's azure as the one
    accent (`--primary` `#2f7cf6` dark / `#1b5cf0` light); dark ground `#1c1e24`, frame
    `#15171c`; light `#ffffff` / `#f3f4f7`. Icons regenerated from
    `priv/static/images/logo.png` with `python3 assets/scripts/icons.py`. Tailwind v4 with
    shadcn token names, **no `@apply`**, no daisyUI; only `html` gets `overflow-x: hidden`.
    `DialogContent` is a flex column capped at the viewport with `DialogBody` as the
    scrolling middle.
  - **The chat** — `ui/chat/`: `ChatProvider` (mounted by `ProjectWindow` around the whole
    window: `useLongxRuntime` + `AssistantRuntimeProvider` + `DirtyTreeDialog` +
    `GoalProvider`; `useChat()` reads it), `ThreadPage` (the Thread element; the composer
    rail: `ComposerTrailing` = the `context-display` ring (a click-to-open popover, not the
    hover tooltip — the auto-scroll closed it) + the `model-selector` element standalone
    (models grouped by provider, tiers and aliases first, `efforts` from the row's
    levels; the rail shows the description's model when the project pins one —
    `definitionModel`) + the `TurnState` ("waiting" while an ask is pending)),
    `GoalBar`, `TurnBar`, `ReasoningSteps` (the `reasoning-panel` step design over
    `reasoningSteps.ts`), `SlashCommands` (`/new`, `/compact`, `/goal`, `/git` `/files`
    `/history`, `/settings`, `/init` — over `unstable_useSlashCommandAdapter` and the
    `composer-trigger-popover` element), `FileMentions` (`@` over
    `unstable_useLiveCompletionAdapter` → `search_files`; `directive-text` chips),
    `toolkit.tsx` (`defineToolkit` with `type: "backend"`, `display: "standalone"`
    renderers per item type, **all built from the registry's Tool-use elements**: every
    invocation a `tool-call` row whose body is `terminal-block` (commands), `file-tree` +
    `code-diff` (file changes), `web-search` / a `ReadPage` link row (search / `web_fetch`),
    `ActionTool` (an ask: `elicitation-form` for fields, buttons otherwise, answered via
    `extras.answerAction`), `SubagentTool` (a row with an `agent-status` pill and the
    child's conversation over the exported `AssistantParts`), `CompactionUI` for the
    marker). Attachments: `CompositeAttachmentAdapter([SimpleImage, SimpleText,
    FileUpload])` — images go out as `images`, text files appended, anything else uploaded
    to `/attachments`. Dictation is off (`DICTATION = false` in `runtime.ts`). Terminal
    output linkifies URLs (an ask's link is often printed there). `thread.aui` shows a
    stall hint (`unstable_useMessageStallDetection`, 15 s) and the timing badge; the
    viewport follows the bottom (no `turnAnchor="top"`). After `npm install` adds packages
    while `mix phx.server` runs, restart it (Vite may load two copies of React).

## assistant-ui

This project uses assistant-ui for chat interfaces.

Documentation: https://www.assistant-ui.com/llms-full.txt (the whole docs in one file — fetch
it into the scratchpad and grep; https://www.assistant-ui.com/llms.txt is the index, and any
docs page + `.mdx` is raw markdown, e.g. `/docs/runtimes/custom/external-store.mdx`).
assistant-ui also publishes the same material as Claude Code skills (`npx skills add
assistant-ui/skills` → `elements`, `tools`, `primitives`, `runtime`, `markdown`, …); they are
not vendored here — install them into your own environment when working on the chat, or
read llms-full directly.

Key patterns:
- Use AssistantRuntimeProvider at the app root of the chat (`ui/chat/ChatProvider`).
- Thread component for full chat interface (`elements/thread.aui`, slots via `components`).
- AssistantModal for floating chat widget (not used here — the chat *is* the centre).
- Runtime: `useExternalStoreRuntime` over our thread view (`core/chat/adapter.ts`) —
  **not** `useChatRuntime` / AI SDK transport: the model loop lives in `Longx.Agent`, the UI
  only projects its events. The closest published analogue is `@assistant-ui/react-opencode`
  (ExternalStoreRuntime + RemoteThreadList over a coding-agent server) — copy its shape, not
  its package.
- Capabilities are handler-driven: `onNew` (send), `onCancel` (stop), `setMessages`
  (branching), `onEdit`, `onReload`, `onRefetchThread`, `adapters.threadList`; a button
  only appears when its handler exists — never hand-roll one.
- **Do not hand-roll chat UI**: find the element in assistant-ui's catalog
  (https://www.assistant-ui.com/elements), then `npx assistant-ui@latest add <item>` in
  `assets/` (answer "n" to overwriting existing shadcn files). Elements land in
  `js/ui/components/assistant-ui/elements/` (`*.aui.tsx` read the runtime, the rest are
  props-driven) and are **source we own and adapt**: `thread.aui` (zh-CN strings, our
  composer slots), `tool-call`, `terminal-block`, `code-diff`, `file-tree`, `web-search`,
  `elicitation-form`, `agent-status`, `background-inbox`, `checkpoint-history`,
  `context-display`, `model-selector` / `model-picker`, `reasoning-panel`,
  `markdown-text` with `shiki-highlighter` and `mermaid-diagram`, `thread-list.aui`,
  `message-timing.aui`, `composer-trigger-popover.aui`, `directive-text`, `message-queue`,
  `surfaces` and `../utils/range.ts` as shared helpers.
- Tool UI: toolkit `render` per item type; `display: "standalone"` keeps a tool out of the
  collapsible trace group (commands / file changes are "informing the user", not a trace).

## Releases

`MIX_ENV=prod mix assets.build && MIX_ENV=prod mix release` builds a self-contained
release (Erlang runtime, the Go shim, the built SPA); `mix.exs`'s release step `trim_priv/1`
drops `priv/plts`. Nothing is downloaded at build time: git is the host's, the browser is
fetched at runtime. `config/runtime.exs` (prod) needs only `LONGX_DATA_DIR`: the database
(`longx.db`), the global knowledge (`agent/knowledge`), attachments, the browser (`obscura`)
and the two secrets live there — `secret_key_base` and `cloak_key` are generated on first
boot into 0600 files unless given as env vars; `PORT` (7788), `PHX_HOST`; the release serves
plain http itself (`server: true`, no `force_ssl` — TLS is a proxy's job). The endpoint has
`check_origin: :conn`: the socket's Origin is checked against the request's own Host, never
against `PHX_HOST` (`socket_origin_test`). A release seeds nothing except the Tavily row
(`Longx.AI.ensure_search_provider/0` at boot); the dev / test database gets
`Longx.AI.Seeds.run/0` through `priv/repo/seeds.exs`. `install.sh` (repo root, `curl … |
sh`) installs or upgrades in `~/.longx` (`app` / `data` / `backups` / `downloads`) as a
`systemd --user` service, verifying the sha256, backing `data` up before a swap;
`--rollback` puts `app.old` back; `LONGX_TARBALL=` installs a local build. `rel/env.sh.eex`
sets `ELIXIR_ERL_OPTIONS=+fnu`. `.github/workflows/ci.yml` runs the precommit set on every
push / PR (`mix test --exclude host_sandbox`; `:integration` and `:live` stay excluded by
`test_helper.exs`); `release.yml` builds on a `v*` tag for linux x86_64 and arm64, each
natively on its own runner (`ubuntu-24.04` / `ubuntu-24.04-arm`), and attaches the tarballs
to the GitHub release. The repository is public at github.com/mjason/longx (MIT).

## Development workflow — TDD is mandatory

Every change follows red → green → refactor. No production code without a test that
motivated it.

1. Write a failing test first and run it: `mix test test/path/to/file_test.exs:LINE`.
   Confirm it fails for the *expected* reason.
2. Write the minimum code to make it pass.
3. Refactor while green, then run the whole suite: `mix test`.
4. Before declaring done: `mix precommit`
   (`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, the Go checks,
   `ash_typescript.codegen --check`, `npm run check`, `test`).
   `mix dialyzer` (dialyxir; PLT in `priv/plts/`, mix + ex_unit included) must stay at
   zero warnings — not part of precommit (minutes), run it before merging. Two habits it
   enforces: never `Process.sleep(n) && f()` (`:ok && …` is a guard that can never fail —
   write two lines), and no opaque `MapSet` inside a reduce accumulator (a plain map works).
   Never run two `mix test` at once: the SQLite test database answers "Database busy".

Where tests live / what to use:

- Ash resources & actions → `test/longx/…`, `use Longx.DataCase`; call code interfaces,
  assert on results and on `Ash.Error.*` for failures. See the `ash-framework` skill
  (`references/ash/testing.md`).
- Controllers / channels → `test/longx_web/…`, `use LongxWeb.ConnCase` /
  `LongxWeb.ChannelCase`; RPC actions at the wire in `test/longx_web/rpc/`.
- `Longx.Shim` → `test/longx/shim_test.exs` drives real OS processes (`cat`, `sh -c …`;
  the guard tests need `python3`); the Go side has its own `go test` suite in `native/shim`.
- `Longx.Git` → `test/longx/git_test.exs` runs the machine's git on temp repos (git is a
  dev prerequisite; the suite plays a remote with a bare repository). `Longx.Projects`
  thread / turn tests combine temp git repos with Bypass as the model.
- The kernel → `test/longx/agent/` with **Bypass as the model** and
  `Longx.Test.ResponsesFixture` building valid Responses SSE streams
  (`assistant_message/1`, `function_call/3`); a test gives its own `pipeline:` module.
  Every test that starts agents ends with `Longx.Test.Agents.stop_all!/0`. Test support
  lives in `test/support/` (`agents.ex`, `channel_case.ex`, `conn_case.ex`, `data_case.ex`,
  `fake_obscura.sh`, `responses_fixture.ex`, `tmp_dirs.ex`, `vite_manifest.json`).
- DB tests must clear the seeded rows in `setup` (seeds run before the suite).
- The browser → the unit suite runs `fake_obscura.sh`; `browser_integration_test.exs`
  (`:integration`) downloads the real binary. `:live` tests (real DeepSeek / Tavily) read
  `DEEPSEEK_API_KEY` / `TAVILY_API_KEY`. Both tags are excluded by default
  (`test_helper.exs`); `mix test --include integration`.
- **Look at it in a real browser** before calling a screen done: `node scripts/browse.mjs
  <url> phone|desktop out.png` (playwright, in `assets/`) loads the page as an iPhone 13 or a
  1280px desktop, prints console/page errors and any element wider than the viewport, and
  saves a screenshot to read back. Point it at the running dev server (never start a second
  one on 7798 if it is already up).
- TypeScript/React → also test-first: vitest + testing-library in `assets/` (`npm test`).
  Pure code in `js/core/` is unit-tested directly; pages render the real route tree with
  `renderAt(path)` from `ui/test-utils.tsx`, mocking `@/ash_rpc` (and `@/core/socket`) with
  `vi.mock` (shared factories in `ui/test-mocks.ts`); `setViewport(390)` for phone-width
  assertions.
- `mix test` runs `ash.setup --quiet` first; the test DB is `longx_test.db` (SQLite) —
  avoid `async: true` on DB-backed tests. Prefer `start_supervised!/1`; never `Process.sleep`
  in tests (monitor / `assert_receive` instead). A test that points a global directory
  (the knowledge's, the browser's) at a tmp dir of its own removes it with
  `Longx.Test.TmpDirs.rm_rf!/1` (retries).

## Dev server

- **Port 7798, bound to 0.0.0.0** — the dev box is reached over the LAN; production owns
  7788 on the same machine. This is set in `config/dev.exs` (`http: [ip: {0, 0, 0, 0},
  port: 7798]`); the `PORT` env var only applies to prod (`config/runtime.exs`). Never
  change it and never fall back to `localhost:4000`. Reach it at `http://<lan-ip>:7798`;
  Vite serves the scripts on 7799.
- The dev data lives in the repo: `longx_dev.db` at the root, `data/` (attachments, the
  global knowledge, the downloaded browser; gitignored).
- Start: `mix phx.server` (or `iex -S mix phx.server`). Run it in the background when you
  need the terminal; check first that the port is free: `ss -ltnp | grep ':7798'`.
- **Stop: only kill the process that owns port 7798.**

      fuser -k 7798/tcp            # or: kill $(lsof -ti tcp:7798)

  Other Elixir/BEAM apps run on this machine. **Never** use `pkill beam`, `pkill -f mix`,
  `pkill -f elixir`, `pkill -f phx.server`, `killall erl`/`beam.smp`, or anything else that
  matches by process name.
- Environment: WSL2 Linux, zsh. Test env binds `127.0.0.1:4002` with `server: false`.

## Conventions

- HTTP client: `Req` only (no httpoison/tesla/httpc).
- Ash: consult the `ash-framework` skill before touching domains/resources. Generate with
  `mix ash.gen.*`; migrations via `mix ash.codegen <name>` then `mix ash.migrate`;
  RPC exposure lives in `Longx.AshTypescriptManifest`.
- Phoenix: consult the `phoenix-framework` skill for the web layer. The UI is the React SPA;
  HEEx is only the shell/error pages — no LiveView screens.
- Assets: Vite owns bundling (`assets/vite.config.ts`, `@` → `assets/js`); never `@apply`;
  only Vite's output under `/assets` and the committed PWA files are served — no inline
  `<script>` in templates and no vendored `<script src>`; dependencies through
  `assets/package.json`.
- Paths, caches, devices: consider macOS and Windows too; derive candidates per platform
  through `Longx.Platform`, label Linux-only mechanisms.
- Docs: `mix usage_rules.docs Module.fun` and `mix usage_rules.search_docs "…" -p pkg`
  (see below) before guessing an API.

## Managed sections

Everything between `<!-- usage-rules-start -->` and `<!-- usage-rules-end -->` below, plus
`.claude/skills/ash-framework` and `.claude/skills/phoenix-framework`, is generated by
`mix usage_rules.sync` from the `usage_rules/0` config in `mix.exs`. Don't hand-edit it;
re-run the task after adding or upgrading deps.

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
