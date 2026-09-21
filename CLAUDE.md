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
    `trust_local_agent` (loads
    `.longx/agent.exs` + `.longx/shared/`, below), `agent_settings` (a map overriding the
    global kernel settings), `archived_at`. Whether it is a git repo is read live
    (`git_info/1`), never stored; `init_git/1` sets git up with a first commit. The UI warns
    when a project has no git. `delete_project/2` needs `confirm: true`: threads, turns,
    transcripts and attachments go first (`Changes.DeleteThreads` /
    `DeleteAttachments`), never the working directory. **Nothing waits on a process or the
    disk inside an Ash transaction** (`Repo.write_transactions?` is on, so a change's
    `before_action` / `after_action` runs holding SQLite's write lock): `DeleteThreads`
    stops the agents in `before_transaction` and deletes the rows in `before_action`,
    `DeleteAttachments` removes the files in `before_transaction`, `InitGit` runs git in
    `after_transaction` — a project delete once stopped its agents inside the transaction,
    each stop waiting on an agent that was itself waiting for that write lock, and every
    other writer saw "database is locked" (busy_timeout 16 s) for the whole of it (prod,
    2026-09-20).
  - `Thread` = kernel thread ↔ project (`kernel_thread_id`, `title`, `preview`, `cwd`,
    `model_slug`, `reasoning_effort`, `web_search`, `parent_thread_id` / `agent_path` for a
    sub-agent's row, `status`, `last_activity_at`). Statuses: `:idle`, `:active`,
    `:unrecoverable`, `:archived`. `start_thread/2` → `Longx.Agent.ensure/2` + the row +
    `Tracker.track`.
  - `Turn` = one turn (`kernel_turn_id`, `user_text`, `model_slug`, `reasoning_effort`,
    `status`, `started/completed_at`, `error`, `usage`). **Nothing of git on a turn and
    no commit by Longx, ever**: the per-turn bookmarks (`commit_before/after`), the
    dirty-tree policy with its `longx: before turn — …` commits and the restore points
    of 0.2.x went in 0.2.22 (a migration drops the columns) — they polluted every
    history they touched and bought nothing; the working tree is the person's, the Git
    tool window is where they commit. `send_message/3` writes the Turn row **first**
    with a generated `turn_<uuid>`, then `Longx.Agent.send/3`
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
    fills `status` / `completed_at` / `usage` from `turn/completed`, the
    thread `preview` from the first user message, gives a turn the kernel started by itself
    (a sub-agent's report waking an idle parent, another session's answer, a watch) a
    row via `record_external_turn/2` — named by who started it: `（定时触发）<name>` for
    a watch, `（agent 消息）` for an agent, `（目标续跑）<objective>` only for a turn
    nobody signed while a goal is set (every child's report once read 目标续跑 whenever
    the parent had a goal, and the person asked why the goal kept starting) —, turns a parent's first `subAgentActivity` into a Thread row
    under it (`parent_thread_id`, `agent_path` `/root/<name>`; hidden from the project's
    list, `list_subagents/1`), pushes the notify feed, and runs the **stall watchdog** (`running_threads/0` — the welcome page, the notify join — counts
    a root thread as running when one of its sub-agents is at work too, `working` naming
    them, and the directory says `running` for it): no
    event for `stall_after` (10 min; `config :longx, Longx.Projects.Tracker, stall_after:,
    tick:`) → interrupt, turn `:interrupted`; an interrupt answered `:not_running` (the
    row outlived its agent) settles the row `:failed` and the thread idle. **The agent
    process is monitored while a turn runs** (`turn/started` → `Process.monitor`,
    `turn/completed` → demonitor; `in_flight/0` lists those threads) — that monitor set
    is what the watchdog looks at (every thread ever hosted used to cost a row lookup
    and a turn query per tick once quiet for ten minutes) plus, in one query, the
    `in_progress` rows older than `stall_after` that no monitor covers (orphans: a
    crash nobody saw); a `:DOWN` that is no graceful exit with a turn row open fails
    the turn at once ("the agent died mid-turn: …", Sentry, the notify feed) and idles
    the thread — a crashed agent once left its thread `:active`, refusing every message
    ("a turn is running") until the next boot. **A (re)start recovers from the rows**
    (`handle_continue(:recover)`): every `in_progress` turn's thread is followed again,
    its agent monitored when it runs that turn (`Projects.agent_status/1`), the row
    settled when it does not. Its followed list is in memory: `host_thread/1`
    (a `ThreadChannel` join) and `send_message/3` both `Tracker.track/1` (idempotent), and
    `Projects.settle_after_restart/0` (a boot `Task`) fails every `:in_progress` turn and
    idles every `:active` thread a previous boot left.
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
  - `Longx.Agent` — one **`:gen_statem`** per thread (`Longx.Agent.Registry`, under
    `Longx.Agent.Supervisor`, `restart: :temporary`; states `:loading` — `init` does
    nothing slow (the DynamicSupervisor runs every start through it one after the other,
    and a big transcript read there held up every other agent's start); the transcript
    read, the view's replay and the team's restore are the state's first event, every
    other event postponed by OTP meanwhile, and `ensure/1` waits for a `:loaded?` call
    so its caller (not the supervisor) blocks until the view is there —, `:idle` /
    `:running` read off the kernel's finer `phase`, `handle_event_function` + `state_enter`; the handlers keep
    their GenServer shapes as `on_call/on_cast/on_info/on_step` behind one translating
    `handle_event/4`; the idle exit is the `:idle` state's `state_timeout`; a message sent
    with `deliver: :idle` while a turn runs is **postponed by OTP in the mailbox** and
    handed back the moment the agent is idle — no queue of our own; `GenServer.call` /
    `:gen_statem.call` speak the same protocol, `call/3` in the module caps the wait at
    5 s), **the loop as OTP recursion**: a step
    runs the pipeline at `:request` (pure: prompt, tools, the request), the model streams
    from a task (`Longx.Agent.Model.run/3`; `Model.prepare/1` — target, gateway shaping, a
    DB read — runs in the kernel process so a killed task never leaves SQLite mid-query) as
    `{:model, ref, event}` messages, the pipeline runs at `:response` (the model's calls
    known, none run yet), tool calls run as tasks under `Longx.Agent.TaskSupervisor` and
    answer as messages, `handle_continue(:step)` recurses until the model answers without a
    call, then the pipeline runs at `:turn_end`. **Never a blocking receive or a
    synchronous model call in a callback**: the mailbox is how steer, interrupt and
    `/compact` get in. `send/3` (`turn_id:`, `model:`, `effort:`, `images:`, `from:`,
    `reply_to:` / `reply_as:` / `hops:`, `deliver: :now | :idle`)
    starts a turn when idle and is a *steer* while one runs (into the context at the next
    step after the tool outputs, and shown then; a step is added when the model had already
    stopped) — or, with `deliver: :idle`, waits in the mailbox for the turn to end and
    starts one of its own (answers `:ok`); `interrupt/1` kills the tasks (a command's shim tree dies with its task) and
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
    `forget_child/2` (the `close_agent` tool, which also stops it, deletes its spec and
    **archives its row** — `Projects.archive_agent_row/1`; `list_subagents` skips
    archived rows, so a restart's rebuild leaves a closed child out: a closed
    researcher once came back beside the new one and the two names made the tools'
    enum an invalid schema, every `close_agent` failing from then on — the enums are
    `Enum.uniq`'d too) removes one. `max_children` counts working members. The team survives the parent
    leaving idle: `init` rebuilds it from `Specs.children_of/1` (specs carry `parent:`,
    `task:`, `spawned_at:`), and after a BEAM restart `Projects.ensure_agent` registers
    the children's specs from their rows (`register_team_specs/1`, any thread's — a
    child's own children too) before starting the
    parent, so `host_thread/1` lists the team again and a follow-up revives a child from
    its row. Siblings — the parent's other children, read from `Specs`, never a call to
    the parent (it may be calling this agent) — are `step.assigns.siblings`; a child may
    `send_message` one and gets its answer itself. A child monitors its parent but goes
    on when it leaves idle or crashes (the child's report brings it back from its spec);
    it stops with the parent only when the parent's spec is gone for good (`Agent.stop`
    stops the children first anyway). **A child inherits the session's model and
    level**: `Team.spawn_child` passes `inherited_model:` / `inherited_effort:` (what
    the parent runs on, or what it inherited itself), the child's row keeps them as
    `model_slug` / `reasoning_effort` (for a sub-agent row `agent_opts` gives them back
    as the inheritance, not a choice), and the loader puts them under everything
    (`inherited:` → the first `Config`): a spawn option, the role's own `model`, the
    settings' `child_model` all outrank it; the level goes with the model that stands
    (`model_and_effort/1` — an inherited `xhigh` never rides under another model).
    **Depth guard**: a spawn past `max_depth`
    (settings; `config :longx, Longx.Agent, max_depth:` 2) answers `{:error, :too_deep}` —
    a strategy plug inherited by every child recursed for ever without it. How a child is
    made is the `spawner:` function the agent was `ensure`d with
    (`Longx.Projects.spawn_native_agent/4`: a Thread row under the parent, the task as its
    first Turn row). `step.assigns` carries `parent`, `name`, `children`, `siblings`;
    **`step.state`** (`Step.put_state/3`) is a map kept across the phases and steps of
    one turn. `Plugs.Agents` speaks codex's multi-agent words (`models.json`
    `multi_agent.role.root` / `.subagent` for the prompt and `Team.team_instructions`,
    `core/src/tools/handlers/multi_agents_spec.rs` for the tools — `spawn_agent`,
    `send_message` as codex's `followup_task` + `send_input` in one, `close_agent`
    answering the previous status) adapted to roles, the mailbox and reports as
    `[agent <name>]` messages; **a child is told its canonical path** the way codex names
    agents (`your identity is \`/root/coder-3\`: the agent above you in that path
    (\`/root\`) is your parent`, the final message "delivered back to your parent agent"
    as codex says, a sibling listed `at \`/root/coder\`` — the specs carry `path:`) — a
    coder-3 told only its name once took the sibling `coder` for the main agent, sent it
    its report, and the two argued over the task's scope turn after turn; it offers `spawn_agent` / `send_message` (every member and
    sibling) / `close_agent` (own members) over the **declared roles**
    (`.longx/shared/agents/<name>/agent.exs`, `local/agents/<name>/`); the prompt lists
    the team with status, role and task and says to ask a finished agent again rather
    than spawn anew; **a task cannot override a role's rules**: the child is told its
    role's instructions take precedence over the task (leave the forbidden part out,
    report which rule it hit), the parent that a task changing method must fit the
    role's prompt or the rule must change first (a parent asked coder for three fee
    tiers and a loop its own prompt.md forbade — the coder followed the task and the
    machine went down); with no role declared the spawn tool is absent and the prompt
    teaches the model to declare one (`local/agents/<name>/agent.exs` + `prompt.md`) —
    **Longx ships no roles**: they grow in the project and are promoted to `shared/`.
    Prefix stability is what makes a follow-up cheap: nothing in the request varies per
    step but the transcript itself (Environment's date changes daily, the knowledge
    index and the model list only when they do).
  - **The directory: every session has an address** (`docs/agent-directory-design.md`).
    A `Thread` may carry a `handle` (a slug, unique per project — `HandleFormat`; the
    person sets it in the Agents tool window, the agent claims one with `claim_handle`,
    a watch's own session is `watch-<name>`); `Projects.agent_name/1` is how a session
    is called: the handle, else the team name, else `~` + the last six characters of
    its id. `Projects.directory/2` (RPC `directory`) lists the project's root sessions
    with `address`, `state` (`running` / `waiting` / `idle` / `asleep`, read off ETS and
    the registry only — it is built inside agent processes for the prompt, so never a
    call to one), `goal`, `team`; `scope: :all` crosses projects (`<slug>:<handle>`).
    `Projects.resolve_address/2` and **`Projects.deliver/4`** put a message in another
    session's mailbox by address (the target woken from its spec or row, tracked;
    `from_thread:` signs it with the sender's name and routes the answer back with
    `reply_to:` and `reply_as:` — `Team.report_to_parent` signs a root session's answer
    with the address the asker used; `hops` cap an exchange at six bounces; `:self` and
    archived targets refused). `Projects.session_named/3` finds or starts a session by
    handle. **On duty**: only a session on duty may be woken by another agent or a
    watch — `Thread.on_duty` (the switch beside every row of the Agents window's
    directory, RPC `set_thread_on_duty`), a handle (the person or the agent named it
    to be found; a watch's session too) or an active goal (`Projects.on_duty?/1`,
    `on_duty` on every directory row); `deliver/4` answers `{:error, :off_duty}` for
    the rest — a plain conversation the person had and left is not a colleague (an
    agent once read the directory, saw the person's last chat and woke it to ask
    about uncommitted files it had found; the person had been done with that
    session). A reply goes back to the asker regardless (it is not a call).
    `Plugs.Agents` names this session in the prompt (`# Sessions in this
    project`, the sessions **on duty** with handles / titles / goals only — live state
    would break the cached prefix — and the rule that a conversation is not woken),
    offers `agents_directory` (every session, live state, `on duty` / `conversation`),
    `send_message(to, message, deliver)` for a team name *or* an address (an
    off-duty target is refused with the reason), and `claim_handle` on a root session.
    The `turn/started` event carries `from` when an agent or a watch started the turn
    (the Tracker names the row `（定时触发）<name>` / `（agent 消息）`; the list's
    preview drops the `[agent …] ` prefix).
  - **Effects are what a plug asks the kernel to do**, data on the step interpreted after
    each phase: `Step.enqueue_call/3` (`:response`; a synthetic `function_call` with a
    `longx_` id, run with the model's), `Step.continue/2` (`:turn_end`; another step with
    that text instead of ending), `Step.compact/2` (`:request`), `Step.halt/2` (end the
    turn `failed`), `Step.spawn/4`, `Step.goal/2`. `step.usage` (`last` / `total`) and
    `step.context_window` let a plug judge the context; `step.calls` are the model's calls
    at `:response`; `Step.instructions/2`, `Step.tool/2`, `Step.raw_tool/2` build the
    request.
  - **What a turn runs on is told**: `Longx.AI.in_force(name, effort)` resolves the tier /
    alias / slug asked for to the concrete slug and the level in force (the model's
    default level when none was asked); the kernel puts it on the step
    (`assigns.model_in_force`) — `Plugs.Environment` adds "Model: you are running on
    model `x` (asked for as `plus`) at reasoning effort `low`" so the agent can say so
    instead of guessing — and emits `turn/model` `%{"turnId", "model", "name",
    "effort"}` at the first request and on every change (a chain fallback,
    `model/rerouted`, now names slugs); the Store merges it onto the turn
    (`put_turn` merges partials), the client too, and the badge's popover shows 模型 /
    档位, a sub-agent's row its child's `slug · level`.
  - **Events keep codex's vocabulary** (`turn/started`, `item/started`,
    `item/agentMessage/delta`, `item/reasoning/summaryTextDelta`,
    `item/commandExecution/outputDelta`, `item/completed`, `thread/tokenUsage/updated`,
    `turn/completed` — **the turn carries `startedAt` / `completedAt` (epoch seconds) and
    its own `usage`** (the turn's token totals; the Store keeps every turn under `turns`,
    the Tracker writes the usage onto the `Turn` row (`usage` map column), and
    `Projects.host_thread/1` seeds the store's turns from the rows through
    `ThreadState.seed_turns/2` — a restart rebuilds only the items from the transcript —
    so the client's `timingFor`, reading the message's own turn, gives every assistant
    message a badge with the duration and the tokens and a popover with 输入 / 缓存命中 /
    输出 / 思考, restarts included) —, `thread/goal/updated`, a `contextCompaction` marker,
    `longx/action/request` for an ask), fed to `Longx.Agent.ThreadState.ingest/3`. A
    tool's `show` decides the item: `:command` → `commandExecution`, `:file_change` →
    `fileChange` (a unified `diff` per change), `:tool` → `dynamicToolCall`,
    `:web_search` → `webSearch`.
  - **The tool set is codex's by name and parameters** — models tuned for codex call them
    as they know them: `exec_command` (`Plugs.Shell`: `cmd`, `workdir`, `tty` (a pty through
    the shim), `timeout_ms` (default 2 min — `options Shell, timeout_ms:` sets a
    description's default —, max 30 min; the command runs to completion —
    `write_stdin` sessions are not offered), `max_output_tokens`, `shell`, `login`;
    the result in codex's `format_exec_output_for_model` shape — `Exit code:` / `Wall
    time:` / `Total output lines:` when clipped / `Output:` then stdout+stderr
    interleaved, head+tail kept around `…N tokens truncated…`, a timeout as "command
    timed out after N milliseconds" with exit code 124, a kill with 137 (`{:error, text,
    extra}`; `Calls` takes the 3-tuple, the page appends `extra["reason"]` to what
    streamed); `Longx.Agent.Tools.ShellEnv` builds the environment). **The machine is guarded** (the settings'
    `command_oom_priority` 800 / `command_memory_percent` 90 / `memory_floor_percent`
    8, per project too; the loader's settings layer hands them to the plug as
    `options Shell, oom_score_adj:/memory_percent:/memory_floor_percent:` and the tool
    is mounted as a closure carrying them, its description telling the model the
    limits): the tree's `oom_score_adj` so the kernel kills the agent's command first,
    `RLIMIT_AS` at that share of RAM (`Longx.System.Memory.total/0`; allocations past
    it fail inside the command — Linux; Windows through the Job), and the command
    registers with **`Longx.System.Pressure`** (a watchdog in the tree, every 2 s while
    a command runs, `Pressure.Registry` duplicate keys under `:running`): free memory
    (`MemAvailable`, `vm_stat` on macOS) under the floor → `{:memory_pressure, …}` to
    the tool task, the shim tree killed, the model told "killed by Longx: the machine
    was down to 3% free memory…", a `:memory` fault recorded. The same registry is
    **the ledger of live commands** (`Longx.System.Commands`: each entry has an `id`,
    the command, its thread, `started_at`, and the shim + OS pid once started —
    `Pressure.update/1` replaces the caller's entry); `list/0` names each command's
    session (the root conversation, the sub-agent beside it), `kill/1` sends the tool
    task `{:kill_command, :person}` → the whole tree dies and the model reads "killed
    from the settings page by the person…"; RPC `running_commands` / `kill_command`;
    Settings → 进程 (`ProcessesSection`, `core/commands.ts`, refreshed every 2 s, 结束
    behind a confirm) — the GUI for a hung backtest. Why: a jbt GPU backtest
    on the Spark took ~100 GB the NVIDIA driver carved out of RAM — no process's RSS,
    invisible to RLIMIT and cgroups — and the kernel's OOM killer took Firefox instead;
    a shell loop of 24 backtests then started the next one. Tests:
    `test/longx/system/{memory,pressure}_test`, the Shell guards in `plugs_test`),
    `apply_patch` (`Plugs.Patch` over
    `Longx.Agent.Tools.Patch`: codex's patch grammar parsed and applied in Elixir — all
    hunks matched first, then written; **a miss says where the block stops matching** —
    the context and deleted lines are one block matched line by line, and an error naming
    only the first line sent an agent chasing encodings when a blank line was missing from
    its context, so `explain_miss/3` reports the matched prefix, the diverging line on both
    sides and the nearest line when the first is absent; `Plugs.Patch.normalize/1` is the
    tool's `prepare:` (the patch under `patch` / `text` / `content` / `diff`, newlines
    escaped as literal `\n` with no real newline, a markdown fence around it);
    `priv/agent/apply_patch.md` gained the line-by-line rule; for a provider of `kind: :openai` the same tool as a
    grammar-constrained `custom` tool from `priv/agent/apply_patch.lark`; instructions from
    `priv/agent/apply_patch.md`), `view_image` (an `input_image` user message after the
    result). There is no `read_file` / `list_dir` / `grep_files`: reading is `exec_command`
    (`cat`, `sed -n`, `rg`).
  - **Every prompt starts from codex's own text** (`openai/codex`, `codex-rs/`) and changes
    only what Longx does differently, with the source file named in a comment — a
    prompt of our own once let a coordinator infer a goal from "have the researcher
    and coder look into it". **The base prompt is codex's gpt-5.6
    `instructions_template`** (`models-manager/models.json`; `Plugs.Base` reads
    `priv/agent/base_prompt.md` at compile time; the template is kept as
    `test/support/fixtures/codex_gpt56_instructions.md` and `plugs_test` lists every
    paragraph that differs — the identity (Longx, no model named), Harmony's channels
    said in plain words, file references as paths not links, no `$CODEX_HOME`, the
    skills section out, "# Where you work" and a commands-run-to-completion line in).
    `Plugs.Environment` is codex's `<environment_context>` block (`cwd`, `shell`,
    `current_date`) plus our `operating_system` and `model` elements; `Plugs.Prompt` the
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
    `ThreadState.backfill`; a retract is a truncation. **One writer, an event log**:
    an agent never writes its transcript itself — `append!/1` is a cast to
    `Longx.Agent.Transcript.Writer` (in the tree), which writes whatever accumulated in
    one transaction (`Ash.bulk_create`, `transaction: :all`), then the next batch, one
    thread's items in order; `items!` / `truncate!` / `delete!` flush first
    (`Transcript.flush/0`, a call answered after everything queued), so nothing reads
    around a pending item; a batch the lock refuses is retried through `waits:`
    (200 ms → 2 s, synchronously for a flush call, by timer otherwise) and then
    dropped with a `:db` fault, an error that is no lock dropped at once — never a
    raise into an agent (a team of agents each writing as they went ran past SQLite's
    `busy_timeout` and the raise ended an agent mid-turn — Sentry LONX-5). Tests:
    `Longx.DataCase` flushes the writer on exit before the sandbox owner stops, and
    `Longx.Test.Agents.stop_all!/0` after the Tracker.
  - **Descriptions: `Longx.Agent.Config`** (the DSL: `version` / `extends` / `model` /
    `prompt` / `prompt_file` / `summary` / `agents` / `plug` / `options` / `drop` /
    `pipeline`), data evaluated before anything runs, the same format in every layer.
    `import Longx.Agent.Config; agent do version 1; extends :default; model "pro", effort:
    "high"; prompt "…"; plug Deploy, after: Shell; options Shell, timeout_ms: …; drop Patch
    end` — a description records the **difference** to the layer below (`Config.resolve/2`
    applies the ops; a short name means the shipped plug, `Config.builtin/1`), so a release
    that changes the shipped pipeline (`Longx.Agent.Pipelines.Default.config/0`:
    Environment, Base, Shell, Patch, ViewImage, Present, Knowledge, WebSearch, Browser,
    Credentials, Agents, Watches, Goal, Compaction, Request; a description's `prompt`
    becomes a `Plugs.Prompt` after them —
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
    `child_effort`, `model_retries` 3, the command guards `command_oom_priority` 800 /
    `command_memory_percent` 90 / `memory_floor_percent` 8 — global in
    `Longx.System.Setting`, overridden per project by `Project.agent_settings`). **No global code layer**: no global agents, plugs
    or skills; the only thing shared across projects is the global knowledge. A layer is
    `agent.exs` + `plugs/**/*.exs` + `agents/<name>/agent.exs`; every `defmodule` of a layer
    and every reference to it is renamed under `Longx.Agent.Local.<tag>` before
    `Code.compile_quoted`, so two projects may both define `Deploy`; cached per layer by the
    files' mtimes and sizes (`Loader.Cache`; `Loader.stamps/1` leaves out a file gone
    since the listing — a once watch its run consumed, a plug the agent removed — where
    a `File.stat!` once ended an agent mid-turn), recompiled on change; a file that fails to
    load leaves the layer below in force and becomes a **notice** in front of the model
    (`⚠ … failed to load …`), as does an outdated version, a plug nobody defines, and a
    description naming a model Longx does not have (the default runs instead —
    `description_model/3`). **`Definition.Lint`** reads every plug file of a layer and turns a
    plug that does secrets by hand (listens on a port for an OAuth redirect, keeps tokens
    in a file, reads `*KEY*` from the environment) into a notice pointing at
    `Longx.Credentials` — the plug still runs; the Local and Knowledge prompts say the
    shipped guidance takes precedence over a local doc or tool that contradicts it (an
    agent once wrote a loopback-OAuth plug plus a doc calling it the only way, and every
    later session followed the doc). `Layout.promote/2` (`Projects.promote_local/2`, RPC
    `promote_local`) moves a local file into `shared/`. `Projects.agent_definition/1` (RPC
    `agent_definition`) lists the files, the resolved plugs, the notices and the
    description's model (`definitionModel`, what the composer shows). `Longx.Agent` loads
    per step when no `pipeline:` module is given (tests give one).
  - **Knowledge instead of memory — `Plugs.Knowledge` over `Longx.Agent.Knowledge`** (the
    prompt is codex's memory decision boundary — `ext/memories/templates/memories/
    read_path.md`: skip only a self-contained request, a quick `knowledge_search` when
    unsure — and its skills trigger rules — read a matching doc whole before acting,
    not carried across turns, "not proof of current behavior"; the writing rules are
    ours):
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
    transport errors — and **a stream that breaks, ends without a completion or goes
    silent past the provider's `request_timeout_ms`** — are retried on the same model
    (`retry_ms:` `[5_000, 15_000, 30_000]`, `[10, 10]` in tests; how many times is the
    settings' `model_retries`, 3, global or per project, through `Model.prepare(request,
    retries:)`; a retry of a stream that had begun tells the kernel `{:restart, why}` —
    it closes what came in the view, gives none of it to the model, and shows a
    `turn/progress` of kind `retry`), then the chain's next model, and when the chain is
    spent the failure is `{:failed, {:model_failed, slug, message}}`: the turn ends
    `failed` with `error: %{"message", "code" => "model_failed", "model" => slug}` and
    the page offers another model (`ModelFailedBanner`: a pick, 换个模型继续 sends 继续 on
    it and keeps it for later turns). A provider's own failure event mid-stream
    (`response.failed`, `error`) is retried the same way when it is passing — by type
    (`server_error`, `overloaded`, rate limits…) or by its words ("retry", "try again",
    "temporar", "unavailable"…; `transient?/1`) — and final otherwise. A 4xx is final. **A call's arguments streaming in
    are progress**: `response.function_call_arguments.delta` /
    `custom_tool_call_input.delta` → `{:arguments_delta, id, delta}` → `turn/progress`
    `%{"progress" => %{"kind" => "toolCall", "name", "bytes"} | nil}` (the first bytes at
    once, then once a second; nil when the call is whole), kept as `progress` in the
    Store's meta and the client view — the turn bar says 正在写 apply_patch 的参数（13 KB）,
    a sub-agent's row the same for its child (`SubagentContext`, with 停止 to interrupt
    the child from the parent's page), and the Tracker's stall watchdog counts it as
    progress: a researcher writing a long note streamed argument bytes for twenty
    minutes with nothing on the thread, and `follow/2` no longer resets a followed
    thread's clock when a page joins it (every join had restarted the ten minutes). The
    task monitors its owner and dies with it. `Longx.Agent.Model.SSE` parses the stream into `{:item_added | :text_delta |
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
    the `public_url` setting, else `LONGX_PUBLIC_URL` (a container's compose file), else the address the last browser connected from
    (`LongxWeb.Origins.last/0`, from the socket's `connect_info: [:uri]`), else
    `Endpoint.url()` — never a port opened on the server for a browser elsewhere.
  - **Cards — `Plugs.Present`** (in the shipped pipeline after ViewImage): `present`
    draws a generative UI tree from assistant-ui's component vocabulary
    (`@assistant-ui/react-generative-ui`: Card, Row, Col, Fact, Table, Chart, Markdown,
    Alert, Badge, ListView, Image, Button, Select, Input, Form, … — `$type` + props +
    `children`), `prompt_user` draws one and waits for what the person fires in it. **The
    schema is generated, never written**: `assets/scripts/present-schema.mjs` →
    `priv/agent/present.json` (`npm run present-schema`; precommit runs `--check`) from
    the same library the client renders with, so the model can only name what the page
    draws; `Tool.declare` / the `tool` macro take `schema:` for it. The item the person
    sees is the call itself (`dynamicToolCall`, namespace `longx`, `arguments` = the
    tree; toolkit `longx.present` → `PresentTool` over `elements/generative-ui.tsx`'s
    `GenerativeTree` — the registry's styled library with fenced code through shiki;
    styles in `css/generative-ui.css`, the registry's `generative-ui-style` item on our
    tokens); the model reads only "shown to the user". `prompt_user` is an ask with
    `spec:` (`Context.ask(ctx, spec: tree)` → `longx/action/request` carries `spec`;
    `ActionTool` draws the tree with a `dispatch` whose action — `$action` plus
    `$input` or the form's values — answers as `%{"action" => payload}`; the tool returns
    it as JSON, a cancel as "dismissed"). **A plug pushes a card without the model**:
    **`Present.normalize/1`** is the tools' `prepare:` (a `Tool` option applied by
    `Tool.call/3` and by `Calls.arguments_of/2`, so the UI item sees it too): nested arrays
    a model sent as JSON strings under the structural keys (`children`, `rows`, `columns`,
    `options`, …) are decoded and a tree handed over under one key (`spec`) unwrapped —
    百炼 and DeepSeek slip like that, and a card once showed its children as raw text; a
    component's words under a prop the vocabulary does not read (`Alert.text`,
    `Text.text`, `Header.value` …) are moved to the one it reads — an Alert once drew as an
    empty pill.
    `Context.present(ctx, tree)` (→ `Agent.present/2`, a cast; `Kernel.Calls.present/2`
    appends a completed `longx.present` item as an `:activity` row, `context?: false`,
    never model input) or `"present" => tree` in the result's meta. Tests:
    `plugs_test` (schema, namespace, refusals), `agent_test` (present / prompt_user /
    Context.present end to end), `toolkit.test` (the tree, the spec form's dispatch). **Surfaces** (the same plug): `show_file(path, line)` / `show_diff(path,
    sha)` open a workbench tab, `send_file(path, title)` a download card
    (`GET /files/:project_id/*path` — `LongxWeb.FileController`, the path
    resolved inside the root like `Workspace`, `_attachments/<name>` for an
    upload, `?inline=1` for an image drawn in the chat; no auth, the single-user
    boundary of the RPC), `show_html(title, html | url)` an artifact — the
    workbench tab kind `artifact` (`core/workbench.ts`, plain data so a native
    client can open it in a window; not remembered on the device — the row
    reopens it) drawn as an iframe with `sandbox="allow-scripts allow-forms"`,
    never same-origin, a full-screen sheet on a phone. Every tool checks the
    path stays inside the project and puts what the client needs on the item
    as `details` (`UI.completed_ui` merges the result's `"details"`;
    `messages.ts` passes it in the part's result). **A surface opens only when
    its item arrives live**: `useThreadView` signals `item/completed` of a
    `longx` surface tool (`isSurfaceEvent`), `ChatProvider` opens the tab;
    a snapshot never signals, so a reload leaves the workbench alone and the
    row's 打开 reopens. Renderers `ShowFileTool` / `ShowDiffTool` /
    `SendFileTool` / `ShowHtmlTool` read `SurfaceContext` (the project's
    workbench) and degrade to a plain row without it.
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
  - **Image generation is the provider's hosted tool, per model** — `Model.image_generation`
    (default false; the `openai` and `chatgpt` presets set it on their models; the model
    dialog's 图片生成 switch, "only OpenAI's Responses API"): `Target.image_generation?`
    makes `Gateway.prepare` append `{"type": "image_generation"}` to the tools (once; a
    stray one is dropped for every other target, a replayed `image_generation_call`
    item too — `@hosted_call_items`). No plug, no per-thread switch: the model draws
    when asked. The stream folds `image_generation_call` (`Kernel.Stream`): in progress
    → a `longx.image_generation` `dynamicToolCall` row (`UI.image_generation_ui`); done →
    the base64 saved with `Attachments.store_bytes/3` as `<stamp>-image-<thread>-<n>.png`
    under the project's attachment dir, the row completed with `send_file`-shaped
    `details` (`path`, `mime`, `attachment: true`, the `revised_prompt` as `title`) so
    `ImageGenerationTool` draws it inline through `/files/<project>/_attachments/…?inline=1`
    (a `FileCard` shared with `SendFileTool`), and **the model's context gets a note**
    (`[image_generation] The image … was saved as the attachment <name> …`, a user
    message, kind `:hosted_call`) instead of the bytes — with `store: false` every step
    replays the history and one picture is a megabyte. `agent_test` "hosted image
    generation" folds a fixture stream; the real thing was checked once through the
    subscription (a 877 KB png back for a red circle).
  - **Compaction, codex's shape** (`Plugs.Compaction` policy; `Kernel.Compaction`
    execution): the kernel folds on its own when the person types `/compact`
    (`Agent.compact/1`: at once when idle, before the next step when running) and when the
    provider refused the request for its length (`assigns.context_overflow`, `:request`
    re-run once); the plug — in the shipped pipeline since 2026-09-18; a project may
    `drop` it or set `options Compaction, at: …` — asks (`Step.compact/2`) when the
    context passed `at:` (0.9) of the window or the model called `new_context_window`,
    and offers `get_context_remaining`.
    **The fold is shown while it runs**: `Compaction.start_compaction` emits
    `turn/progress` of kind `compaction` (`name` the model, `bytes` of the summary so
    far — the first delta at once, then once a second, `note_delta/2`; `turnId` nil
    between turns) and `nil` when it is folded or failed; the client's `TurnState` gains
    `compacting` (a fold with no turn running) and the turn bar says 正在压缩上下文（摘要
    N KB） — a `/compact` once showed nothing for a minute and then the marker.
    The kernel streams a summary from a
    task (`priv/agent/compact/prompt.md`, no tools), appends a `:compaction` item
    (`summary_prefix.md` + the summary as a user message), emits the `contextCompaction`
    marker, reloads the context and continues the step. A failed summary: the step goes on
    without folding, or fails the turn when the provider had refused the length.
  - **Watches — scripts Oban runs, sessions' mailboxes as the outlet** (`Longx.Watches`,
    `Longx.Agent.Watch`, `docs/watches-design.md`). A watch is a file
    `.longx/local/watches/<name>.exs` (or `shared/watches/`, behind the trust switch):
    a module `use Longx.Agent.Watch` whose head is data (`every` cron in the machine's
    local time / `once` instant / `webhook true`; `expires`, `max_runs`, `timeout` 30 s,
    `budget` 6 sends per hour) and whose `run/1` does the rest with the imported helpers
    (`shell/3` bash in the project root as the person, `http/3`, `credential_request/4`,
    `knowledge_read/2`, `log/2`, **`send/4`** to an address or `:self` — the session
    `watch-<name>`, started when there is none), answering `{:ok, state}` (the next
    run's `ctx.state`) or `{:error, why}`; `Watch.definition/1` reads the head,
    `Watch.run/2` runs it in the calling process (a collector Agent records sends and
    log; `deliver: :dry` for a dry run). **No policy in the runtime**: what changed,
    whom to tell, is the script's `if`. The definition loader compiles `watches/` with
    the plugs (`loaded.watches`; a bad head is an error naming the file → a notice);
    `Longx.Watches.Watch` rows (table `watches`, unique per project and name) are the
    state — `Watches.reconcile_project/1` upserts / resyncs / drops rows from the files
    (a broken file: `disabled_reason: :load_error`), `run/2` (in
    `Longx.Watches.TaskSupervisor`, the script's timeout, `running_since` while it
    runs, the sends through `Projects.deliver/4` with `deliver: :idle` and the hour's
    budget — over it the row is off and the person told —, then `state` / `last_*` /
    counts / `next_due_at`; a `once` consumed with its file; expiry) and `dry_run/1`,
    `set_switch/2`, `delete/1` (file then row), `overview/0`, `settle_after_restart/0`
    (a boot clears `running_since`). The clock is plain Oban like the credential
    refresh: `Longx.Watches.Tick` every minute (reconcile every active project, queue a
    `Watches.Runner` per due row, unique per watch), queue `watches`; `POST
    /hooks/:token` (`LongxWeb.HooksController`, the body as `ctx.payload`) queues a
    webhook watch's run. `Plugs.Watches` (shipped, inside a project): `watch_list`,
    `watch_run` (dry), `watch_enable`, `wait_until` (writes a once / cron watch that
    sends the message back to this session — the loop's "sleep"), `notify`; the
    prompt teaches the file and says never to sleep in a turn; the knowledge
    `longx/writing-watches.md`. `Longx.Notify` kind `watch` (`Projects.notify_project/3`
    points at the project page); the project channel pushes `"watches"` on any change.
    UI: Settings → 监控与定时 (`WatchesSection`, every project's watches, running first,
    RPC `list_all_watches`), the project settings card (`ProjectWatches`: state, last
    output, 试跑 dialog, switch, delete, 提升到 shared for a local one through
    `promote_local`, and a hint naming the `shared/watches/` files an untrusted project
    keeps off — RPC `list_watches` / `switch_watch` /
    `dry_run_watch` / `delete_watch`), the Agents tool window's session directory
    (`SessionDirectory`: addresses, states, the 值班 switch on every row — on and
    disabled for a handle or an active goal —, the handle field — RPC `directory`,
    `set_thread_handle`, `set_thread_on_duty`). Tests: `test/longx/agent/watch_test`,
    `test/longx/watches/{watches,plug}_test`, `hooks_controller_test`,
    `watches_rpc_test`, the loader's watches test.
  - **Goal mode** (`Plugs.Goal`, `Kernel.Goal`): `create_goal` / `update_goal` / `get_goal`;
    **the words are codex's** (`codex-rs/ext/goal`: the rules sit on the tools, nothing
    in the system prompt — `create_goal` "only when explicitly requested by the user or
    system/developer instructions; do not infer goals from ordinary tasks", `token_budget`
    "omit unless explicitly requested", `update_goal` for `complete` / `blocked` /
    `paused` only (a resume is the person's; `paused` at their explicit request;
    `blocked` after the same blocker three goal turns running) plus our `reason` shown
    beside 卡住了; the tools answer codex's JSON `{goal, remainingTokens,
    completionBudgetReport}`, a second `create_goal` on an unfinished goal is refused;
    the continuation is codex's `templates/goals/continuation.md` vendored as
    `priv/agent/goal/continuation.md` with the objective escaped inside `<objective>`
    and the budget lines filled in, its `update_plan` paragraph left out as codex does
    without that tool — a coordinator once made a goal out of "have the researcher and
    coder look into it" under our own looser wording); with the goal `active` the
    `:turn_end` phase continues the turn with that step until the model marks it
    `complete` / `blocked`, the token budget is spent
    or `max_rounds:` (8) continuations happened (then `blocked`, never a loop) — **not
    while a child works**: its report starts the next turn by itself (a parent waiting
    on coder was continued eight times saying "waiting" and blocked). The continuation
    is `Step.continue(text, origin: %{"kind" => "goal", "round", "objective"})` →
    `{:continue, text, origin}` → the user item carries `"origin"`, and the page draws
    a marker 目标续跑 · 第 N 轮 (`GoalContinuationUI`, `data-goal` part; older items
    recognised by their text) instead of the person's bubble. A blocked goal carries
    `"reason"` (`rounds` / `budget` from the plug, the model's sentence through
    `update_goal`'s `reason`), shown beside 卡住了.
    `Agent.set_goal/2` (RPC `set_goal` / `clear_goal`, the `/goal` command, `GoalBar` —
    gone once the goal is `complete`; a blocked one stays with its reason until cleared)
    sets the same goal; `thread/goal/updated` is the view's `goal`.
  - **Bytes that are not UTF-8 never reach the view or the transcript** — `Longx.Agent.Text`
    (`utf8/1`, `deep/1`, U+FFFD per invalid sequence) at three doors: a shell chunk and the
    clipped result (`Plugs.Shell`; a clip can cut a character), every tool result in
    `Calls.finish_call` (the transcript is the model's JSON request), every item and delta
    the Store folds or backfills. A researcher once `cat`ed a parquet: Jason refused the
    snapshot inside the socket transport, the socket closed, the client rejoined — 146
    times in five seconds on every page showing that thread.
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
    `reasoning_summary`, `verbosity` — OpenAI's `text.verbosity` `low` / `medium` / `high`,
    nil sends nothing and every preset leaves it nil — the person picks it per model
    (codex sends `low` to gpt-5.x); DeepSeek and Qwen accept and ignore it (measured
    2026-09-21: 200, echoed, the length unchanged); the model dialog's 回答详略 —,
    `max_output_tokens`,
    `hosted_web_search`). `AI.check_effort/2`
    refuses a level the model does not declare; unknown slugs are refused in
    `Longx.Projects`. `resolve_target/1` (`longx` = the default model) = model + its
    provider's decrypted key.
  - **Presets** (`Longx.AI.Presets`, pure data + `apply/2`, idempotent): DeepSeek, GLM,
    阿里云百炼 Token Plan (个人版 / 团队版), OpenAI and **`chatgpt` — a ChatGPT
    subscription through the Codex backend** (`credential: true`: `apply/2` makes the
    OAuth2 credential `chatgpt` from `Presets.chatgpt_credential/0` — the Codex CLI's
    public client `app_EMoamEEZ73f0CkXaXp7hrann`, PKCE, `fixed_client`, `device_flow:
    :openai`, the vendor's `redirect_uri` `http://localhost:1455/auth/callback`,
    `authorize_params` `codex_cli_simplified_flow` / `originator` — and a provider
    `kind: :openai` on `https://chatgpt.com/backend-api/codex` with `credential_id`
    pointing at it; the RPC answers `credentialId` so the page opens the login next)
    with endpoint / kind / hosted search / key url / docs url and their models.
    **A provider on a credential** (`Provider.credential_id`): its key is the
    credential's access token (`Longx.Credentials.access_value/1`, refreshed when about
    to expire; no login = `{:missing_api_key, slug}`, so the model stays out of the
    chains), `has_api_key?` counts it; `target_for/1` marks the target `chatgpt?: true`
    with `account_id` read off the token's claim `https://api.openai.com/auth
    .chatgpt_account_id` (`AI.chatgpt_account_id/1`), and `Gateway.prepare` adds the
    backend's headers (`chatgpt-account-id`, `OpenAI-Beta: responses=experimental`,
    `originator: codex_cli_rs` — the backend serves only clients it knows) and
    `store: false` + `include: ["reasoning.encrypted_content"]`, and — **measured
    against the backend item by item, not guessed** — takes `status` and `content`
    off every replayed reasoning item (a reasoning `status` → 400 "Unknown parameter";
    a non-empty `content` → 400 "array too long … maximum length 0"; a summary alone
    is fine, so another provider's summary from a thread that ran there before stays,
    one left with neither summary nor ciphertext goes) while messages and calls keep
    their `status` / `phase` / `logprobs` (accepted). The public API's reference
    (developers.openai.com, Responses → input → reasoning) allows `content` and
    `status`, so api.openai.com is untouched. Checked with a real thread's mixed
    history (80 items: qwen / deepseek reasoning, uuids, statuses, calls) and a
    two-step tool call. **`prompt_cache_key`** (OpenAI caches the prefix per key; the
    Codex CLI sends its session id) is the thread id, sent when the provider's
    `prompt_cache_key` says so — nil follows the kind (OpenAI and the Codex backend on,
    compatible off; the provider dialog's prompt_cache_key select: 自动 / 发送 / 不发 — a
    compatible service that reads it is switched on there), `Target.prompt_cache_key?`;
    a key from elsewhere is dropped otherwise. A content-policy refusal ("Invalid
    prompt: your prompt was flagged as potentially violating our usage policy", relayed
    by a gateway as a 502) is **final** like a quota refusal — no retry of the same
    prompt; `Model.policy?/1`. The Codex backend also gets the Codex CLI's session
    headers `session-id` / `thread-id` (the thread): the backend routes a session to
    the shard holding its prompt cache — measured with identical requests: without
    them a repeat hit the cache every other time, with them every time after the
    first (a two-turn kernel test: turn 2 cached 24,064 of 24,653); `discover_models`
    reads the backend's catalog (`GET /models?client_version=` → `models[]` with
    `slug`, `context_window`, `supported_reasoning_levels`, `visibility` — hidden ones
    left out) with the same headers. **Any provider's own list**: `discover_models/1`
    asks `GET <base_url>/models` and normalises each entry (window, levels, default level,
    image input, `installed`). Over RPC via the data-less `Longx.AI.Preset` (`list_presets`,
    `apply_preset`) and `discover_models` on `Provider`. Seeds (`priv/repo/seeds.exs` →
    `Longx.AI.Seeds`, run by `mix ash.setup` / `mix test`, never by a release) apply the
    DeepSeek preset without a key (`deepseek-flash` the default) and the OpenAI provider
    alone — keys are entered in Settings, not read from the environment. A new NOT NULL
    column needs a `default:` in the migration (SQLite).
  - `Longx.AI.Aliases` (above): RPC `model_aliases` / `set_model_alias` /
    `delete_model_alias`; `model_choices/0` is what the agent is told (the default marked
    by its name). **The default model is a name** (`AI.default_model_name/0`: the
    `default_model` setting, `plus` unless saved — a tier by preference, an alias or a
    slug; `set_default_model/1` saves it, a slug also becoming the base row;
    `default_model_info/0` says what it resolves to now; RPC `default_model_setting` /
    `set_default_model`). The row flagged `default` (`make_default_model`) is the
    **base**: what an unmapped tier means and the fallback when the name no longer
    resolves, so a fresh install runs on its preset's model until the person maps
    `plus`. `resolve_targets(nil)` is the default name's whole chain; `in_force(nil, _)`
    names it (`turn/model` says `plus` → the slug). Settings → 模型与 Provider has the
    默认模型 card (`DefaultModelCard`: tiers with their labels, aliases, models, the
    resolution and the reason to prefer a tier); the composer rail shows a tier as
    `plus deepseek-flash high` (`useDefaultModel`).
  - `Longx.AI.Gateway.prepare/2` shapes a Responses request for its target: the
    placeholder `longx` swapped for the `upstream_id`, `stream: true`, `max_output_tokens`
    from the row, the row's `reasoning_summary` on the request's `reasoning` block (the
    kernel sends `auto`; `none` drops the key — only OpenAI's hidden-reasoning models read
    it, the model dialog says so), the hosted `web_search` tool kept only for a provider that searches.
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
- **Credentials — `lib/longx/credentials/`**, Ash domain `Longx.Credentials`: the API keys
  and OAuth2 tokens the agent's tools need, **never seen by the model**.
  `Longx.Credentials.Credential` (`credentials`): `name` (a slug, the placeholder the agent
  uses), `kind` `:api_key` | `:oauth2`, `header` / `scheme` (`authorization` / `Bearer`;
  `""` = the raw value), **`allowed_hosts` (required, non-empty — the boundary against
  exfiltration)**, the ciphertext columns `secret` / `access_token` / `refresh_token` /
  `client_secret` (AshCloak + `Longx.Vault`, `decrypt_by_default([])`, loaded only by
  `Credentials.reveal/1`), the OAuth2 client (`client_id`, `authorize_url`, `token_url`,
  `registration_url`, `scopes`, `pkce`, `extra_params`), `expires_at` / `refreshed_at` /
  `last_error`, and the calculated `status` (`ready` | `expired` | `needs_login` |
  `error`). **The one way a credential is used is `Credentials.request/4`**
  (`Credentials.Http`): the value injected into the row's header — or wherever
  `{{credential:NAME}}` stands in the URL, headers or body —, refused for a host outside
  `allowed_hosts`, redirects not followed, an access token within 60 s of expiry refreshed
  first, and the answer (status, headers, body) **scrubbed** of every secret value
  (`[redacted:NAME]`). `Credentials.OAuth`: `begin_login/2` (PKCE S256 + state kept in
  `Credentials.Logins`, ETS in the tree, 15 min; RFC 7591 `register/2` first when the row
  has a `registration_url` and no client id), `complete/2` (`GET
  /callback/credentials?code&state` — **the redirect URI is https or loopback, never a
  remote http address** (RFC 8252; COROS answers `invalid_redirect_uri: Remote
  redirect_uri must use https` to a LAN box's `http://192.168…`): `OAuth.redirect_uri/1`
  is the browser's origin (else `Longx.System.public_url/0`) + `/callback/credentials`
  when that is https, otherwise Longx's own `http://127.0.0.1:<endpoint port>` — a
  browser on the Longx machine lands on Longx, one elsewhere lands on an unreachable page
  and the person pastes its address back: `OAuth.complete_url/1`, RPC
  `credential_complete_url`, the settings card's paste box after 登录, the agent's login
  ask carrying a `redirect` field when `loopback?/1`; an https `public_url` behind a TLS
  proxy is the zero-paste setup. The ask of an agent's `credential_login` is answered by
  the callback through the request's `meta.login` state, so the person presses nothing
  when the browser did reach Longx), `refresh/1` (the refresh_token
  grant; a refresh token in the answer replaces the old one; an error lands on the row).
  **Oban** (`Oban.Engines.Lite` on `Longx.Repo`, `Oban.Notifiers.PG`, queue `credentials`,
  `Oban.Plugins.Cron` every 5 min, `Pruner`; `config :longx, Oban`; migration
  `add_oban.exs` from `Oban.Migration`; `testing: :manual` in tests with `Oban.Testing`):
  `Credentials.RefreshWorker` sweeps `Credentials.expiring/1` (10 min ahead, with a refresh
  token) into one unique job per credential. **The agent side — `Plugs.Credentials`** (in
  the shipped pipeline after Browser, namespace `longx`): `credentials_list` (names,
  kinds, statuses, hosts, expiry), `http_request(credential, url, method, headers, body,
  timeout_ms)` (through `request/4`; the body clipped head and tail; MCP servers over HTTP
  are JSON-RPC POSTs through it), `credential_login` (an ask with the authorize URL and
  `meta: %{"login" => state}`; **a public client Longx did not register** (a client id
  on the row, no secret, no `registration_url` — an agent once registered one by hand
  with a loopback redirect URI; COROS rejects that only after the IdP login, so no probe
  sees it) is replaced before the first login by one Longx registers at the
  `registration_endpoint` of the server's RFC 8414 metadata; a Longx-registered client the
  authorize URL refuses outright (a GET probe answering 400) is registered again; a
  confidential client is used as it is), `credential_create` / `credential_rotate` (`secret_from:` `env:NAME` / `file:PATH` / `file:PATH#KEY` copies a key already on the machine into the store without the model seeing it; else the key / client secret typed by the
  person into the ask's **`secret: true` field**, masked in the elicitation form, stored
  by the tool). RPC on the resource: `list_credentials`, `create_credential_api_key`,
  `create_credential_oauth2`, `update_credential`, `delete_credential`,
  `credential_login_url` (`id`, `origin`), `refresh_credential`, `credential_redirect_uri`,
  `credential_device_begin` / `credential_device_poll` (`test/longx_web/rpc/credentials_rpc_test`).
  **A credential may carry a vendor's own OAuth client**: `fixed_client` (the id is used
  as it is, never replaced by a registration), `redirect_uri` (the vendor's, in place of
  Longx's own — the browser ends on an unreachable page and the person pastes its
  address back), `authorize_params` (authorize-only query params; `extra_params` stay
  token-request form fields) and `device_flow: :openai` — the Codex device-code login
  (`OAuth.device_begin/2`: `POST <issuer>/api/accounts/deviceauth/usercode` → a
  `user_code` to type at `<issuer>/codex/device`; `device_poll/1`: `POST
  …/deviceauth/token` answers 403/404 while pending, then the authorization code and the
  PKCE verifier the vendor made, exchanged at `/oauth/token` with the vendor's own
  callback `<issuer>/deviceauth/callback`; the pending login sits in `Logins` under a
  state, `Logins.get/1` reads without taking). No port, no address to catch: the way for a
  Longx on a server the browser is not on. Settings → 凭证
  (`settings/CredentialsSection`, `core/credentials.ts`: the list, add API key / OAuth2,
  登录 opens the URL in a new tab and the list polls until the browser comes back, 立即刷新,
  delete behind a confirm, the redirect URI to register). A plug's own Elixir code calls
  `Longx.Credentials.request/4` directly (`writing-plugs.md`). Tests:
  `test/longx/credentials/` (resource, `http`, `oauth`, `refresh_worker`, `plug`,
  `agent` — the login and the typed key end to end with Bypass as the model and as the
  provider), `callback_controller_test`.
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
  draw the bar (`DownloadBar`, shared with the upgrade). **Resolution order**
  (`Runtime.resolve/2` → `{:ok, :env | :downloaded, path}`): `LONGX_OBSCURA`, then the
  download — the pinned version, else the newest older `<dir>/<version>/` so the browser
  keeps working right after a Longx upgrade. **An `obscura` on PATH is never used**: only
  a version we pinned and checksummed runs (the PATH lookup of 2026-09-18 was taken out
  the same day). The status carries `source`, `installed_version` (a download's
  directory, or `--version` through the shim for the env binary, 2 s, cached 10 min),
  `latest` (the pin) and `upgradable`; `install/0` downloads nothing for an env binary
  and, for an older download, installs the pin and `Runtime.prune_old/2` removes the old
  version dirs — the card's 升级 button. In a container: mount `data/obscura`, or point
  `LONGX_OBSCURA` at a binary the image ships.
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
  - **Error reporting — `Longx.Sentry`** (`{:sentry, "~> 13"}`, the default Finch client):
    the SDK starts with no DSN (`config :sentry` — silent) and the one saved in the
    settings (`Setting` key `sentry_dsn`, encrypted) is applied at runtime with
    `Sentry.put_config/2` — `set_dsn/1` validates the shape and applies, `""` clears
    and turns reporting off, `configure_from_settings/0` is a boot task after the repo.
    Reported: request exceptions (`use Sentry.PlugCapture` on the endpoint,
    `plug Sentry.PlugContext` after the parsers), process crashes
    (`Sentry.LoggerHandler` attached once a DSN is set, crash reports only),
    `Longx.System.Faults.record/3` (`fault/3`, warnings), failed turns from the Tracker
    (`turn_failed/3`, errors tagged thread / turn, fingerprinted by the message's first
    words — a provider's refusal of the prompt or the account (a content filter, a
    quota) is not sent: the person sees it on the page), and `send_test/0` from the page. RPC `sentry_status` / `set_sentry_dsn` /
    `sentry_test`; `before_send/1` drops Bandit's client-side protocol errors
    (`Bandit.HTTPError` — a connection opened and never used is a "Read timeout" logged
    with a crash reason —, `Bandit.TransportError`), which are not bugs of ours; the
    Sentry project is `oxo/lonx` (`sentry issue list oxo/lonx`); the card at the bottom of Settings → 请求记录 (`SentryCard`,
    `core/sentry.ts`): the DSN masked, 已开启 / 未开启, 发送测试事件, 清除并停止. Tests:
    `test/longx/sentry_test.exs` (Bypass plays Sentry's envelope endpoint),
    `sentry_rpc_test`.
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
    `agent_definition`, `promote_local`; Turn: `list_turns`.
  - **Channels** (`LongxWeb.UserSocket` at `/socket`, `connect_info: [:uri]` — the uri feeds
    `LongxWeb.Origins`; the endpoint had it only on the LiveView socket until 0.2.7, so the
    browser's address was never remembered). **Nothing a channel sends can kill the
    socket**: `LongxWeb.Wire.clean/2` makes every reply and push JSON-safe in the channel
    process (invalid bytes scrubbed, DateTimes to ISO, anything else `inspect`ed; a clean
    payload is returned as it is) and `LongxWeb.Socket.Serializer` (the endpoint's
    websocket serializer) turns a leftover encode failure into an error frame
    (`phx_reply` status error / event `longx/error`) instead of a transport crash — that
    crash closed the connection for every channel and the client rejoined in a loop. Both
    record to `Longx.System.Faults` (an ETS ring, in the tree; RPC `recent_faults`; listed
    under Settings → 请求记录, counted on the status strip as N 个服务端故障). The client
    has the other half: `core/chat/breaker.ts` — `createJoinBreaker` (one per page, from
    `socket.ts`'s `joinBreaker()`; a channel whose pending join sees three socket closes
    is left and its view says 这个会话的视图加载会让连接断开, the other channels keep the
    connection; a child view is dropped) and `createCloseTracker` (five closes in a
    minute = status `unstable`: a red banner naming the server, reconnects at 5–10 s
    instead of phoenix's ladder, calm again after 30 s open). `LongxWeb.ThreadChannel` (`thread:<kernel_thread_id>`,
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
    `"from"` on an agent's message → `metadata.custom.from`, the `[agent name] ` prefix (for the model) stripped, **`"kind"` → `metadata.custom.kind`** — what the message is, stamped by the kernel (`State.user_ui`, `kind:` on `Agent.send/3`): `report` (`Team.report_to_parent` to the parent: the child done with its task), `answer` (the same to `reply_to`: the asker), `question` (a `send/3` with `reply_to:` — the `send_message` tool, `Projects.deliver` with `from_thread:`); older items have none —, and **consecutive messages from one agent of one kind fold into one message** with several text parts (two steers in a row once drew two boxes each headed `agent coder-3`); `thread.aui`'s `AgentMessage` is the **speaker-identity element's row** (`elements/speaker-identity`: `SpeakerRow`, our extraction of its per-turn markup — the circle badge of `kind: "subagent"`, the name, a detail) with the detail `汇报` / `提问` / `回复` (`· N 条` when folded; `data-testid="agent-message-kind"`) and the text parts stacked through `MessagePrimitive.GroupedParts` with a rule between, each `MarkdownText` (a report is markdown; the person's bubble is plain text; the name is the `AgentLabel` slot — `chat/AgentLabel`: a session addressed through the directory (`~052ca4`) shows the directory's title for it and links to its page, a team name is the bare name; `core/projects.ts`'s `sessionTitle` names a session — title, else its first 24 characters, else the address); **the outgoing half of an exchange is a row too**: `agents.send_message` renders standalone (`toolkit`'s `SendMessageTool`: 问了 + the same session name, linked + the message, folded past 160 characters) so the person sees whom the agent asked and what before the answer arrives as that session's message; an upload's `<attachment name path size />` tag (and the note after it, both for the model) is a paperclip chip `name · size` in the person's bubble (`mentions.ts` parses it beside `@` mentions); a sub-agent's activities folded into `subagent`
    parts — one row per turn the child was engaged in (spawned, or asked again later:
    `SubAgent.rowItemIds`), the latest row carrying the child's whole conversation as
    `messages`, earlier ones a completed marker — so a child asked again is seen where
    the person is, not at its spawn far above), `adapter.ts` (`buildAdapter` →
    `ExternalStoreAdapter`: `onNew` → `steerTurn` while `runningTurnId(view)`, else `sendMessage`;
    `/goal <objective>` typed past the popover
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
    Provider — providers as cards, presets first, `LevelsEditor`, 档位与别名; a provider on
    a credential shows 已登录 / 未登录 instead of the key badge and 登录 ChatGPT in its
    menu; the `chatgpt` preset's dialog has no key field and opens
    `settings/ChatGptLoginDialog` after applying: the device code with the vendor's page
    and a poll every `interval` s, and beneath it 改用浏览器登录 with the paste box; the
    凭证 page's 登录 opens the same dialog for a `deviceFlow: "openai"` credential —,
    `dependencies` 系统依赖, `knowledge` 知识 (global docs in the CodeEditor, a save is a
    commit when git is there), `agent` Agent 内核 (settings, public URL, the browser card,
    private network), `watches` 监控与定时, `processes` 进程 (the agents' live commands,
    killed from the page), `update` 版本与更新, `requests` 请求记录, `appearance` 外观).
    `ProjectWindow`: desktop = icon rail + docked resizable tool window + status strip;
    phone = chat full-screen, bottom toolbar, tools as bottom sheets. Tool windows
    `frame/tools/{Threads,Git,Agents,Files}Tool` toggled with ⌘1–4 (`core/frame.ts`,
    remembered per device; a device that remembered the gone `history` tool falls back):
    Threads is the `thread-list` element; Git is GitHub Desktop's
    shape (branch popover, sync button, Changes, History); Agents is the thread's sub-agents as `background-inbox`;
    Files is the IDE tree (git status coloured, ignored dimmed, new / rename / delete, a
    filter over `search_files`). `frame/StatusStrip`: HEAD and dirty count, missing
    dependencies, the browser download, a new version — every item `whitespace-nowrap
    shrink-0`. **The centre is an editor area** (`ui/workbench/Workbench`, state in
    `core/workbench.ts`): the chat tab first and always, files and diffs from the tools,
    a sub-agent's conversation (`agent`, from its row or the Agents inbox);
    `EditorTab` = `ui/editor/CodeEditor` (CodeMirror 6, lazy languages + Elixir, our tokens
    as the theme, ⌘S; **a markdown file opens rendered** — `ui/editor/MarkdownPreview`,
    react-markdown + remark-gfm with the chat's markdown classes and shiki — 编辑 / 预览
    toggle in the tab's bar, the editor straight away when `show_file` named a line), `DiffTab` = `ui/editor/DiffView` (`@codemirror/merge`, side by side
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
    scrolling middle. **Copy works over plain http**: a LAN address is not a secure
    context and the browser gives no `navigator.clipboard`, so `ui/lib/clipboard.ts`
    (`copyText`, the selection + `execCommand("copy")` way) backs `use-copy-to-clipboard`
    and `installClipboardFallback()` at boot (`index.tsx`) gives the page a
    `navigator.clipboard.writeText` for assistant-ui's own copy button.
  - **The chat** — `ui/chat/`: `ChatProvider` (mounted by `ProjectWindow` around the whole
    window: `useLongxRuntime` + `AssistantRuntimeProvider` +
    `GoalProvider`; `useChat()` reads it), `ThreadPage` (the Thread element; the composer
    rail: `ComposerTrailing` = the `context-display` ring (a click-to-open popover, not the
    hover tooltip — the auto-scroll closed it) + the `model-selector` element standalone
    (models grouped by provider, tiers and aliases first, `efforts` from the row's
    levels; the rail shows the description's model when the project pins one —
    `definitionModel`) + the `TurnState` ("waiting" while an ask is pending)),
    `GoalBar`, `AgentsPanel` (`agentSummaries(view, subviews)`: every child the view
    mentions with its live state — working with what its model writes, waiting with
    the ask's title, done; on a desktop a card floating at the chat's top right, the
    working / waiting ones then 最近完成, a click opens a child's tab, ■ stops it,
    folded to a pill on request (`localStorage`); on a phone `AgentsPill` — a count,
    amber when someone waits — opens the Agent sheet, whose inbox shows the same
    live labels; nothing when the thread has no child — the rows sit where the
    children were spawned and a long page hid who still worked), `TurnBar`,
    `ReasoningSteps` (the `reasoning-panel` step design over
    `reasoningSteps.ts`; **folded until the reader opens it**, the choice kept — a page
    unfolding every thought while it streamed was too long; a sub-agent's row is folded
    the same way, opening by itself only when its child waits on the person —
    `ToolRow`'s `openWhileRunning`), `SlashCommands` (`/new`, `/compact`, `/goal`, `/git` `/files`
    `/settings`, `/init` — over `unstable_useSlashCommandAdapter` and the
    `composer-trigger-popover` element), `FileMentions` (`@` over
    `unstable_useLiveCompletionAdapter` → `search_files`; `directive-text` chips),
    `toolkit.tsx` (`defineToolkit` with `type: "backend"`, `display: "standalone"`
    renderers per item type, **all built from the registry's Tool-use elements**: every
    invocation a `tool-call` row whose body is `terminal-block` (commands), `file-tree` +
    `code-diff` (file changes), `web-search` / a `ReadPage` link row (search / `web_fetch`),
    `ActionTool` (an ask: `elicitation-form` for fields, buttons otherwise, answered via
    `extras.answerAction`), `SubagentTool` (**a one-line summary, never the
    conversation**: name, `agent-status` pill with what it does and its model · level,
    the child's last words as an excerpt, its pending ask drawn on the row as an
    `ActionTool` — answered there —, 打开 and 停止; 打开 asks `SubagentContext.open` for
    the workbench `agent` tab — the child's whole conversation read-only in the editor
    area (`ui/workbench/AgentTab`: a read-only `useExternalStoreRuntime` over the
    parent page's `subviews`, else its own `useThreadView`, drawn by `thread.aui`'s
    exported `ReadOnlyThread`; a header link 到它的页面去对话 leads to the child's own
    page). The Agents tool window's inbox opens the same tab. A nested conversation in
    the transcript made a page one had to scroll for minutes to fold), `CompactionUI` for
    the marker). Attachments: `CompositeAttachmentAdapter([SimpleImage, SimpleText,
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
  `elicitation-form`, `agent-status`, `background-inbox`,
  `context-display`, `model-selector` / `model-picker`, `reasoning-panel`, `speaker-identity`
  (registry name `elements-speaker-identity`; the catalog's names differ from the registry's —
  `registry.json` at `r.assistant-ui.com` lists them),
  `markdown-text` with `shiki-highlighter` and `mermaid-diagram` (**LaTeX** as
  assistant-ui's guide: `remark-math` + `rehype-katex`, KaTeX and its stylesheet a
  **lazy chunk** (`ui/math/useMath`: fetched the first time a MarkdownText mounts, every
  markdown part re-rendered when it is in; the TeX shows as text until then); **one
  KaTeX** — `katex` is pinned to the major `rehype-katex` renders with (0.16; a 0.18
  beside it once served a stylesheet whose sizing class was `katex-sizing` to HTML that
  said `sizing`, and every subscript sat full-size on the baseline — `useMath.test`
  checks the classes against the CSS and the lockfile for a nested copy). MathJax 4 with
  Fira Math was tried and reverted: its SVG output estimates the width of glyphs the
  font lacks, so `\text{中文}_i` lost or misplaced its subscript, and sans operators
  read thin. Before the renderer, `core/chat/math.ts` (unit-tested, DOM-free):
  `normalizeMathDelimiters` (`\(…\)` / `\[…\]` → `$…$` / `$$…$$`) →
  `blockMathOnItsOwnLines` (a line that is only `$$…$$` gets its fences on their own
  lines — remark-math reads the one-line form as inline) → `wrapIdentifiers` (a run of
  3+ letters or two capitals inside math, not a macro or a macro's text argument,
  becomes `\mathrm{}` — TeX set `TotalVolume` as ten italic variables with spacing
  between) → `escapeCurrencyDollars` (`$5 到 $7` is not math); `MarkdownPreview` uses
  the same pipeline), `thread-list.aui`,
  `message-timing.aui`, `composer-trigger-popover.aui`, `directive-text`, `message-queue`,
  `surfaces` and `../utils/range.ts` as shared helpers.
- Tool UI: toolkit `render` per item type; `display: "standalone"` keeps a tool out of the
  collapsible trace group (commands / file changes are "informing the user", not a trace).

## Releases

**Docker.** `Dockerfile` builds the runtime image from a release tarball on `ubuntu:24.04`
(the runners' glibc; nothing compiled) with git, ripgrep, fd, jq, tree, bat, fzf, Python 3
+ uv + pip, Node 22 + npm and build-essential; the agent runs as `longx` (uid 1000), `tini`
is PID 1, `/data` and `/home/longx` are volumes (data; what the agent installs at user
level — `npm_config_prefix` and `UV_TOOL_BIN_DIR` point into the home), `/workspace` the
projects, `HEALTHCHECK` on `GET /health` (`LongxWeb.HealthController`, plain text, the
version in `x-longx-version`). `LONGX_CONTAINER=1` makes `Longx.Upgrade.install/1` nil and
`status.container` true: the update page says an upgrade is a new image. `release.yml`
pushes `ghcr.io/<repo>:<version>-<arch>` per arch and an `image` job stitches
`<version>` + `latest` with `docker buildx imagetools create`. `docker-compose.yml` is the
shipped setup (`LONGX_PUBLIC_URL`, the three mounts, an NVIDIA block commented out).
**Boot migrations run on one connection** — `Longx.Migrator`, a child before `Longx.Repo`,
starts a dynamic repo instance (`Longx.Migrator.Repo`, `pool_size: 1`, a plain pool) and
stops it: SQLite checks a `DROP COLUMN` against the connection's cached schema at parse
time, and on the app's pool the `drop gpu_passthrough` migration landed on a connection
that had never seen the add — 0.2.4 could not boot on an empty data dir
(`migrator_test`: a fresh database migrates from nothing).


`MIX_ENV=prod mix assets.build && MIX_ENV=prod mix release` builds a self-contained
release (Erlang runtime, the Go shim, the built SPA); `mix.exs`'s release steps `trim_priv/1`
(drops `priv/plts`) and `prune_old_versions/1` (removes any other `lib/longx-<version>/` —
`mix release --overwrite` replaces only the current version's directory, and CI's cached
`_build` shipped a stale `longx-0.1.0/` with the then-bundled codex, obscura and git,
500 MB, in every tarball up to 0.2.1; `release.yml` also `rm -rf _build/prod/rel` first).
A lean release is ~30 MB compressed. Nothing is downloaded at build time: git is the host's, the browser is
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
  one on 7798 if it is already up). **The e2e suite** — `npm run e2e` in `assets/`
  (`scripts/e2e/run.mjs`; `-- turn exchange` picks scenarios by name; `LONGX_E2E_URL`,
  `LONGX_E2E_MODEL`, `LONGX_E2E_KEEP=1` keeps the scratch projects) — drives a running
  Longx with its real model through the page and the page's own RPC (`scripts/e2e/
  lib.mjs`: a `Harness` with a scratch project under the OS tmp dir, `send` / `idle`
  (no turn in progress), a phone context, console-error and overflow checks, screenshots
  in `scripts/e2e/out/`). Scenarios: `01-pages` (every page, desktop and phone), `02-turn`
  (a file written and run, the rows and the badge, a second turn from the composer),
  `03-stop` (a `sleep` stopped from the page, the next message taken), `04-exchange` (two
  sessions: on duty asked and answered, off duty refused, the Agents window's switches),
  `05-goal` (the bar: paused, gone once complete). A model that refuses an instruction
  fails a scenario — that is the point; run it before a release and after a change to the
  kernel, the prompts or the chat.
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
