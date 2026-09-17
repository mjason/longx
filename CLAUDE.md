# Longx

Agent application. **Ash 3 + Phoenix 1.8 (Bandit, SQLite)** backend that drives the
**OpenAI Codex app-server** (`codex app-server`, JSON-RPC) and renders the agent UI with
**React 19** (Vite, shadcn/Tailwind v4, assistant-ui for the chat), mobile-first, with a
React Native client planned on the same core code.

## Architecture

- `lib/longx/` — Ash domains & resources (`AshSqlite`). Business logic lives in Ash actions
  and is called through code interfaces — never in controllers/LiveViews.
- `lib/longx/shim.ex` + `native/shim/` (Go) — `Longx.Shim`: runs external programs through
  our own port middleware (adapted from ex_cmd/odu, see `NOTICE`). Gives back-pressured
  stdin/stdout, a separate stderr stream, `close_stdin` independent of stdout, and clean
  termination: `kill/2` SIGTERMs the child's whole process group then SIGKILLs after a grace
  period; if the owner process or the BEAM dies the shim sees its stdin close and does the
  same. Output is pull-based (the shim sends a chunk per `read` credit), so `await_exit`
  closes what nobody read to let the shim go — except with `close_streams: false`, which
  `run/2` uses: its drain tasks may not have asked for anything yet when a fast child is
  already gone, and closing then threw the output away (a silent empty stdout under
  load, or a reader's call hitting a stopped server). Protocol is defined twice —
  `native/shim/proto.go` and `lib/longx/shim/proto.ex` —
  keep them in sync and bump the version in both when it changes (now 3). The binary is
  built by `Mix.Tasks.Compile.Shim` into `priv/bin/` (gitignored) on `mix compile`; **Go must
  be on PATH**. `mix precommit` also runs `gofmt`, `go vet`, `go test` in `native/shim`;
  Windows/macOS code is `GOOS=windows|darwin go vet`-checked (no machine here to run it).
  Windows support is via `CREATE_NEW_PROCESS_GROUP` + CTRL_BREAK + `taskkill /T`, plus a
  **Job object** per child (`guard_windows.go`: `KILL_ON_JOB_CLOSE` makes tree kills reliable).
  **Resource guards** (`native/shim/guard_*.go`, options `oom_score_adj:` / `memory_limit:`,
  `Shim.stats/1`): Linux writes `oom_score_adj` to the shim itself before spawning so the
  whole tree inherits it (raising needs no privilege; the BEAM stays at its own value — under
  memory pressure the kernel kills the fattest process of a codex tree first, never the BEAM);
  `memory_limit` is `RLIMIT_AS` via `prlimit(2)` on the child (Linux) or the Job's memory
  limit (Windows; allocations fail inside the job — Windows has no OOM killer, so this is
  the only way to keep commit for the BEAM), ignored on macOS. **RLIMIT_AS counts address
  space**: runtimes that reserve it up front (a BEAM: 1 GiB carrier + scheduler stacks; JVM,
  Go) need generous caps — the test fake needs 16 GiB. `stats/1` answers with the tree's
  process count, RSS and CPU (Linux: `/proc` walk by parent pid; Windows: Job accounting +
  working sets; macOS: `ps`).
- `lib/longx/codex/runtime.ex` — `Longx.Codex.Runtime`: the **bundled** `codex-app-server`.
  Never use the machine's `codex`. Pinned to upstream release `rust-v0.154.0`; the
  `codex-app-server-package-<target>.tar.gz` asset (bare binary + `bwrap`/`rg`/`zsh` the
  Linux sandbox needs; the only variant with published SHA256s) is downloaded by
  `mix codex.fetch`, checksum-verified against hashes pinned in the module, and unpacked to
  `priv/codex/<target>/` (gitignored; `priv` ships in `mix release`, so CI runs
  `mix codex.fetch [--target …]` before `mix release`). `mix setup` runs it too.
  `Longx.Codex.Runtime.executable/0` resolves the binary; `LONGX_CODEX_APP_SERVER` overrides.
  Bumping the version = change `@version` + the six `@sha256` entries from the release's
  `codex-package_SHA256SUMS`, then `mix codex.fetch --force`, and refresh
  `priv/codex_prompt.md` from the release's `codex-rs/models-manager/prompt.md` (the
  model catalog's base instructions; `mix test --include integration` checks it).
- **Git is bundled too, and it is real git.** `Longx.Git.Runtime` pins GitHub Desktop's
  portable build (`desktop/dugite-native` v2.53.0-4: git 2.53.0 + git-lfs + git-remote-https,
  six targets, sha256 per target) fetched by `mix git.fetch` into `priv/git/<target>/`
  (gitignored; in `mix setup`). Every repository operation goes through `Longx.Git`, which
  runs the bundled binary with dugite's environment (`GIT_EXEC_PATH`, bundle gitconfig and
  templates, Linux CA bundle, Windows `mingw64` PATH; plus `GIT_TERMINAL_PROMPT=0`,
  `LC_ALL=C`) via `Longx.Shim.run/2` (stdout/stderr separate, tree killed on timeout). Never
  reach for the machine's `git`, never a reimplementation (go-git/gitoxide/libgit2 lack
  hooks/LFS fidelity — evaluated and rejected). `Longx.Git`: `repository?/toplevel/init/head`,
  `status` (porcelain v1 -z), `commit_all` (falls back to a Longx identity when the user has
  none), `log`, `diff`, `restore_tree` (files back to a commit, branch untouched),
  `reset_hard`, `worktree_add/remove/list`, `lfs?`; and, for the git tool (GitHub Desktop's
  feature set on the bundled binary): `commit/3` (named paths only — during a merge the
  merge is committed whole, git allows no partial commit then), `file_diff/2` (working tree
  vs HEAD; untracked against nothing; binaries flagged), `discard/2` (tracked restored,
  untracked removed), `log` (`limit`/`skip`, email), `show/2` (message, parents, files with
  status; merges against their first parent), `commit_file_diff/3`, `undo_commit/1`
  (`reset --soft HEAD~1`, never the root), `branches/1` / `create_branch` / `switch` /
  `delete_branch`, `stash` / `stash_pop` / `stashes`, `remotes` / `set_remote` /
  `ahead_behind` / `fetch` / `pull` / `push` (upstream set on first push; 120 s), `ignored/1`
  (what `.gitignore` hides, directories whole), `merging?/1` / `abort_merge/1`,
  `file_versions/3` (`git show rev:path` on both sides), `merge/3` (`{:error, :conflict}`
  leaves the merge in progress). Every command that may commit (`commit_all`, `commit`,
  `pull`, `merge`) passes the Longx identity as `-c user.*` when the user has none —
  GitHub runners have none, a fresh machine neither. Auth for
  remotes is whatever the machine's SSH agent / credential helpers give the bundled git
  (`GIT_TERMINAL_PROMPT=0`: never a prompt, an error instead). The suite plays the remote
  with a bare repository on disk. `LONGX_GIT` overrides the binary.
  Bundle download/verify/extract lives in `Longx.Bundle`, shared with `Codex.Runtime`.
- `lib/longx/projects/` — Ash domain `Longx.Projects` (single-user; no thread ↔ user mapping):
  - `Project` = a working directory (absolute, existing, unique `root_path`) + defaults for
    its threads: `approval_policy`, `sandbox`, `network_access` (the workspace-write sandbox
    has no network unless this is true → `sandbox_workspace_write.network_access`), `tools`
    (registered `"ns.name"`s), `model_id` (nil → global default), `dirty_start`
    (`:commit` | `:ask` | `:off`), `writable_roots` (the project's own extra directories
    the workspace-write sandbox may write — default `[]`). **The user's tool cache is
    writable in every workspace sandbox, like /tmp**: `Projects.writable_roots/1` always
    starts with `Longx.Codex.Sandbox.cache_dir/0` — per platform, never a hard-coded
    `~/.cache` (0.1.7 stored that as a row default, Linux-only, and it was reverted):
    Linux `$XDG_CACHE_HOME` (absolute) else `~/.cache`, macOS `~/Library/Caches`, Windows
    `%LOCALAPPDATA%` else `~/AppData/Local` — uv / pip / npm / cargo / Hugging Face all
    live there and fail on the first run without it. Then the project's roots (`~`
    expanded), only existing directories; they go on `thread/start` as
    `sandbox_workspace_write.writable_roots`, on resume the same, and in
    `turn/start.sandboxPolicy.writableRoots` on every turn — one path for every platform,
    including Windows where codex enforces the sandbox itself. **Devices and sockets go in through `passthrough_paths`, never as writable roots**:
    bwrap's `--dev /dev` is minimal and a device node as a writable root breaks the launch.
    `Project.passthrough_paths` (globs allowed; `Projects.passthrough_paths/1` resolves to
    what exists, sorted) is read by **the exec-server at every command start**
    (`Projects.exec_context/1`) — no restart, no `stale`. **The GPU is no setting**:
    `passthrough_paths/1` always adds this machine's `gpu` preset (`Sandbox.presets/1`:
    nvidia*, dxg, dri), so every sandbox on a box with a GPU has it — a device node is
    neither a file nor the network (nothing to read or reach through it, the driver surface
    every process has), codex's permission requests cannot ask for one, and Longx's users
    run backtests on it. The `gpu_passthrough` switch of 0.1.13 and the chat's GPU hint
    (`sandboxHints` / `SandboxHint`) are gone (migration drops the column). Upstream has no
    GPU answer (openai/codex#3141, #19676; PR #8002 closed over security concerns). Project
    settings keep only long-lived exceptions, folded under 高级 (writable roots, Linux
    passthrough for USB / sockets) — no presets, no cache lists: the agent asks. Whether it is a git repo is read live (`git_info/1`), never
    stored; `init_git/1` sets git up with `Longx.Git.Ignore.default/0` and a first commit.
    The UI warns when a project has no git.
  - **Each project has its own codex process and its own `CODEX_HOME`**
    (`Longx.Codex.Pool`, below). `Projects` never needs a `conn:` — `start_thread/2` takes
    the project's pooled connection, `send_message/3` the connection hosting the thread
    (resuming it on the project's codex first when nobody hosts it, i.e. after a restart);
    tests pass `conn:` to use their own fake. The codex is a project resource:
    `codex_info/1` (home path, size, sqlite files, worker status incl. OS pid), `stop_codex/2`
    (refuses while a turn runs unless `force: true`), `restart_codex/1`,
    `clear_codex_history/1` (stop + delete codex's sessions and state in the home, keep our
    config and its `memories/`; the threads become `:unrecoverable`),
    `clear_codex_memories/1` (only what codex learned about the project: `memories/` and
    `memories_*.sqlite`; sessions and threads stay — for codex's project memory gone wrong),
    `reset_codex_home/1` (the whole directory; threads `:unrecoverable`; the next use
    regenerates a clean config), archive stops the worker and keeps the home,
    `delete_project/2` needs `confirm: true` and removes the home (never the working
    directory; its thread and turn rows go first — `Changes.DeleteThreads` — since they
    reference the project and SQLite refused the delete of any project with history as
    "referenced something that does not exist"). All five are the project settings page's danger zone (delete asks for the
    project's name).
  - **Permissions are codex's own, asked for on demand** (`Home.config_toml` turns on
    `features.exec_permission_approvals` + `request_permissions_tool`, both UnderDevelopment
    in 0.154 and verified on the binary): `:on_request` is the plain `"on-request"` string —
    codex never widens the sandbox by itself, a denied command is reported to the model, which
    asks. A command asking for a directory / the network (`with_additional_permissions`)
    arrives as `item/commandExecution/requestApproval` with `additionalPermissions` and
    `availableDecisions` (`accept` / `cancel` — no session variant); accepted, it runs
    *inside* the sandbox with that one grant. The `request_permissions` tool arrives as
    `item/permissions/requestApproval` (`permissions`, `reason`; no item of its own),
    answered with `{permissions, scope: turn | session}` — `Thread.decision_for/3` maps our
    `:accept` / `:accept_for_session` / `:decline` to that, and for command approvals to
    what `availableDecisions` lists (`acceptWithExecpolicyAmendment` = an execpolicy rule in
    the project's home for "always"). `messages.ts` builds the card from the request:
    `approvalOptions` (本轮允许 / 本会话允许 / 拒绝 for a permissions request; the offered
    decisions otherwise — the session button only when offered), `permissionLines` (写 /x ·
    读 /y · 联网), a standalone `permissions` tool part rendered by `PermissionsTool`.
    `sandbox_permissions_integration_test` proves both flows on the real binary; live with
    DeepSeek: a read-only `~/.cache/uv` → `request_permissions` → card → 本轮允许 → the run.
    A granular policy (`sandbox_approval: true`, which makes codex ask "retry without
    sandbox?" on a denial) was tried and dropped: codex refuses `with_additional_permissions`
    under anything but plain on-request.
    **Automatic approval review — codex's Guardian, on by default** (`Project.auto_review` →
    `Thread.auto_review`, fixed at start: `thread/start.config.approvals_reviewer =
    "auto_review" | "user"`, on resume / fork / sub-agent rows too; the ModePicker switch is
    new-chat only, like web search). Every approval request (a command with
    `with_additional_permissions`, a `request_permissions` call, an MCP/network one) goes to
    a read-only reviewer sub-session on the thread's model (its `low` effort when declared;
    codex's preferred reviewer model is not in our catalog, so it falls back to the active
    slug) — **or on a model of its own**: `Longx.AI.set_review_model/2` / `review_model/0`
    (`Longx.System.Setting` keys `review_model` / `review_effort` — **`Setting`'s upsert names
    `:encrypted_value`**, AshCloak's column: with `upsert_fields [:value]` a second put never
    updated, so a review model, effort or GitHub token could be set once and never changed,
    `setting_test`; RPC `review_settings` /
    `set_review_model` on `Longx.AI.Model`, the 自动审核 card of Settings → 模型) makes
    `Home.catalog_models/0` add a `longx-review` entry — that model's, its levels narrowed
    to the pinned one (codex takes `low` whenever an entry offers it) — that every other
    entry names as `auto_review_model_override`; the gateway resolves the slug
    `longx-review` (`AI.review_model_slug/0`) to that model, the default one when none is
    set. A catalog change, so `stale: [:models]` and a codex restart. Proven in
    `auto_review_integration_test`: the reviewer's request carries the review model and
    its level, the agent's the thread's — through our gateway — one extra model call per request — with
    `core/assets/guardian/policy.md` as instructions and a strict-JSON verdict
    (`text.format` is sent; the parser also takes JSON inside prose, so third-party models
    work: live with DeepSeek Flash a whole-home write was denied, a single file allowed).
    No card: `item/autoApprovalReview/started` / `completed` (`reviewId`, `targetItemId`,
    `action` in v2 camelCase, `review.status inProgress|approved|denied|timedOut|aborted`,
    `riskLevel`, `rationale`) plus a `guardianWarning` text we ignore. The Store / `thread.ts`
    fold them into one `autoApprovalReview` item per review id; `messages.ts` puts the
    review on its target's part (`args.review`, an `AutoReview`) or, with no item of its
    own (a permissions request), a standalone `autoReview` part; `AutoReviewVerdict` in the
    toolkit is a line above the row (running / approved) or an `approval-card` in its
    `denied` state. **A denial never falls back to asking the person**: the command item is
    `declined`, the model is told to stop or ask; the card's 仍然允许 →
    `extras.approveDeniedReview` → RPC `approve_review` → `Projects.approve_denied_review/3`
    → `Longx.Codex.Thread.approve_denied_review/3`: the stored item back in codex's *core*
    shape (`Thread.guardian_event/1`: snake_case keys, `unified_exec`, `request_permissions`)
    on `thread/approveGuardianDeniedAction`, then Longx's own
    `item/autoApprovalReview/userApproved` event marks the item; the renderer appends
    "请继续" as a user message, and the next request carries codex's developer note
    ("The user has manually approved…") the reviewer treats as authorization. Circuit
    breaker: 3 consecutive denials (10 in 50) interrupt the turn. Full access is never
    reviewed. `auto_review_integration_test` (`:integration`, Bypass plays agent and
    reviewer) proves allow, deny and the override on the real binary. codex's "always
    allow" (`rules/default.rules` in the project's home) only exists under `untrusted`, so
    it stays empty here.
    **全部放行 — `approval_policy: :auto_accept`, Longx's own value** (Project / Thread enum
    next to codex's three; per turn like the others): codex runs plain `on-request` and
    `ServerRequest.Default` answers every approval request of the thread at once —
    commands / patches `accept`, a permissions request as asked for the *session* — off a
    flag in the ThreadState store (`Store.auto_accept?/1` — **its own ETS key**, not a field
    of the meta map: `Thread.start` / `send` set it from the caller while the writer folds
    `thread/started` / `turn/started` into the map, and two processes read-merge-writing
    one map lost the flag on CI; set whenever `approval_policy:` is given, and by the
    Tracker on a sub-agent's row from its parent); no card, no review. The reviewer would judge first, so
    `start_params` forces `approvals_reviewer = "user"` under it and
    `Projects.send_message` sends `thread/settings/update` (`Thread.update_settings/2`) when
    a turn moves onto or off it (`reviewer_for/2`: the row's `auto_review` comes back).
    codex's `never` is the opposite — it *refuses* every request — hence the label
    从不询问（申请一律拒绝）. Proven on the real binary in
    `auto_review_integration_test` (no reviewer request, the file written; the settings
    update takes effect on the next turn).
  - `Thread` = codex thread ↔ project (`codex_thread_id`, `cwd`, the settings it started with,
    `model_slug`, `preview`, `status`, `last_activity_at`). Statuses: `:idle`, `:active`,
    `:disconnected` (its codex died mid-turn; resumed → `:idle` when it is back),
    `:unrecoverable` (codex no longer knows it — refuses new messages), `:archived`.
    `start_thread/2` calls `Longx.Codex.Thread.start/1` with the project's settings (model as
    slug + `model_context_window`) and asks `Longx.Projects.Tracker` to follow the codex topic.
  - `Turn` = one turn with git bookmarks. `send_message/3` does the **git preflight** first:
    clean tree → `commit_before = HEAD`; dirty → per `dirty_start` (`:commit` makes a
    `longx: before turn — …` commit so every turn starts from a commit; `:off` records
    `dirty_start: true`; `:ask` returns `{:error, {:dirty_tree, changes}}` unless
    `dirty: :commit | :ignore`), then `turn/start` (with `model:` if switching). The Tracker
    fills `status`/`completed_at`/`commit_after`/`diff` from `turn/completed` and
    `turn/diff/updated`, the thread `preview` from the first user message, and an empty
    `title` from codex's `thread/name/updated` (a title the person chose stays).
    **Access mode per turn**: `send_message/3` takes `sandbox:` / `approval_policy:` /
    `network_access:`; what differs from the thread row goes on `turn/start` as
    `sandboxPolicy` / `approvalPolicy` (codex keeps them for the turns after) and is
    recorded on the `Thread` (`network_access` is a thread attribute too). `images:` (data
    urls, the composer's attachments) go on `turn/start` as `image` inputs after the text —
    the gateway passes `input_image` parts through untouched (`detail: high` from codex;
    verified end to end against DeepSeek Flash's Responses API, which reads screenshots —
    a solid-colour synthetic test image it answers about unreliably, so test with a
    real one). **A message while a turn runs goes into that turn** (what the Codex app does):
    `steer_message/3` → `Longx.Codex.Thread.steer/4` (`turn/steer` with `expectedTurnId`,
    `images:` like a send) — codex shows it as a `userMessage` on the running turn and hands
    it to the model at its next request; no new Turn row; `{:error, :not_running}` once the
    turn is over (codex's "no active turn to steer"). RPC `steer_turn` (`threadId`, `text`,
    `images`; `not_running` on `threadId`). Client: `core/chat/steerQueue.ts` is a
    hold-nothing queue adapter — assistant-ui only lets the composer send while running when
    a queue adapter exists, and its own would hold the message until the turn ends — every
    message goes straight to `adapter.onNew`, which steers while `runningTurnId(view)` and
    falls back to `send_message` on `not_running`; `thread.aui`'s send button stays next to
    the stop while running. `messages.ts` splits the turn's assistant message at each steered
    user message (`turn:<id>`, `turn:<id>:1`, …: with one id assistant-ui kept only the last
    segment and the command before the steer vanished). Proven on the real binary
    (`steer_integration_test`) and live with DeepSeek: a `sleep 12` running, a second
    message typed, both answered in one turn. **Slash commands of the composer**:
    `compact_thread/2` (`thread/compact/start`,
    refused while a turn runs; codex marks the fold with a `contextCompaction` item) and
    `review_thread/3` (`review/start` with `delivery: inline` — the review is a turn of the
    thread: a Turn row with `user_text` "/review …", bookmarked like any turn but **never
    committed first**, since a review of the uncommitted changes needs them uncommitted;
    targets `:uncommitted` | `{:commit, sha}` | `{:base_branch, name}` | `{:custom, text}`).
    Over RPC: `images` on `send_message`, `compact_thread`, `review_thread` (`target` +
    `value`). **Stop before anything ran = take the message back** (Claude Code's
    behaviour): `retract_turn/3` — for an `:in_progress` turn that had no side effect
    yet: its items in the ThreadState are only words (`userMessage`, `reasoning`,
    `agentMessage`, `plan` — a revert drops them with the turn) and no request of the
    turn is pending; a command, a patch, a tool, a search, a sub-agent or an approval /
    question waiting is `{:error, :has_output}` (interrupt instead), a settled turn
    `:not_running` — marks the row `:reverted` **first** (the Tracker's `turn/completed`
    leaves a reverted row alone; it lands after a git call and used to overwrite the
    status with `:interrupted`), then `turn/interrupt`, waits for `turn/completed`
    (15 s), `thread/revert` of that one turn (`ThreadState.drop_turns` broadcasts
    `thread/reverted`, clients re-snapshot), idles the thread and answers
    `%{text: user_text}`; a failure puts the row back (`:in_progress` when the turn
    never ended, `:interrupted` when only the revert failed). RPC `retract_turn` on
    `Thread`; `adapter.ts`'s `onCancel` calls it instead of `interruptTurn` while
    `turnHadEffects(view, turnId)` is false (the same rule on the client's view) and
    hands the text to `onRetract` → `ChatProvider`'s `ComposerBridge` puts it back in
    the composer (`aui.composer.setText`) for editing. Proven on the real binary from
    the page: stopped mid-thinking → bubble and thinking gone, text back; stopped with a
    command running → the turn stays, the command 已取消. `delete_thread/1`
    removes the row and its turns (not while a turn runs; codex's own copy stays — the
    project-level wipe is `clear_codex_history/1`).
  - **Opening a thread** (`LongxWeb.ThreadChannel` join → `Projects.host_thread/1`): a
    thread nobody hosts is resumed on its project's codex; an *empty* one codex cannot
    resume (it only writes a thread to disk on its first turn) is started again under a
    new codex id (`Thread` action `rehost`; the join reply carries the id to follow);
    `:unrecoverable`/`:archived` threads join read-only. **A resume carries the thread's
    access mode** (`Projects.resume_thread/2` → `Thread.resume/2` with `cwd`, `sandbox`,
    `approval_policy`, `network_access`, `writable_roots` and the model's config): codex
    takes none of it from the stored
    thread — a resume without them ran on codex's defaults (read-only) after every
    restart / recycle while the row and the UI still said 完全访问 (verified against the
    real binary: rollout `turn_context.sandbox_policy`). A resume (`ThreadState.backfill`)
    and a dying connection (`Connection.terminate` → `withdraw_inbound`) both withdraw
    pending approvals nobody can answer any more.
  - **When codex dies** (`Longx.Projects.Tracker` on `"codex:connection"`): `:down` → every
    `:in_progress` turn of that project fails with "codex restarted…", its `:active` threads
    become `:disconnected`; `:ready` → those are `thread/resume`d on the new process (→
    `:idle`) or marked `:unrecoverable`. Idle threads are resumed lazily by `send_message/3`.
    **The Tracker's list of followed threads is in memory**: a Longx restart forgets it, so
    `resume_thread/2` and `send_message/3` both `Tracker.track/1` (idempotent) — without
    that a turn after a restart never completed its row and the thread showed 进行中 for
    ever; and `Projects.settle_after_restart/0` (a boot `Task` after the Tracker) fails every
    `:in_progress` turn ("Longx restarted while this turn was running") and idles every
    `:active` thread a previous boot left, since no codex survives the BEAM.
    **Stall watchdog**: a turn whose thread produced no event for `stall_after` (default
    10 min; `config :longx, Longx.Projects.Tracker, stall_after:, tick:`) gets
    `turn/interrupt` and ends `:interrupted` with error "no progress for N seconds".
  - **Going back**: `restore_proposal/1` (commit, dirty now?, changed files, later turns) is
    what the UI shows; `restore_files/2` needs `confirm: true`, makes a safety commit of any
    uncommitted work first, then `restore_tree` (files back, history untouched — default) or
    `reset_hard`. Nothing here touches ignored files or side effects outside the repo; say so
    in the UI.
  - **Redo from turn N with another model**: `redo_turn/2` — refuses while a turn runs or if
    the turn is already `:reverted`; optional `restore_files: true`; `mode: :revert` (default)
    calls `thread/revert` (needs `historyMode: "paginated"`, which every thread is started
    with; codex's `thread/reverted` names only the thread, so we pass the dropped turn ids to
    `ThreadState.drop_turns/2`, which deletes their items from the ETS store and broadcasts
    `thread/reverted` with `"turnIds"` — clients re-snapshot) and marks the rows `:reverted`
    (`list_turns/2` hides them unless `include_reverted: true`); `mode: :fork` uses
    `thread/fork` with the turn before N and creates a sibling `Thread` (`forked_from_id`).
    Then `send_message/3` with `text:`/`model:` through the normal git preflight. Worktree
    isolation was considered and dropped: knowing the commit after each turn is enough.
    Over RPC these are the `Turn` generic actions `restore_proposal`, `restore_files`
    (`confirm`, `mode`) and `redo_turn` (`text`, `model`, `mode`, `restore_files`).
- **The project's files and git, for the UI** — two data-less resources under
  `Longx.Projects` (like `Longx.System.Status`), one generic action per operation, wire-tested
  in `test/longx_web/rpc/workspace_rpc_test.exs`:
  - `Longx.Projects.Files` over `Longx.Projects.Workspace`: `list_files` (one level,
    directories first, `.git` never), `read_file` (1 MB cap → `truncated`, NUL / invalid
    UTF-8 in the head → `binary`, no content), `write_file`, `create_entry`, `rename_entry`,
    `delete_entry`. Every path is relative to the root and resolved inside it (`..`,
    absolute paths, `.git/` → an error on `path`).
  - `Longx.Projects.Repo` over `Longx.Git`: `git_changes` (the whole sync state in one call:
    branch, head, changes, ahead/behind, remotes, ignored, merging), `git_file_diff`,
    `git_commit`, `git_discard`, `git_undo_commit`, `git_abort_merge`, `git_log`,
    `git_show`, `git_commit_file_diff`, `git_file_versions` (both whole texts of one
    change — HEAD vs the working tree, or a commit vs its first parent; a missing side is
    null, a binary carries none — what the side-by-side view wants instead of a patch),
    `git_branches` (+ stashes), `git_create_branch`,
    `git_switch` (`stash: true` sets the tree aside first), `git_delete_branch`,
    `git_stash_pop`, `git_set_remote`, `git_fetch` / `git_pull` / `git_push`. git's own words
    come back as the error on the argument they concern; a non-repository answers
    `repository: false` to `git_changes` and an error on `project_id` to the rest. Commit
    times are ISO strings (a typed map's `utc_datetime` has no client type in
    ash_typescript 0.18).
- **A headless browser is bundled too: obscura** (`h4ckf0r0day/obscura`, Rust + embedded V8,
  Apache-2.0). `Longx.Browser.Runtime` pins `v0.2.2` (five targets: `{x86_64,aarch64}-linux`,
  `{x86_64,aarch64}-macos` as tar.gz, `x86_64-windows` as zip — `Longx.Bundle` unpacks
  both; upstream publishes no checksums, so the sha256s were computed once when pinning and
  are verified on every fetch), fetched by `mix obscura.fetch` into `priv/obscura/<target>/`
  (gitignored; in `mix setup`; `priv` ships in `mix release`, so CI runs `mix obscura.fetch`
  before `mix release` — it is part of every release, like codex and git; only windows
  arm64 has no upstream build). `LONGX_OBSCURA` overrides. The default (rendering,
  no stealth) variant is bundled; `stealth:` is a config flag.
  - `Longx.Browser.fetch(url, format: :html | :markdown | :text, timeout:, wait_until:,
    selector:, wait:, max_bytes:)` — **one short-lived `obscura fetch` process per page**
    under `Longx.Shim.run/2` (killed with its tree at the deadline, `oom_score_adj` 600,
    `OBSCURA_SCRIPT_DEADLINE_MS` = the deadline, optional `memory_limit:`), so an idle
    system runs no browser and nothing can leak across pages. `:html` is the page reduced by
    `Longx.Browser.Html.main/1` — the `main`/`article`/`[role=main]` element (else `body`)
    without scripts, styles, svg, iframes, nav/header/footer/aside/forms and with only the
    attributes that carry meaning (`href`, `src`, `alt`, `title`, …): the model gets HTML
    with its structure and links, not flattened text. obscura keeps its SSRF guard (private /
    loopback IPs refused) unless `allow_private_network: true` (tests against Bypass set it).
    stdout is the dump, stderr the log (`Page loaded: <url> - "<title>"` gives the title;
    `Error: …` and exit 1 on navigation failure; a 404 still renders as a page).
  - `Longx.Browser.Pool` (in the tree) hands out permits: at most `max_concurrent` (default
    `min(4, schedulers)`) fetches at once, FIFO waiting up to `queue_timeout` (10 s →
    `{:error, :busy}`), permits tied to the caller by monitor (a dead caller frees its slot);
    limits are read per request so config changes apply at once. Stateful sessions
    (clicking, logging in) are the planned second step: `obscura serve` behind the same pool,
    idle-shutdown like `Pool.connection/1` plus `Recycler`-style limits — not built yet.
  - Tests: `test/support/fake_obscura.sh` plays the CLI (`/page`, `/slow?N`, `/fail`,
    `/big`; flags echoed to stderr); `config/test.exs` points `executable:` at a
    nonexistent path so the unit suite never runs the real one; the real binary runs only in
    `test/longx/browser_integration_test.exs` (`:integration`, a Bypass SPA).
  - `builtin.browser_fetch` (`Longx.Tools.Builtin.BrowserFetch`, url / format / selector,
    60 s) is the agent's way to read rendered pages outside the sandbox.
- **The native agent kernel — `lib/longx/agent/` (`Project.engine: :native`, experimental).**
  Longx's own loop in place of codex: the kernel is four things — the process, the
  transcript, the execution of model and tool calls, and an interpreter of *phases and
  effects* — and everything else is a **plug**, the one concept. Chosen per project (the
  wizard's 高级 / project settings, `engine` column, default `:codex`); a native thread's id
  is `native_<uuid>` (`Projects.native?/1`). **No sandbox, no approvals, no policy**:
  commands run on the machine as the person (isolation is the deployment's job — the whole
  of Longx in a container — never the kernel's).
  - `Longx.Agent` — one GenServer per thread (`Longx.Agent.Registry`, under
    `Longx.Agent.Supervisor`, `restart: :temporary`), **the loop as OTP recursion**: a step
    runs the pipeline at `:request` (pure: prompt, tools, the request), the model streams
    from a task (`Longx.Agent.Model`) as `{:model, ref, event}` messages, the pipeline runs
    at `:response` (the model's calls known, none run yet), tool calls run as tasks under
    `Longx.Agent.TaskSupervisor` and answer as messages, `handle_continue(:step)` recurses
    until the model answers without a call, then the pipeline runs at `:turn_end`. **Never a
    blocking receive or a synchronous model call in a callback**: the mailbox is how steer,
    interrupt and `/compact` get in. `send/3` (`turn_id:`, `model:`, `effort:`, `images:`)
    starts a turn when idle and is a *steer* while one runs (into the context at the next
    step after the tool outputs, and **shown then** — until then it is the client's queue;
    a step is added when the model stopped before seeing it); `interrupt/1` kills the tasks (a
    command's shim tree dies with its task) and ends the turn `interrupted`; `retract/2`
    also truncates the turn from the transcript and `ThreadState.drop_turns`;
    `compact/1`; `status/1`. Guards: `max_steps` per turn (500, `config :longx,
    Longx.Agent, max_steps:`) and 20 continuations. **The process is light and leaves
    when idle** (`idle_ms:`, default 30 min, `config :longx, Longx.Agent, idle_ms:`;
    `{:stop, :normal}`, nothing restarts it): `Longx.Agent.Specs` (ETS, in the tree)
    keeps what every agent was `ensure`d with, `ensure_alive/1` starts it again from
    that and its transcript, and `send/3` does so by itself — a message brings an agent
    back in milliseconds; a crash likewise (the turn in flight is not resumed; a BEAM
    restart forgets the specs and `Projects.host_thread` rebuilds from the row).
  - **A team is more processes of the same loop, talking through the mailbox** — no
    wait tool, no shared inbox, no state machine: `spawn/4` (`Agent.spawn(parent_id,
    name, task, model:/effort:/cwd:/pipeline:)`, or the `Step.spawn/4` effect from any
    phase) starts a child `Longx.Agent` (`parent:` + `name:` options; `info/1`,
    `children/1`) and sends it the task; the child's instructions say it is the
    sub-agent "name" and that its final message is its report. **That report is a
    message in the parent's mailbox** (`{:agent_message, from, text}`): a steer while
    the parent runs (folded at its next step — a step is added when the model had
    already stopped), a new turn when it is idle (`turn/started`; the Tracker gives it
    a row, user text "（agent 消息）"). Words between agents are **user messages
    prefixed `[agent <name>] `** (the Responses API has no agent role every provider
    reads) with `"from"` on the UI item; `send/3` takes `from:`. The parent monitors
    its children: `:normal` / `:shutdown` says nothing, anything else is a message
    "[agent X] exited: reason"; a child monitors its parent and stops with it (its turn
    interrupted). How a child is made is the `spawner:` function the agent was
    `ensure`d with (`Longx.Projects.spawn_native_agent/4`: a Thread row under the
    parent with `parent_thread_id` / `agent_path` `/root/<name>` / title, the task as
    its first Turn row; a bare agent otherwise). The kernel itself keeps names unique
    among the live children (`helper`, `helper-2`) and refuses a spawn past the depth
    limit (`{:error, :too_deep}`; the settings' `max_depth`, else `config :longx,
    Longx.Agent, max_depth:` 2) — a strategy plug inherited by its own children would
    otherwise recurse for ever. **The parent's view shows a child the way codex does**:
    the kernel emits `subAgentActivity` items (`agentThreadId`, `agentPath`, `kind`
    started / interacted / completed / interrupted) on spawn, `send_message`
    (`Agent.interacted/2`), a report and a crash — kept in the transcript as
    `:activity` items (UI only, never model input: `append(…, context?: false)`,
    `Transcript.input/1` drops them) so a rebuilt view has them; `messages.ts` folds
    them into the `subagent` row whose body is the child's own conversation
    (`useThreadViews`), the Tracker's handler marks the child's row active / idle, the
    Agents tool lists it, and **its own page opens**: `useCodexRuntime` fetches a thread
    the project list hides by id (RPC `get_thread`, the Thread `by_id` read; `missing`
    only once that fails). `Agent.stop/1` is a normal `GenServer.stop`, never the
    supervisor's kill: a transcript write in flight finishes (a killed writer left
    SQLite's connection mid-transaction and every later query said "Database busy"). `step.assigns` carries `parent`, `name`
    and `children` so a strategy can see its team; **`step.state`** (`Step.put_state/3`)
    is a map the kernel keeps across the phases and steps of one turn (fresh per turn)
    for a strategy that counts rounds. The design is `docs/agent-kernel-plan.md` (all
    four slices built 2026-09-17).
  - **Roles are declarations, the model picks a role** — `Plugs.Agents` (in the default
    pipeline) offers `spawn_agent(agent, task)` with the declared roles as the enum
    (`step.assigns.agents` from the loader, narrowed by the description's
    `agents [...]` → `assigns.allowed`), `send_message(agent, message)` and
    `close_agent(agent)` for the live children (`assigns.children`), and the prompt says
    the report comes back as a message — *do not wait*. Limits `max_depth:` (2) /
    `max_children:` (4): at the limit `spawn_agent` is not offered and the prompt says
    why. A second child of one role is `researcher-2` (`role_of/1` strips the suffix on
    a revived row). The kernel runs a child with `role:` + `depth:` (assigns too) and
    the loader mounts the role's description on top of the project's. **Longx ships no
    roles** (a starter set was built and removed — the user's rule: roles grow in the
    project, never come from the kernel): with nothing declared `spawn_agent` is not
    offered and the plug's prompt says how to declare one — `local/agents/<name>/agent.exs`
    + `prompt.md`, loaded at the next step — and the person promotes a proven one to
    `shared/`. **Goal mode is `Plugs.Goal`**
    (default pipeline): `create_goal` / `update_goal` / `get_goal`; the goal lives in
    the kernel (`Agent.set_goal/2`, `get_goal/1`, `clear_goal/1`, restored from the
    ThreadState meta on a restart; `thread/goal/updated` / `cleared` so `GoalBar` and
    `/goal` work — `Projects.set_goal` / `clear_goal` dispatch to it on native threads),
    every model call is charged to `tokensUsed`, and at `:turn_end` an `active` goal
    continues the turn with a continuation step naming the objective (`step.state`
    counts the rounds) until the model marks it complete, the budget is spent or
    `max_rounds:` (8) passed — then the `{:goal, attrs}` effect (`Step.goal/2`) marks it
    `blocked` instead of looping.
  - **A tool may ask the person to act — `Longx.Agent.Context.ask/2`** (an agent's own
    COROS login plug printed an OAuth link into a terminal block and listened on the
    *server's* loopback port for the redirect: nothing told the person, and the browser
    on another machine hit its own 127.0.0.1). `ask(ctx, title:, text:, url:, fields:,
    callback:, timeout:)` blocks the tool's task on `Agent.ask/2` (`GenServer.call`,
    `:infinity`); the kernel keeps `asks: %{id => %{from, timer, callback?}}`, puts a
    `longx/action/request` request on the thread (`ThreadState.put_request`: `itemId`,
    `title`, `text`, `url`, `fields`, `callbackUrl`) and replies when the person answers
    (`Agent.respond/3` ← `Projects.answer_request/3` ← RPC `answer_request` — the same
    action codex's `requestUserInput` answers use; `%{"cancelled" => true}` is
    `{:error, :cancelled}`, `%{"done" => true}` or the typed fields `{:ok, map}`),
    times out (`timeout:`, 10 min) or the turn ends (`cancel_asks/1` in `end_turn`).
    **`callback: true`** registers the ask in `Longx.Agent.Registry` under `{:ask, id}`
    (`Longx.Agent.Asks`) and hands the tool `<public url>/callback/<id>` (`url:` may be a
    function of it); `LongxWeb.CallbackController` (`GET /callback/:id`, no CSRF) delivers
    the query as `{:ok, %{"query" => params}}` and shows a "回到 Longx" page, 404 for a
    stale id. **The public URL** — `Longx.System.public_url/0`: the `public_url` setting
    (Settings → Agent 内核 → 外部访问地址; RPC `public_url` / `set_public_url`), else
    `LongxWeb.Origins` (the scheme/host/port the last browser's socket connected with,
    `connect_info: [:uri]` in the endpoint, remembered in `UserSocket.connect`), else
    `Endpoint.url()`. The client: `messages.ts` makes the request a standalone `action`
    part (`ActionTool` in the toolkit: a link button + the `elicitation-form` with
    已完成 / 取消 or the fields, answered through `extras.answerAction` — raw, unlike
    `answerRequest`'s codex shape), the rail says 等待你操作, the Tracker pushes it as
    an `approval` notify event (title 等待你操作), and `terminal-block` makes URLs in
    output clickable. The plug reference says: ask, never print a link and poll; never
    listen on a local port for a redirect.
  - **Effects are what a plug asks the kernel to do**, data on the step the kernel
    interprets after each phase: `Step.enqueue_call/3` (`:response`; a synthetic
    `function_call` with a `longx_` call id, run with the model's), `Step.continue/2`
    (`:turn_end`; another step with that text — a user message — instead of ending),
    `Step.compact/2` (`:request`; fold the context first), `Step.halt/2` (end the turn,
    `failed` with the reason), `Step.spawn/4` (any phase; a child agent, above). `step.usage` (`last` / `total`) and `step.context_window`
    let a plug judge the context; `step.calls` are the model's calls at `:response`.
  - **Events are codex's vocabulary**, fed to `Longx.Codex.ThreadState.ingest/3` on the
    same topic (`turn/started`, `item/started`, `item/agentMessage/delta`,
    `item/reasoning/summaryTextDelta`, `item/commandExecution/outputDelta`,
    `item/completed`, `thread/tokenUsage/updated`, `turn/completed`, a `contextCompaction`
    marker): the channel, the store, `messages.ts`, the toolkit and the Tracker (turn rows,
    previews, the notify feed, the stall watchdog) are shared with codex unchanged. A
    tool's `show` decides the item: `:command` → `commandExecution`, `:file_change` →
    `fileChange` (with a unified `diff` per change), `:tool` → `dynamicToolCall`.
  - **The tool set is codex's, by name and parameters** — models tuned for codex call
    them as they know them: `exec_command` (`Plugs.Shell`: `cmd`, `workdir`, `tty` (a pty
    through the shim), `yield_time_ms` (accepted; the command runs to completion here —
    `timeout_ms`, default 2 min, max 30 min — `write_stdin` sessions are not offered yet),
    `max_output_tokens`, `shell`, `login`; stdout+stderr interleaved, head+tail kept, the
    exit code reported), `apply_patch` (`Plugs.Patch` over `Longx.Agent.Patch`: codex's
    patch grammar parsed and applied in Elixir — all hunks matched first, then written;
    exact, then trailing-whitespace, then surrounding-whitespace matching; a `function`
    tool with the patch as `input` everywhere, and for a provider of `kind: :openai` the
    same tool as a grammar-constrained `custom` tool (`Tool.freeform`, the lark grammar
    from `priv/agent/apply_patch.lark`; `Longx.Agent.Model` swaps it in, the kernel reads
    `custom_tool_call` items and answers `custom_tool_call_output`) — codex's instructions
    from `priv/agent/apply_patch.md`), `view_image` (an `input_image` user message after
    the result). There is no `read_file` / `list_dir` / `grep_files` — codex 0.154 has
    none either: reading is `exec_command` (`cat`, `sed -n`, `rg`).
  - **The base prompt is codex's, trimmed** (`priv/agent/base_prompt.md`, from the
    vendored `priv/codex_prompt.md`: sandbox / approvals / plans / AGENTS.md sections out,
    our tool names in, "reply in the user's language" added, a **"Where you work"**
    section: the project is the working directory, do not explore the home directory,
    other projects or Longx's own source — a model asked to "start an agent" before the
    tool existed went hunting through `~` and Longx's repo for a way).
  - `Longx.Agent.Transcript` (Ash domain) / `Longx.Agent.Item` (`agent_items`): the
    append-only log — every Responses input item (`input`: user / assistant message,
    reasoning, `function_call`, `function_call_output`, `compaction`) with its UI item
    (`ui`) and `seq` / `turn_id` / `model`. The model's context is `Transcript.input/1`:
    from the last `:compaction` boundary, the user's own messages before it verbatim
    (newest first within `keep_user_bytes`, 80 KB ≈ codex's 20k tokens), the summary, then
    everything after; a `function_call` left without an output gets a synthetic
    "interrupted" output. A boot replays the `ui` items through `ThreadState.backfill`
    (synchronous); a retract is a truncation; `delete_thread` / a project delete drop it.
  - **Descriptions: `Longx.Agent.Config`**, data evaluated before anything runs, the
    same format in every layer (`Longx.Agent.Loader`): the shipped default
    (`Longx.Agent.Pipelines.Default.config/0` — Environment, Base, Shell, Patch,
    ViewImage, Knowledge, WebSearch, Browser, Agents, Goal, Request), the person's
    `<data>/agent/agent.exs` (`config :longx, Longx.Agent.Loader, global_dir:`), the
    project's **shared** tree (`<root>/.longx/agent.exs` + `shared/{agents,plugs,knowledge}`;
    the flat `plugs/` / `knowledge/` of before count as shared) and its **local** tree
    (`.longx/local/` — `agent.exs`, `agents/`, `plugs/`, `knowledge/` — gitignored:
    `Longx.Agent.Layout.ensure_ignored/1` on every local knowledge write, `Git.Ignore`'s
    default; `promote/2` moves a local file into shared — `Projects.promote_local/2`,
    RPC `promote_local`, the project settings' 提升到 shared). `import Longx.Agent.Config;
    agent do version 1; extends :default; model "…", effort: "…"; prompt "…"; prompt_file
    "prompt.md"; summary "…"; agents ["researcher"]; plug Deploy, after: Shell; options
    Shell, timeout_ms: …; drop Base end` — a description records the **difference** to the
    layer below (`Config.resolve/2` applies the ops; a short name means the shipped plug,
    `Config.builtin/1`), so a release that changes the shipped pipeline reaches every
    project; an explicit `pipeline do … end` replaces the base and freezes it. `version`
    is the format version (`current_version/0`, `outdated?/1` → a notice). The DSL words
    are paren-free in `.formatter.exs`.
  - **The loader**: a layer is `agent.exs` + `plugs/**/*.exs` + its **roles**
    `agents/<name>/agent.exs` (each a description with its `prompt.md`, its own
    `plugs/`; no shipped layer of roles); the `.exs` code is data first — every `defmodule` of a layer and every
    reference to it is renamed under `Longx.Agent.Local.<tag>` (the project id; the local
    tree shares the project's namespace and sees its modules) before
    `Code.compile_quoted`, so two projects may both define `Deploy`; cached per layer by
    the files' mtimes and sizes, recompiled on change, modules no longer defined
    `soft_purge`d; a file that fails to load leaves the layer below in force and becomes a
    **notice** the kernel puts in front of the model (`⚠ … failed to load …`), as does an
    outdated version, a missing prompt file and a plug the description names but nobody
    defines — an agent that broke its own definition fixes it next turn. `load(root,
    agent: "researcher")` is the role's pipeline: the main stack (global → shared →
    local) with the role's declaration on top — the **last layer's declaration replaces**
    the earlier (a local `researcher` stands in for the shared one); `agents` lists
    every declared role with its summary, `allowed` whom the loaded agent may spawn (nil =
    all), an unknown role is an error. The **settings layer** goes on last
    (`settings:` — `Longx.Agent.Settings.for_project/1`, handed to the kernel as a
    function read per turn like `trust:`): `options Agents, max_depth/max_children`, the
    default child model for a role that names none, the reviewer model for the `reviewer`
    role; `overrides:` takes one more `Config`. `Project.trust_local_agent` (default
    false; the settings page's switch, `Projects.agent_definition/1` / RPC
    `agent_definition` list the files, the local files, the roles, the resolved plugs,
    the effective settings and the errors) gates the **shared** tree only (`agent.exs`,
    `shared/`): that code came with the clone, so a cloned repo executes nothing until
    the person looked. **`local/` always loads** — it is gitignored, this machine's, what
    the agent itself wrote (an agent that already runs commands as the person gains no
    new power from it); gating it too left a declared researcher invisible on an
    untrusted project, the model saying "no spawn_agent here" for three turns.
    `Plugs.Local` is mounted for every project, `.longx` or not (`trusted:` option:
    untrusted, it says the shared tree waits for the switch), and **lists the models
    the agent may name** (`# Models`: slug, name, provider, levels, default level, the
    default — `Longx.AI.model_choices/0`, handed to the kernel as `models:`, a function
    read per step like `trust:`; `assigns.models`). A description naming a slug Longx
    does not have (a model wrote `model "qwen-max"` and the next turn failed with
    "unknown model") is a **notice** naming the known slugs, and the default model runs
    (`description_model/3`); the person's own choice for a turn always stands — and the
    composer **shows the description's model as the one in force** on a native thread
    that picked none (`definitionModel` in `useCodexRuntime`, `TurnBar`'s `current`): a
    turn went to Bailian's qwen while the rail said deepseek-flash, and the person
    thought the DeepSeek quota had failed. **Tiers and aliases — `Longx.AI.Aliases`**:
    `ultra` / `pro` / `plus` (旗舰 / 高级 / 普通, always there; unmapped = the
    default model) and any alias a team agrees on (青龙 …), each a **chain** of slugs
    (one `Longx.System.Setting`, `model_aliases`; `put/2` validated — a word, not a
    slug, models known; a tier is emptied, never deleted). `Longx.AI` sees through them:
    `resolve_target/1` the first model, `resolve_targets/1` the whole chain (models
    whose provider has no key skipped), `fetch_model/1` the first model under the
    alias's own name (so `thread_options`, `check_effort`, the Thread row's `model_slug`
    all take a tier), `model_choices/0` lists them first with `alias: chain`; the
    prompt's `# Models` names tiers and aliases before the concrete models and tells
    the agent to prefer them ("survives a change of provider"). The composer offers
    them as options (a section of their own, the shell pick's too); Settings → 模型
    has the 档位与别名 card (RPC `model_aliases` / `set_model_alias` /
    `delete_model_alias` on `Longx.AI.Model`: three slots per name — the model used, two
    fallbacks — a tier without a delete, an alias added by name). It is what the agent is told
    about its own definition (write to `local/`, the person promotes; a custom tool is
    two files — `local/plugs/<name>.exs` + `plug <Module>` in `local/agent.exs`, live at
    the next step, a broken file back as a notice), with the compact API reference
    `priv/agent/reference.md` (= the body of `priv/agent/knowledge/writing-plugs.md`).
    `Longx.Agent` loads per step when no `pipeline:` module is given (tests give one); the
    description's `model` / `effort` stand where the person chose none.
  - **Settings → Agent 内核 (`Longx.Agent.Settings`)**: `max_depth` (2), `max_children`
    (4), `idle_minutes` (30), `child_model` / `child_effort`, `reviewer_model` /
    `reviewer_effort` — one `Longx.System.Setting` (`agent_kernel`, JSON) for the global
    values (`global/0`, `put_global/1` validated per field — counts ≥ 1, models the
    gateway knows, levels they offer; nil clears a key), `Project.agent_settings` (an
    untyped map column, `Validations.AgentSettings`) for a project's overrides,
    `for_project/1` the merge (`idle_ms/1` → the agent's `idle_ms:`). RPC
    `agent_settings` / `set_agent_settings` and the person's global agent files
    (`Longx.Agent.GlobalFiles`: `agent_files` / `agent_read_file` / `agent_write_file` /
    `agent_delete_file`, `.exs` and `.md` under the global dir, knowledge excluded) on
    `Longx.System.Status`; the page `settings/AgentKernelSection` (the
    `AgentSettingsFields` form shared with the project settings' overrides card, where an
    empty field inherits and the placeholder shows the value in force; a file editor
    like the knowledge page's with templates for a role and a plug). Hooks in
    `core/agent.ts`.
  - **Knowledge instead of memory — `Plugs.Knowledge` over `Longx.Agent.Knowledge`**:
    markdown files with front matter (`title`, `summary`, `tags`, `always: true`) in four
    roots — `longx/` shipped read-only (`priv/agent/knowledge/`: writing plugs, the
    description format and its versions — how a release guides the agent to update its
    own pipeline), `global/` the person's (`<data>/agent/knowledge/`, a git repository, a
    commit per write under a lock), `project/` the shared tree (`.longx/shared/knowledge/`,
    the flat `.longx/knowledge/` read too; committed with the code by the turn's
    bookmarks — what the person reviewed), `local/` (`.longx/local/knowledge/`, gitignored;
    **where the agent writes by default**). **Two levels**: a doc lives in a topic
    (`<root>/<topic>/<name>.md`; a top-level write is refused with the rule), the index
    folds to one line per topic (`root/topic/ (N docs) — README's or first doc's title:
    summary`; flat docs of before listed one by one), and a topic path reads as its
    docs (`knowledge_read("local/deploy")`). Always-docs go into every prompt
    (`always_cap:` 16 KB, the rest named for `knowledge_read`), the index capped
    (`index_cap:` 200 entries); tools `knowledge_read`, `knowledge_search` (every word,
    titles and summaries included, 50 lines), `knowledge_write` (front matter and a
    topic required; `longx/` refused; paths stay inside their root; a local write keeps
    `.longx/local/` in `.gitignore`); `promote/2` moves a local doc into shared. The
    prompt tells the model to write what is durable, into `local/` unless the person
    asked to share, and to prefer improving a doc over adding one. AGENTS.md is **not** read here — `Plugs.AgentsMd` still exists but is out
    of the shipped pipeline; a project that wants it adds `plug AgentsMd`. Skills are
    docs (a how-to is a doc), no loader of their own.
  - **Web search and reading pages** are two plugs. `Plugs.WebSearch` (`mode:` `:auto` /
    `:hosted` / `:standalone` / `:off`): *hosted* when the model's provider searches on
    its side (`Longx.AI.web_search_mode/1` — OpenAI, 百炼 Qwen 3.5+ / DeepSeek-v4 /
    glm-5.2; the model dialog's 联网搜索) — the request carries codex's `{"type":
    "web_search", "external_web_access": true}` through `Step.raw_tool/2` (provider-run
    tools go into `"tools"` as they are) and no function; the kernel turns the provider's
    `web_search_call` output items (codex's `action`: `search` with `query` / `queries`,
    `open_page` with `url`, `find_in_page` with `pattern`) into `webSearch` rows and hangs
    the following message's `url_citation` annotations on the last one as `results`; the
    item is kept in the transcript (`:hosted_call`) and `Gateway.prepare` drops
    `web_search_call` items for a target that does not search (an unknown item type
    there) — *standalone* for every other model: `web_search(query, recency_days,
    domains)` over `Longx.AI.Search` (Tavily; no provider → said inside the result). The
    thread's 联网搜索 switch reaches the kernel as `web_search:` → `assigns.web_search`;
    `false` mounts nothing. `Plugs.Browser` is `web_fetch(url, format, selector)` in every
    mode — obscura through `Longx.Tools.Builtin.BrowserFetch`, markdown by default — since
    a provider that searches still cannot read the URL the person named. Both show as
    `webSearch` rows (`show: :web_search`: `search` / `openPage` actions, `results`).
  - **Compaction, codex's shape** (`Plugs.Compaction`, policy; the kernel, execution):
    the plug asks (`Step.compact/2`) when the context after the last step passed `at:`
    (0.9, codex's 90 %) of the window, when the provider refused the request for its
    length (the kernel sets `assigns.context_overflow` and re-runs `:request` once), or
    when asked — the model through `new_context_window` (a tool result's `"compact" =>
    true`), the person through `/compact` (`Agent.compact/1`: at once when idle, before
    the next step when running; `Projects.compact_thread` on a native thread); it also
    offers `get_context_remaining` (from `Context.usage` / `context_window`). The kernel
    then streams a summary from a task (phase `:compacting`; codex's
    `priv/agent/compact/prompt.md`, request kind `compaction` in the log, no tools),
    appends a `:compaction` item whose input is codex's `summary_prefix.md` + the summary
    as a user message, emits the `contextCompaction` marker, reloads the context from
    the transcript (user words verbatim + summary), clears the usage and continues the
    step. A failed summary: the step goes on without folding, or fails the turn when the
    provider had refused the length.
  - `Longx.Agent.Model` — the streamed call, in a task. **`prepare/1` runs in the kernel's
    own process** (`Longx.AI.resolve_target/1` — `longx` = the default model —,
    `Gateway.prepare/2`, the `Gateway.Log` entry) and the task only `run/3`s the prepared
    request: a task killed mid-query (an interrupt, a parent stopping, a test's sweep)
    took the shared SQLite connection down with it and the next write anywhere said
    "Database busy" — a flake that only showed with several agents per test.
    `stream/3` = both, for tests. `prepare/1` resolves the request's name to the
    **chain** (`AI.resolve_targets/1`) and prepares every model of it; `run/3` streams the
    first and, when it never got going — a 429 that is a **quota gone** (`quota|exhaust|
    insufficient|balance|credit|billing…`, no retry: a retry never brings a quota back),
    a 4xx, retries spent on a 5xx / real 429 (`[5, 15, 30]` s now) — moves to the next,
    telling the kernel `{:fallback, from, to, why}`, which the kernel shows as codex's
    `model/rerouted` (the client's toast); the last model's failure names the model and
    provider (`qwen3.8-max (bailian-token-plan-team): upstream answered 429: …`).
    Preparation is reasoning items sanitised per
    provider, the output cap — the same path codex's requests take —, the `custom` tool
    swap for `:openai`; then a `Limiter` slot, a `Gateway.Log` entry (Settings → 请求记录 shows
    native requests too, `request_kind` `agent` / `compaction`), `Longx.Agent.SSE` →
    `{:item_added | :text_delta | :reasoning_delta | :reasoning_text_delta | :item_done |
    :completed | :failed}`. 429 / 5xx / transport errors before anything streamed are
    retried (`config :longx, Longx.Agent.Model, retry_ms:`, `[10, 10]` in tests); a 4xx
    is final; the task monitors its owner and dies with it.
  - `Longx.Projects` dispatches on the engine: `start_thread` (`start_native_thread`:
    `Longx.Agent.ensure` with `trust:` — a function read per turn — + the row +
    `Tracker.track`), `send_message` (`send_native`: the Turn row **first**, with a
    generated `turn_<uuid>`, then `Agent.send`; `{:error, :turn_in_progress}` while one
    runs), `steer_message`, `interrupt_turn/2` (the Thread action and the stall watchdog
    go through it for both engines), `retract_turn`, `compact_thread`, `host_thread`
    (starts the agent again after a restart — `ThreadChannel`'s join path),
    `delete_thread`, `list_skills` (`[]`) and `search_files` (a walk of the tree, the
    query as a subsequence) without codex; `review_thread` / `redo_turn` answer
    `{:error, :not_supported}`. The client: `ProjectWindow` hands `engine` to
    `ChatProvider` → `useCodexRuntime` → `useChat().engine`; the composer rail and the
    status strip say "原生内核" instead of the mode picker / codex state; the project
    settings show the definition (`settings` `AgentSection`, `useAgentDefinition`) with
    the trust switch, in place of codex's skills list.
  - **A message typed while a turn runs is queued, the Codex app's way** (client):
    `useCodexRuntime` gives assistant-ui `createMessageQueue` as the runtime's queue
    (`notifyBusy` / `notifyIdle` from the view's running turn; the host subscribes to
    the controller and bumps a `queueVersion` into the adapter memo — the runtime only
    re-applies a *new* adapter object, and the store reads the lanes from it), so a
    send while running lands in the queue and goes out as a new turn when the turn ends;
    `elements/message-queue.tsx` (the registry element, ours) stacks the items above
    the composer (`ComposerQueue` slot of `thread.aui`) with 取消 (`QueueItemPrimitive.
    Remove`) and 插入 — `insertQueued` → RPC `steer_turn` into the running turn now,
    off the queue (a send while running sits in the *steer* lane; `insertQueued` looks
    in both). The composer has **one** action button: send (a turn; 加入队列 while one
    runs) when there is text, stop while a turn runs and the draft is empty.
  - **Knowledge in Settings** (设置 → 知识, `settings/KnowledgeSection`): the person's
    global docs listed, edited in the CodeEditor (a save is a commit), created from a
    template, deleted with a confirm; Longx's shipped docs read-only. RPC on
    `Longx.System.Status`: `knowledge_docs` / `knowledge_read` (`trim?: false` — Ash
    trims strings) / `knowledge_write` / `knowledge_delete` over
    `Longx.Agent.Knowledge.global_docs/0`, `read_raw/2`, `write/3`, `delete/2`
    (`knowledge_rpc_test`). A page read (`web_fetch`, an `openPage` action) renders as
    one link row (`ReadPage` in the toolkit), not the search element.
  - Tests: `test/longx/agent/` (`pipeline_test` the DSL and phases, `config_test`,
    `loader_test` (namespaces, reload, notices, trust), `knowledge_test`,
    `web_search_test` (Tavily by Bypass, the fake obscura), `patch_test`,
    `sse_test`, `plugs_test` runs real bash, `transcript_test`, `model_test` and
    `agent_test` with Bypass as the model — a held reply for steer / interrupt / retract,
    `Bypass.pass/1` after a reply the interrupt cut off, a restart rebuild, effects, the
    step limit, the loader mode, compaction by effect / overflow / hand, the team:
    spawn / report / crash / idle exit / `spawn_agent` through the shipped plug / goal
    mode), `settings_test` (the settings layer, promotion), `test/longx/projects/native_engine_test`
    (through `Projects`, the Tracker completing rows, the trust switch, a child's row),
    `test/longx_web/rpc/agent_settings_rpc_test`. No codex process anywhere in it.
- `lib/longx/platform.ex` — `Longx.Platform`: runtime-safe os/arch detection and the Rust
  triple / GOOS-GOARCH naming for it. Anything that resolves a binary path at runtime goes
  through this, never through `Mix.*` (Mix is absent in releases).
- **Model access is inverted: codex talks to *our* AI gateway, never to a vendor.**
  - `lib/longx/ai/` — Ash domain `Longx.AI`: `Provider` (base_url + `api_key` encrypted at
    rest via `AshCloak` + `Longx.Vault`; key from `LONGX_CLOAK_KEY` in prod, fixed keys in
    dev/test config; `kind`, derived from the base_url unless given —
    `Provider.kind_for_base_url/1`; `request_timeout_ms` (default 10 min) and
    `max_concurrent_requests` (nil = unlimited) that the gateway enforces; `last_error` /
    `last_error_at` / `last_checked_at` written by `check_model/1` and by the gateway on
    upstream 401/403) and `Model` (`upstream_id`, `slug`, `context_window`, one `default`,
    `reasoning_levels` (the efforts the model offers, ordered — DeepSeek / GLM
    `low / high / max`; codex's `ReasoningEffort` is any non-empty string, so a row with
    no levels takes free text), optional `reasoning_effort` (the default level, one of
    the levels when declared — `Model.Validations.EffortInLevels`), `reasoning_summary`
    (codex's enum) and `max_output_tokens`).
    `Longx.AI.resolve_target/0` = default model + its provider's decrypted key.
    **Presets** (`Longx.AI.Presets`, pure data + `apply/2`): DeepSeek, GLM, 阿里云百炼
    Token Plan (个人版 / 团队版) and OpenAI with endpoint / kind / hosted search / key env
    + url / docs url and their models (window, levels, default level, image input,
    recommended, per-model `hosted_search`) — DeepSeek's and GLM's from the `models.json`
    each publishes for codex, Bailian's from the `model-catalog.local.json` on its Codex
    page (one endpoint for both plans, `…/compatible-mode/v1`, Responses API, plan-specific
    keys; the team plan lists nine models more; Coding Plan is chat-only and out;
    pay-as-you-go needs a WorkspaceId in the URL → a custom provider), OpenAI's from the
    catalog embedded in the pinned codex binary (`strings` it for
    `supported_reasoning_levels`). **Any provider's own list**: `Longx.AI.discover_models/1`
    asks `GET <base_url>/models` (OpenAI's standard: `data[].id`; OpenRouter adds `name`,
    `context_length`, `reasoning.supported_efforts` / `default_effort` and the input
    modalities, a plain gateway like listenai only `id` + `owned_by`) and normalises each
    entry (window, levels in codex's order, default level, image input, `installed` for ids
    the provider has a row for); RPC `discover_models` on `Provider` (`ok` / `error` /
    untyped `models`, never a failure), the provider menu's 从接口获取模型 → `DiscoverDialog`
    (the `model-picker` checklist with a filter, picked entries → `create_model` with what
    the list said). `apply/2` is
    idempotent (provider by slug — facts refreshed, a key never dropped; models by
    `upstream_id` — a person's edits kept, a row without levels learns the preset's, a row
    on a smaller set of the preset's levels gains the ones added since (DeepSeek's are
    `none / low / high / max` per its 思考模式 docs, Responses format `reasoning.effort`,
    `none` = thinking off, default `high`; minimal / medium / xhigh / ultra are aliases the
    API maps down); a
    slug another provider took gets `<provider>-` prefixed) with `models:` (ids /
    `:recommended` / `:all`) and `make_default:`. Over RPC via the data-less
    `Longx.AI.Preset`: `list_presets` (each with `installed` / `provider_id`, models
    flagged `installed`; the model maps are untyped → camelCased there) and
    `apply_preset`. Seeds (`priv/repo/seeds.exs` → `Longx.AI.Seeds`, run by
    `mix ash.setup`/`mix test`, never by a release) apply the DeepSeek preset without a
    key (`deepseek-flash` the default when nothing is) and the OpenAI provider alone —
    keys are entered in Settings, not read from the environment. Columns added
    after rows existed get a backfill migration (`kind` for api.openai.com rows, `slug` from
    `upstream_id`) — a new NOT NULL column needs a `default:` in the migration (SQLite).
  - **What codex is told about a model** comes from the row, per thread:
    `Longx.AI.thread_options/1` (slug or nil for the default → `model:` only when explicit,
    `model_context_window:`, `reasoning_effort:`, `reasoning_summary:`, `web_search:`) is
    what `Longx.Projects.start_thread/2` and fork pass to `Longx.Codex.Thread.start/1`, which
    turns them into `thread/start.config` overrides — the same dotted keys as `codex -c`
    (`model_reasoning_effort`, `web_search`, `features.standalone_web_search`, …; verified
    against the bundled binary in `gateway_e2e_test`). `turn_options/1` (`model:`, `effort:`,
    `summary:`) goes on `turn/start` when a turn switches models. **The level is chosen
    per turn**: `start_thread(effort:)` / `send_message(effort:)` / `redo_turn(effort:)`
    (RPC `effort`; `AI.check_effort/2` refuses a level the model does not declare — an
    argument error on the wire, like an unknown model now) — `Thread.reasoning_effort`
    is the level in force (start: chosen or the model's default; a turn that changes it
    sends `turn/start.effort`, which codex keeps for the turns after — verified in
    `gateway_e2e_test`; a resume passes the thread's level, not the row's), and
    `Turn.reasoning_effort` what each turn ran with. The catalog entry carries
    `supported_reasoning_levels` / `default_reasoning_level`, so a levels edit turns the
    strip amber (`stale: [:models]`). `max_output_tokens` is not
    a codex knob any more: the gateway puts it on the Responses request when codex sets none.
    Unknown slugs are refused in `Longx.Projects` before codex is involved. Not covered:
    config overrides are per thread, so a mid-thread model switch (`redo_turn` in revert
    mode) changes effort/summary but keeps the first model's context window and search mode.
    **The context window has two halves.** The per-thread `model_context_window` override
    is what codex reports (×95% "usable", `thread/tokenUsage/updated.modelContextWindow`)
    and compacts against — but codex clamps it to the model's `max_context_window`, and for
    a slug it does not know (every model behind our gateway) its fallback metadata says
    272k. So `Longx.Codex.Home.prepare/1` also writes **`model_catalog.json`**
    (`model_catalog_json` in config.toml): one entry per `Longx.AI.Model` slug plus the
    `longx` placeholder sized as the default model, each in codex's own fallback shape
    (unified-exec shell, byte truncation, `priv/codex_prompt.md` as base instructions —
    the prompt vendored from the pinned release; the `:integration` suite checks the
    bundled binary embeds it verbatim, so a codex bump that changes it fails there) with
    `context_window` / `max_context_window` from the row. The catalog (and config.toml) is read
    once, when a codex process starts, so an edit is deliberately **not** applied live:
    `codex_info.stale` (`Home.stale/2`: the files on disk vs what `prepare/1` would write
    now — `models` for a window edit or a new model, `config` for the search mode) turns
    the status strip amber ("codex 需要重启", click → the process tool, which names the
    reason next to its restart button); the person restarts when no turn matters. Both
    the real launch and the test fake's go through `Home.prepare/1`, so the check works
    in the suite. `Projects.resume_thread/2` (the pool's lazy resume and the Tracker's
    resume after a codex death) passes the same overrides as a start, so old threads get
    the row's current window on their next resume — verified against the real binary in
    `gateway_e2e_test` (start 128k → 121 600 reported; resume 1M → 950 000). Seeds give
    `deepseek-flash` 1M (DeepSeek V4 Flash) and lift a row still on the old 128k default.
  - **Provider health / limits**: `Longx.AI.check_model/1` sends one tiny non-streaming
    request (16 output tokens, 30 s) and records the outcome on the provider. In the gateway,
    `Longx.AI.Gateway.Limiter` (ETS counters, in the supervision tree) caps in-flight
    requests per provider → 429 + `retry-after: 1` (codex backs off and retries, like an
    upstream rate limit); an upstream that stays silent past `request_timeout_ms` → 504;
    401/403 → `record_provider_error`.
  - **Every gateway request is remembered — `Longx.AI.Gateway.Log`** (in the tree; an ETS
    ring of the last 1000, `config :longx, Longx.AI.Gateway.Log, keep:`): `begin(body,
    target)` at the controller's door (thread / turn / `request_kind` from codex's
    `client_metadata` + `x-codex-turn-metadata`, the model name and what it resolved to,
    `reasoning.effort` / `summary`, the tools' names, input items and size, instructions
    size, `max_output_tokens`), `finish(id, %{status, error})` after the relay — refused
    requests included (unknown model → 400 with the message). RPC `gateway_requests(limit)`
    on `Longx.System.Status`; Settings → 请求记录 (`settings/RequestsSection`, polled every
    5 s, a row per request with the details behind a click). It is how to check what codex
    actually asked for: verified on this box that the level picked in the composer is the
    `effort` of the turn's request (`max` → `max`, `low` → `low`); a sub-agent's request can
    carry a level the *model* chose in `spawn_agent` (or the model's default), a memory
    request codex's own `low` / `medium` — `request_kind` tells them apart.
  - `LongxWeb.AI.ResponsesController` at `POST /ai/v1/responses` (pipeline `:ai_gateway`,
    bearer = per-boot `Longx.AI.Gateway.Token`; **no `:accepts` plug** — codex sends
    `Accept: text/event-stream`). `Longx.AI.Gateway.prepare/2` swaps the placeholder model
    `longx` for the target's `upstream_id`, drops codex-internal fields, forces
    `stream: true`; **function and namespace tools pass through untouched** — DeepSeek
    accepts `type: namespace` tools (sub-agents, `web.run`) and returns `function_call` items
    with `namespace`, which is what codex's router keys on; which tools codex offers is
    decided in its config, never by filtering here. The one exception: the provider-hosted
    `web_search` / `web_search_preview` tool only exists inside providers with
    `supports_hosted_web_search`, so it is dropped for any other target rather than failing
    the request. `stream/2` relays the upstream SSE chunk-for-chunk with a
    **selective receive on the Req async ref** (a bare `receive` would eat the connection
    process's other messages). Upstream 4xx/5xx pass through so codex shows the message.
  - **Reasoning items never cross providers.** `reasoning.encrypted_content` is an opaque
    blob only its producer can read (OpenAI: real ciphertext; DeepSeek: a reference token).
    `Provider.kind` is `:openai` or `:openai_compatible` (default); `Gateway.prepare/2`
    lets an `:openai` target keep only its own `rs_`-prefixed items intact and strips
    `encrypted_content` from everything else; every other target gets **no**
    `encrypted_content` at all. Readable `summary`/`reasoning_text` stay; an item with
    nothing readable is dropped. When codex switches models mid-thread (`model:` per
    turn/fork) this is what keeps the history replayable. Degraded path: an `:openai`
    target answering 4xx about `encrypted`/`reasoning` gets **one** retry with
    `Gateway.strip_all_encrypted/1` (logged as a warning) — the conversation survives,
    only reasoning continuity is lost for that turn.
  - **Web search** has three modes, decided by `Longx.AI.web_search_mode/0` for the global
    default (written into codex's config by `Home.prepare/1`) and `web_search_mode/1` per
    model (a thread's `config` override, via `thread_options/1`) — pattern-matched on the
    resolved model target and search target, never an `&&`/`||` chain at the call site:
    `:hosted` when the model runs codex's standard `web_search` tool itself —
    `Model.hosted_web_search` when set, else the provider's `supports_hosted_web_search`
    (OpenAI; Bailian for Qwen 3.5+ / DeepSeek-v4 / glm-5.2, which answer with
    `web_search_call` items carrying the query and sources — verified live through codex —
    and refuse the tool for kimi-k2.x / MiniMax / glm-5 with "Agent capabilities are not
    enabled", hence per model; the model dialog's 联网搜索 select) (config
    `web_search = "live"`; the gateway passes the tool through, `external_web_access` and all),
    else `:standalone` — always: `open` needs no provider (below), and a `search_query`
    without one is told "no search provider" inside the output. `:disabled` is only ever an
    explicit choice: `Project.web_search` / `Thread.web_search` (a `thread/start` config,
    so decided when the thread starts — `start_thread(web_search: false)`, the project's
    default otherwise; the composer's mode picker offers it for a new chat only).
    **This is separate from the sandbox's network access**, which governs commands inside
    bubblewrap: `web.run` is executed by the Longx server, so "no network" for the agent's
    commands does not stop it reading a page through us — hence its own switch.
    The provider block always declares `supports_standalone_web_search = true` (a capability,
    not a switch); what a thread gets is `web_search` (`"live"`/`"disabled"`) +
    `features.standalone_web_search` — standalone needs `web_search = "live"` too.
  - **Multi-agent (codex sub-agents).** `Thread.start(multi_agent: true)` asks codex for its
    v2 collaboration tools (`features.multi_agent_v2`: `collaboration.spawn_agent` /
    `wait_agent` / `send_message` / …); `false` turns v1 and v2 off. `Project.multi_agent`
    is the default, `Thread.multi_agent` what the thread started with (a `thread/start`
    config, so a new-chat choice like web search). `[agents]` limits (4 concurrent per
    session, depth 2) come from `config :longx, Longx.Codex.Home, agents:`. **Sub-agents are
    threads**: codex runs each on its own thread id (no `thread/started`; its items arrive
    on that id) and reports on the parent with `subAgentActivity` (`agentPath` "/root/<name>",
    `agentThreadId`, `kind` started/interacted/interrupted/completed) and
    `collabAgentToolCall` (`tool`, `receiverThreadIds`, `agentsStates`, `prompt`, `model`).
    The Tracker turns a parent's first activity into a Thread row under it
    (`parent_thread_id`, `agent_path`, title = last path segment; hidden from the project's
    list, `list_subagents/1` / RPC `list_subagents`) and follows its topic, so a child has
    a ThreadState, a channel and a page like any thread. **The gateway rewrites the child's
    task**: codex hands it over as an `agent_message` item whose content is an
    `encrypted_content` part only OpenAI reads — `Gateway.translate_agent_messages/2` turns
    it into a plain user message for every other provider (without it every sub-agent
    started with an empty task). A child's approval is a request on the child's thread; the
    UI answers it through the parent (same connection, request id is what counts).
    `turn/plan/updated` (codex's `update_plan` tool — not offered to every model) is the
    thread view's `plan`.
  - **Goal mode (codex's `goals` feature, on by default)**: the model has `create_goal` /
    `update_goal` / `get_goal` (it only creates one when asked); with a goal `active`
    codex starts the next turn *by itself* whenever the thread goes idle, with a
    continuation prompt naming the objective, until the model marks it `complete`,
    it is `blocked` (three no-progress turns) or the token budget is spent. Longx:
    `Thread.set_goal/2` (`thread/goal/set`: `objective:`, `status:` `:active` | `:paused` |
    `:complete` …, `token_budget:` nil = none), `get_goal/2`, `clear_goal/2`;
    `thread/goal/updated` / `cleared` fold into the Store / `thread.ts` as the view's
    `goal`; **a turn codex starts on its own gets a Turn row** (Tracker on `turn/started`
    for an unknown id → `Projects.record_external_turn/2`: HEAD as `commit_before`, the
    tree's dirtiness, `user_text` "（目标续跑）<objective>", the thread `:active`) so the
    history, the restore points and the welcome page see it. RPC `set_goal` / `clear_goal`
    on `Thread`; the UI is `ui/chat/GoalBar` (`GoalProvider` in `ChatProvider` holds the
    dialog, `GoalBar` above the thread: objective, status, tokens / budget, elapsed;
    pause / resume / edit / clear) and the `/goal` command opens the dialog; `/goal <目标>`
    typed past the popover is caught in `adapter.ts`'s `onNew` and sets the goal instead of
    going out as a message. Proven on
    the real binary in `goals_skills_integration_test`.
  - **Skills**: codex loads `SKILL.md` files (`<cwd>/.agents/skills/<name>/SKILL.md`, the
    user's, the home's `skills/` incl. codex's own samples) and lists them in the prompt;
    the model reads one when relevant. `Thread.list_skills/2` (`skills/list` per cwd) →
    `Projects.list_skills/2` → RPC `list_skills` on `Project`; the composer's `$` popover
    (`ui/chat/SkillMentions`, the same `composer-trigger-popover` as `@`) writes `$name`,
    `core/chat/mentions.ts`'s `mentionFormatter` renders both `@file` and `$skill` chips and
    `skillsIn/2` turns the names in a sent message into `send_message(skills: [%{name,
    path}])` → `turn/start` `{type: "skill", name, path}` inputs (the SKILL.md text reaches
    the model — proven). Project settings list the skills found (`useSkills`).
  - **Thread-less notifications** ride `"codex:server"` as `{:codex_server, tag, method,
    params}` (tag = the project id under the pool). The Tracker asks each project's codex
    to watch its root once it is up (`fs/watch`, watch id = project id) and relays
    `fs/changed` as `Projects.broadcast_files_changed/2` → ProjectChannel `"files"` → the
    client invalidates the tree and git status (`invalidateFiles`); `configWarning` →
    `broadcast_notice/2` → `"notice"` → a toast (`deprecationNotice` is only logged); `model/rerouted`
    (thread-scoped) reaches the client as a signal (`useThreadView(_, onSignal)` →
    `ChatProvider` toast "模型已切换").
  - **The notify feed — `Longx.Notify`** (`lib/longx/notify.ex`): one event shape for what
    the person should hear about across projects, `%{kind, title, body, url, project_id,
    thread_id, at}` — `kind` `approval` (a request waiting on them: an approval, a
    permission, a question; `body` the command / reason) | `turn_completed` |
    `turn_failed` (the error, or "codex 退出了…" from the Tracker's `codex_down`) |
    `codex_down`; `url` is an SPA path, `/p/<slug>/t/<root thread id>` (a sub-agent's row
    points at its parent's page — `Projects.notify/3`, `thread_label/1`). The Tracker
    pushes them (root threads only for turn ends; every `*/requestApproval` /
    `requestUserInput` / elicitation event with a `requestId`). Delivery is
    `LongxWeb.NotifyChannel` (`notify` on the user socket): the join reply carries
    `running` (`Projects.running_threads/0`, `waiting` marked) so a client that was away
    sees the state, then one `"event"` push per event — what the Android shell's foreground
    service joins to raise notifications without FCM; APNs for iOS is the planned second
    leg with the same payload. `PubSub.broadcast(topic/0, {:notify, event})`. Dev aid: `config :longx, Longx.AI.Gateway, dump_requests_to:`
    writes what the model actually receives.
    Standalone = codex's `ext/web-search`: with the feature on codex offers a `web.run`
    namespace tool and,
    when the model calls it, POSTs the commands to `<base_url>/alpha/search` with the
    gateway bearer. `LongxWeb.AI.SearchController` → `Longx.AI.Search` executes them
    (`search_query`, `open`, `time`; the rest answer "not supported") against the default
    `Longx.AI.SearchProvider` (Tavily; key encrypted; seeded from `TAVILY_API_KEY`) and
    replies `{output, results}` — `output` goes to the model, `results` to the UI as a
    `webSearch` item. `Longx.AI.Search.Refs` (ETS) remembers `turnNsearchM` ids per codex
    session so `open` can resolve them. Config/key problems are reported inside `output`
    with 200, never as an HTTP error (codex would fail the tool call). OpenAI's hosted
    `web_search` tool is never emitted (`web_search = "disabled"` otherwise).
  - `apply_patch` on third-party models works through `exec_command` (codex installs an
    `apply_patch` helper on PATH under CODEX_HOME); our catalog entries declare no
    `apply_patch_tool_type`. DeepSeek's and GLM's own codex catalogs declare `freeform`
    (DeepSeek's Responses API accepts the `custom` apply_patch tool) — switching our
    entries to that is a separate, e2e-verified change, not done yet.
  - Upstreams are all OpenAI **Responses API** (codex 0.154 dropped `wire_api = "chat"`):
    OpenAI `https://api.openai.com/v1`, DeepSeek `https://api.deepseek.com/v1`, GLM
    `https://open.bigmodel.cn/api/v1` (its `/api/paas/v4` is chat completions), Bailian
    Token Plan `https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`. Adding
    a provider = a DB row, no code — `Longx.AI.Presets` has the ready-made ones;
    `bailian_live_test` (`:live`, `BAILIAN_TOKEN_PLAN_API_KEY`) drives the real endpoint.
  - `Longx.Codex.Home` writes our own `CODEX_HOME` (`data/codex_home`, prod
    `$LONGX_DATA_DIR/codex_home`; never `~/.codex`, never a tmp dir) with a generated
    `config.toml`: one provider `longx` → `http://127.0.0.1:<port>/ai/v1`,
    `env_key = LONGX_GATEWAY_TOKEN`, `requires_openai_auth = false` → **codex needs no
    login**; and `environments.toml` naming Longx's exec-server (above) when given
    `exec_server_url:` — `Pool.launch` always does, per project. `Home.prepare/1` returns
    the env to spawn codex with.
- **Commands run through Longx's own exec-server — `lib/longx/exec/`.** codex 0.154 routes
  every command and file operation of a thread through an "environment" (its
  `codex-exec-server` protocol: JSON-RPC over a WebSocket, codex's dialect without the
  `jsonrpc` field); `Longx.Codex.Home.prepare(exec_server_url:)` writes
  `<CODEX_HOME>/environments.toml` (`default = "longx"`, `include_local = false`, one
  `[[environments]]` with the url), so a project's codex never uses its built-in executor:
  approvals, `request_permissions`, execpolicy and the `commandExecution` items stay codex's,
  execution and the sandbox are ours. The url (`Home.exec_server_url/2`: the endpoint's
  loopback port, `/exec/<project id>`, the gateway token as `?token=` — codex sends no
  headers on a plain `ws://` environment; the file is 0600) is `nil` on Windows, where codex
  keeps sandboxing itself. `LongxWeb.ExecController` (`GET /exec/:project_id`) checks the
  token and upgrades to `LongxWeb.ExecSocket` (WebSock; pings every 30 s since codex sends
  no keepalive; traps exits — the commands are linked to it, a closed connection takes them
  down). `Longx.Exec.Session` is the protocol: `initialize` / `initialized` /
  `environment/info|status` (shell = the user's bash/zsh/sh, home, tmp dirs, every
  capability `false`), `process/start|read|write|signal|terminate`, `fs/*` (12 methods,
  handles for `open`/`readBlock`/`close`), `capabilityRoots/discoverV1`; anything else
  (`http/request`, `environmentConfig/read`) is `-32601`. Inline answers come back as
  frames from `handle/2`; reads that wait, walks and discovery run under
  `Longx.Exec.TaskSupervisor` and arrive as `{:exec_out, frame}`. Pieces, each pure and
  unit-tested (`test/longx/exec/`): `Longx.Exec.PathUri` (`file:` URIs, percent-encoded
  UTF-8 — project names are CJK); `Longx.Exec.Env` (codex's `envPolicy`: inherit
  all/core/none, excludes, `set`, `includeOnly`, then codex's overlay; **`*KEY*`, `*SECRET*`,
  `*TOKEN*`, `LONGX_*` and codex's non-inheritable names never reach a command whatever
  the policy says** — codex-local strips the first three too; the shim runs commands with
  `env_clear: true`, exactly that environment; **`Home.tool_bin/0` leads every command's
  PATH** (`tool_bin:` option): `<data>/codex_home/bin/apply_patch`, a symlink to the bundled
  codex binary that `Home.prepare/1` (re)points — codex dispatches on arg0, and its built-in
  executor made the same alias in a temp dir on *its own* PATH, which a command inherited
  there; under the exec-server a command inherits Longx's PATH, and `apply_patch` was
  "command not found" until 0.1.17 — proven in `exec_server_integration_test`); `Longx.Exec.Policy` (the request's
  `FileSystemSandboxContext` — `managed` with `entries` of special paths `root` /
  `project_roots(+subpath)` / `slash_tmp` / `tmpdir`, plain paths and globs, `disabled`,
  `external` — into writable roots, read-only pockets (`.git`, `.codex`), denied paths,
  network; `sandboxed?/1`, `allowed?/3` — an unknown shape is refused, never opened);
  `Longx.Exec.Sandbox` (policy → the wrapping command: **bubblewrap** with codex's own
  shape — `--ro-bind / /`, `--dev /dev`, the roots `--bind`, pockets `--ro-bind`, all
  namespaces unshared, `--cap-drop ALL`, `--unshare-net` when the network is off, `--proc` —
  plus `--dev-bind`/`--bind` for the project's passthrough, and **no seccomp stage**:
  codex's inner stage denies `connect` for every socket family with the network off, which
  killed local IPC (CUDA's driver socket on a DGX); here "no network" is the namespace alone,
  so a unix socket in the filesystem still works — proven on the real binary; **seatbelt**
  on macOS from codex's `.sbpl` files vendored in `priv/seatbelt/` (Apache-2.0, NOTICE) with
  `WRITABLE_ROOT_n` / `_EXCLUDED_m` params — unverified, no Mac here; `{:none, argv}` when
  nothing needs enforcing; no bwrap / another platform is an error, a command is never run
  open by accident); `Longx.Exec.Process` (one command over `Longx.Shim`: output, exit and
  close on one `seq`, notifications to the session, 1 MiB retained for `process/read` with
  `waitMs`, `write` deduped by `writeId`, `signal` = SIGINT to the group, `terminate` =
  the shim's tree kill; `sandbox_denied?/3` is codex's heuristic — denial words in the
  output or 128+SIGSYS, never on exits 2/126/127 — computed once the streams settle;
  `tty: true` runs the command on a pseudo-terminal — the shim's `pty:` option, Go
  `pty_{linux,darwin}.go` over `/dev/ptmx`, 80×24, stdin stays open, one `pty` stream);
  `Longx.Exec.Fs` (`fs/*` over `File`, each checked with `Policy.allowed?/3` first —
  apply_patch on a remote executor writes through these, so they are a sandbox boundary too;
  codex's error codes `-32004` not found / `-32600` refused / `-32603`); `Longx.Exec.Discovery`
  (`SKILL.md` + `agents/openai.yaml`, `.codex-plugin|.claude-plugin|.cursor-plugin/plugin.json`,
  `.mcp.json`, the nearest ancestor's manifest, codex's scan limits). `Projects.exec_context/1`
  gives the session the project's live sandbox options (passthrough) and shim guards
  (`Pool.oom_score_adj/0`, the memory cap) at every start. `exec_server_integration_test`
  (`:integration`) proves it on the real binary: cwd writable / home not, no network but a
  unix socket answers, a tty, a passthrough device visible from the next command with no
  restart. The bwrap PATH wrapper (`bwrapx`), `Home.prepare(passthrough:)` and the
  `:passthrough` stale reason are gone with it. Protocol source: `codex-rs/exec-server-protocol`
  of the pinned release (61 structs; a codex bump re-checks it through the integration suite).
- `lib/longx/codex/` — the app-server client, layered:
  - **One codex per project** — `Longx.Codex.Pool` (DynamicSupervisor + the
    `Longx.Codex.Registry`): `Pool.connection(project_id)` returns the project's connection,
    starting a `Longx.Codex.Worker` (a supervisor with its *own* budget: 3 restarts / 60 s,
    `restart: :temporary` under the pool) on first use, with `CODEX_HOME =
    Pool.home_dir(project_id)` = `<Home.default_dir>/<project.id>` (codex's sqlite and
    sessions live there; id not slug, so renames do not matter). A crash-looping codex kills
    only its worker; the next `connection/1` starts it afresh (`start/2` waits for a dying
    worker before starting a new one). `stop/2`, `restart/1`, `status/1`
    (`:stopped` | `Connection.info/1`), `running/0`. `config :longx, Longx.Codex.Pool,
    command:` (tests: the fake app-server, run inside the home with `FAKE_PERSIST=1` so it
    keeps its thread ids across restarts like codex does), `connection:` (extra Connection
    options; `home: [gateway_url: …]` for integration tests). codex treats
    `sqlite_home`/CODEX_HOME as local disk — WAL needs it; never NFS.
  - `Longx.Codex.Connection` (one per codex process): owns a `Longx.Shim` running
    `Runtime.executable/0` with `Home.prepare/1`'s env (`home_dir:`/`home:` options); a linked
    reader process feeds `{:rpc, msg}`; `initialize` → `initialized` handshake (calls made
    before `:ready` are queued); request/response pairing with per-request timeouts;
    notifications with a `threadId` go to that thread's `ThreadState`, the rest to PubSub
    `"codex:server"`; `{:codex_connection, tag, :ready | :down}` on `"codex:connection"`
    (`tag:` = project id, nil for ad-hoc connections). It **registers every thread it hosts**
    (`{:thread, id}` in the registry, from `thread/start|resume|fork` replies and from
    notifications) so `Longx.Codex.Thread` functions on an existing thread need no `conn:`
    (`Pool.connection_for_thread/1`; `start/1` and `resume/2` still do); `terminate/2`
    unregisters first, then broadcasts `:down`. Shim or reader death → pending callers get
    `{:error, :connection_reset}`, process stops with `{:shutdown, :codex_exited}` and its
    worker restarts it. `Longx.Codex.Framing` / `Longx.Codex.Message` are the pure wire pieces.
  - `Longx.Codex.Recycler` — every `tick` (5 min) it samples each running worker
    (`Connection.info/1`: tree `stats`, `turns` since start, `active_turns`, uptime) as
    telemetry `[:longx, :codex, :worker, :sample]` and **stops idle workers** past
    `max_uptime_ms` (12 h) / `max_rss_bytes` (2 GiB, whole tree) / `max_turns` (200), and
    **stops a worker nobody used for `idle_after_ms`** (30 min since its last turn ended —
    `Connection.info.last_turn_at` — or since it started; nil never): a project left for
    the day costs no memory, the next message starts its codex again and resumes the
    thread. Settings → codex 进程 (`settings/ProcessesSection`, RPC `list_codex_processes`
    on `Longx.System.Status` over `Projects.running_codex/0` + `Recycler.idle_after_ms/0`)
    lists every running codex with its RSS / pid / turns / threads / last use and stops
    an idle one (`stop_codex`, never forced from there) — the
    next use starts a fresh process (openai/codex#42738: a days-old app-server at 11 GB).
    A worker with a turn in flight is never touched. `Recycler.sweep/0` runs one now.
    `Pool.connection/2` takes `shim: [memory_limit: bytes]` (from `Project.memory_limit_mb`,
    optional, min 64, off by default — a big task may use all the memory it needs; the OOM
    ordering is what protects the BEAM); every codex tree gets `oom_score_adj: 500`
    (`config :longx, Longx.Codex.Pool, oom_score_adj:`). `Home.prepare/1` sets
    `TOKIO_WORKER_THREADS` (default 4, `config :longx, Longx.Codex.Home,
    tokio_worker_threads:`): codex builds its tokio runtime with the default builder, which
    honours it; its Linux musl build showed allocator lock storms with one worker per core
    (openai/codex#43170; 0.154 switched musl to jemalloc, the cap stays as belt and braces).
  - **Hard rules for codex's config** (`Longx.Codex.Home`): the generated `config.toml`
    enables nothing beyond the gateway provider and web search — no computer use, no
    `code_mode_host`, no `node_repl`/`js_repl`, no remote control, no MCP servers, no
    plugins: every process leak and runaway-memory report against the desktop app comes
    from those (openai/codex#43471, #44917, #35485, #38948). `data/` (CODEX_HOME, sqlite in
    WAL mode) must be a local disk — never NFS/SMB (#44950, #35217). Codex stays pinned
    (0.154.0); an upgrade is a pin change + `mix test --include integration` green, never
    an alpha.
  - `Longx.Codex.Sandbox` — the bubblewrap probe (the exec-server runs the same bwrap codex
    would have: system first, else the bundle's); bubblewrap needs unprivileged user
    namespaces (WSL1, most containers, hardened distros refuse → codex rejects every sandboxed
    command at turn time). `probe/0` runs the bundled `bwrap` at boot (a `Task` in the
    tree; non-Linux is assumed ok) **with codex's own flags** (`--unshare-user --unshare-pid
    --unshare-ipc`, `/proc` dropped when it cannot be mounted — codex's preflight does the
    same), then again with `--unshare-net`, which codex adds only for commands without
    network access: `status/0` is `:ok`, `:no_net_isolation` (containers, some VMs, GitHub
    runners: "loopback: Failed RTM_NEWADDR" — a project with network access on works, one
    without has every command refused; amber in the UI) or `:unavailable`. A namespace
    refusal while `kernel.apparmor_restrict_unprivileged_userns` is 1 (Ubuntu ≥ 24.04, e.g.
    a DGX Spark) is reason `:apparmor`, and the settings page prints the one-line AppArmor
    profile for the bundled bwrap (README) — the fix is not a kernel setting.
    **The probe runs the bwrap codex will run** (`bwrap_for_codex/0`, `choose_bwrap/3`):
    codex's launcher prefers a `bwrap` on PATH whose `--help` lists `--perms` (Ubuntu's
    bubblewrap package) over the bundled `codex-resources/bwrap` — so an AppArmor profile for
    the bundled path alone did nothing on a host with bubblewrap installed; the report carries
    `bwrap` (the path), and the settings page / install.sh write a stanza for the system
    binary too. `evaluate/2` is the probe over an injected runner (pure, tested);
    `report/0`/`status/0` are cached for the UI to warn.
  - **Server → client requests** (approvals, `requestUserInput`, elicitations, tool calls…) go
    through the `Longx.Codex.ServerRequest` behaviour: `{:reply, _}` / `{:error, code, msg}` /
    `{:defer, timeout, fallback}` / `{:async, fun, timeout, fallback}`. `Default` is
    exhaustive over the 10 known methods: defers anything a person should decide with a "no"
    fallback (`decline` / `timed_out` / empty answers / `cancel`) so a turn never hangs, runs
    `item/tool/call` async, refuses the two ChatGPT-login-only requests
    (`account/chatgptAuthTokens/refresh`, `attestation/generate`) explicitly, and logs a
    warning for anything unknown (a codex upgrade will show up there). `Connection.respond/3`
    (or `Thread.respond/3`) answers deferred ones by request id. Configure with
    `server_request_handler:`.
  - `Longx.Codex.ThreadState.Store` owns three public ETS tables (meta / items / requests)
    holding every thread's materialised view; it is a long-lived process so the data outlives
    the per-thread writers, and swapping to DETS/Mnesia later touches only this module.
    `Longx.Codex.ThreadState` (Registry + DynamicSupervisor, one per live thread) is the
    **single writer**: it folds each notification into the Store (deltas append in place —
    reasoning `summary`/`content` are `string[]` and `summaryIndex`/`contentIndex` name the
    entry — `item/completed` replaces), allocates a strictly increasing `seq`, and broadcasts
    `{:codex, seq, method, params}` on `"codex:thread:<id>"`; an event the Store cannot fold
    is logged and dropped (one bad notification must never crash the writer for every delta
    of a stream and escalate up the tree). Reads (`snapshot/1`) go straight
    to ETS — no process hop, works even when the writer is stopped, and a restarted writer
    continues the sequence. Pending server requests are in the view with a `"requestId"`.
    **Page refresh / late join protocol: `subscribe` → `snapshot` (has `seq`) → render → apply
    only events with `seq > snapshot.seq`.** `Thread.resume/2` rebuilds the view from codex's
    **paginated history**: `thread/resume` with `excludeTurns: true`, `thread/read` for the
    thread itself, then `thread/turns/list` oldest first (`itemsView: full`, `page_size:`
    100 per page, following `nextCursor`) — a whole-history `thread/read` /
    `thread/resume` is deprecated for paginated threads and codex says so with a
    `deprecationNotice`, which the Tracker logs (never toasts: it is addressed to Longx). Nothing is persisted to the DB yet; codex's own sqlite in CODEX_HOME is the
    history. Single-user system: no thread ↔ user mapping; a thread ↔ project mapping is the
    likely future addition.
  - `Longx.Codex.Thread` is the API to use: `start/1` (`cwd:`, `approval_policy:
    :never | :on_request | :untrusted`, `sandbox: :read_only | :workspace_write |
    :danger_full_access`, `model_context_window:`, `tools: ["ns.name" | module]` — default:
    the globally enabled tools),
    `resume/2`, `send/3`, `steer/4`, `interrupt/3`, `respond/3`, `snapshot/1`,
    `subscribe/1`. It is the only place snake_case is turned into codex's camelCase/kebab-case.
  - **Elixir tools for the agent** (codex *dynamic tools*; README has the developer guide):
    one module per tool implementing the `Longx.Codex.Tool` behaviour (`name/0`,
    `namespace/0` default `"builtin"`, `description/0`, `input_schema/0`, `call/2`; optional
    `available?/1`, `timeout/0`), living under `lib/longx/tools/<namespace>/`. Built-ins use
    the `builtin` namespace and follow exactly the same rules as a fork's tools.
    `Longx.Codex.Tool.Registry` discovers implementations by behaviour at boot (plus
    `config :longx, Longx.Codex.Tool, extra:/disabled:`; duplicate `ns.name` raises) and
    produces the `dynamicTools` specs (namespace-grouped) that `Thread.start/1` declares —
    which needs `capabilities.experimentalApi: true` in the handshake. **Registered ≠
    injected**: `Longx.AI.Tool` rows (synced from the registry by `Longx.AI.list_tools/0`,
    new tools `enabled: false`) are the global switch (`enable_tool/1`, `disable_tool/1`);
    `Thread.start(tools: ["ns.name", …])` is the per-thread choice the UI makes; no `tools:`
    means the globally enabled set — never "everything registered". `Longx.Codex.Tool.Runner`
    executes `item/tool/call`: validate arguments with `ex_json_schema` (errors + schema go
    back to the model so it can fix them), build `Tool.Context` (ids, `cwd`, lazy thread
    `snapshot`), run `call/2` in `Longx.Codex.TaskSupervisor` under the tool's timeout,
    normalise to `DynamicToolCallResponse`. **Every failure is `success: false` with a
    readable message, never a JSON-RPC error.** `ServerRequest.Default` routes it via the
    `{:async, fun, timeout, fallback}` outcome, which `Connection` runs off-process (task
    reply / crash / timeout → reply or fallback). Telemetry `[:longx, :codex, :tool, *]`.
  - The app-server speaks newline-delimited JSON-RPC over stdio (messages omit
    `"jsonrpc":"2.0"`). Protocol facts that shape the design:
  - Docs: https://learn.chatgpt.com/docs/app-server. The exact schema for the bundled
    version is authoritative over the docs:
    `priv/codex/<target>/bin/codex-app-server generate-json-schema --out DIR`
    (also `generate-ts` for the React side). Regenerate into the scratchpad/`tmp/`, don't
    commit the 4 MB output.
- `lib/longx_web/` — Phoenix web layer. **The React SPA owns the URL space**:
  `LongxWeb.PageController.spa/2` serves the shell (`spa_root` layout, `<div id="app">`) for
  `/` and, as the router's **last** route (`get "/*path"`, pipeline `:spa` — session, CSRF
  token, no `:accepts`), for every other HTML navigation, so deep links survive a refresh.
  It answers 404 for non-HTML `Accept`s and file-looking paths (a missing asset must never
  come back as HTML). `/rpc/*`, `/ai/v1/*`, `/socket`, `/dev/*` are matched before it.
  No LiveView pages (the `root` layout remains for the dev dashboard/errors).
  - **Self-upgrade** — `Longx.Upgrade` (GenServer in the tree + `Longx.Upgrade.TaskSupervisor`):
    `check/1` asks GitHub's `releases/latest` (`config :longx, Longx.Upgrade, repo:, api_url:`;
    `LONGX_UPDATE_REPO` / `LONGX_UPDATE_API` at runtime; a saved GitHub token —
    `Longx.System.Setting` `github_token`, encrypted like a provider key — goes out as the
    bearer, since anonymous calls are capped at 60/h), caches the result and refreshes every
    `tick` (6 h; nil in tests). `apply/0` works only inside an install (`RELEASE_ROOT/bin/longx`
    exists, or `app_dir:` in tests): download tarball + `.sha256` into `<home>/downloads`,
    verify, `VACUUM INTO <home>/backups/longx-<current>-<stamp>.db`, unpack to `app.new`, swap
    `app` → `app.old` → `app`, then `restart_command` (default `systemctl --user restart
    --no-block $LONGX_SERVICE`, `longx`); no way to restart → stage `:installed` with a
    "restart by hand" message; the download streams through a Req `into:` sink that
    reports `progress: %{received, total}` (total from `content-length`, at most every
    200 ms) — the page draws a bar with the bytes; every stage is broadcast as `{:upgrade, status}` on
    `Upgrade.topic/0`. RPC: `upgrade_status` / `upgrade_check` / `upgrade_apply` /
    `set_github_token` on `Longx.System.Status`; the SPA (`core/upgrade.ts`,
    `pages/settings/UpdateSection`, a hint in the status strip) polls the status every second
    while a stage runs and reloads once a status from another version answers.
  - `Longx.System` (domain) → `Longx.System.Status` generic actions: `sandbox` and
    `list_directory` (`Longx.System.Directory`: subdirectories of an absolute path, git
    flagged, hidden on request, roots home and `/`; arrays of typed maps are untyped in
    ash_typescript 0.18's field selection, so entries are typed client-side) and
    `create_directory` (one name under an existing parent — the picker's "新建目录").
  - `LongxWeb.Actor` is the single place an actor comes from (RPC conn, socket params) —
    `nil` today; AshAuthentication plugs in there later without touching the client.
  - **RPC** = ash_typescript: domains `Longx.Projects`, `Longx.AI`, `Longx.System` declare
    `typescript_rpc` blocks; resources carry `AshTypescript.Resource` + `typescript do
    type_name … end`; work that lives in domain functions (`send_message`, `git_info`,
    `codex_info`, `check_model`, tools catalogue, sandbox status…) is exposed as **generic
    actions** whose `run` calls the existing function and whose return is a typed map
    (`constraints fields: […]`) or `:struct`. Ash `timestamps(public?: true)` where the UI
    needs them. `POST /rpc/run` is tested at the wire in `test/longx_web/rpc/` so the
    generated client's contract is what is tested. Every call carries Phoenix's CSRF token
    via the lifecycle hook (`assets/js/core/rpcHooks.ts`, configured in `config.exs`).
  - **Channels** (`LongxWeb.UserSocket` at `/socket`): `LongxWeb.ThreadChannel`
    (`thread:<codex_thread_id>`) is the ThreadState protocol on the wire — join replies with
    the snapshot (`seq`), then `"codex"` pushes `%{seq, method, params}`, `"snapshot"` on
    demand; joining a thread no running codex hosts is refused. `LongxWeb.ProjectChannel`
    (`project:<id>`) pushes `"changed"` (rows changed → refetch; from
    `Longx.Projects.broadcast_changed/1`, called by the Tracker and Projects after writes),
    `"codex"` (`%{status}` ready/down for that project's process) and `"sample"` (the
    recycler's numbers). Tests: `LongxWeb.ChannelCase`.
  - **Vite ↔ Phoenix is ours, not a dependency** (`LongxWeb.Vite`, `LongxWeb.Vite.Watcher`;
    phoenix_vite was evaluated and rejected as immature — reference only). `<LongxWeb.Vite.assets />`
    in the layouts renders, in dev, the HMR client + raw entry from the Vite dev server
    (`config :longx, LongxWeb.Vite, dev_server:`; `LONGX_DEV_HOST=<lan-ip>` for phone
    testing — Vite listens on `0.0.0.0:7789` (7788 + 1, so it never collides with another
    project's Vite on 5173; `strictPort`) and the phone loads scripts from it directly),
    — first `js/dev/react-refresh.ts` (the React Fast Refresh preamble a non-Vite page must
    load itself, else "@vitejs/plugin-react can't detect preamble"), then `@vite/client`,
    then the entry — otherwise the hashed files from `priv/static/assets/.vite/manifest.json` (entry css,
    script, `modulepreload` for imported chunks; cached in `persistent_term`). The dev
    watcher runs `npm run dev` **through `Longx.Shim`** so Vite dies with the BEAM (a plain
    npm watcher leaves node on the port). `mix assets.build` = compile + `ash_typescript.codegen`
    + `npm run build` → `priv/static/assets/` (gitignored); no `phx.digest`. PWA bits are
    committed static files: `priv/static/manifest.webmanifest`, `icons/` (`static_paths/0`).
- `assets/` — Vite + TypeScript + React 19, tests with vitest/testing-library
  (`npm run check` = `tsc --noEmit` + `vitest run`, part of `mix precommit`). Layout:
  - `js/core/` — **DOM-free**, the part a React Native app will reuse: the generated client
    (`ash_rpc.ts`, `ash_types.ts` — **generated** by `mix ash_typescript.codegen`, never
    edited; `codegen --check` runs in precommit), `rpcHooks.ts`, `socket.ts` (one Phoenix
    socket, status for the connection banner), `projectChannel.ts`, TanStack Query hooks
    (`projects.ts`; `RpcFailure` carries field errors; `useModels`), formatters, and
    `core/chat/` — the chat runtime, DOM-free: `thread.ts` (the client half of
    `Longx.Codex.ThreadState`: snapshot + `applyEvent` with the same fold rules as the
    server's Store — deltas append, reasoning `summary`/`content` are `string[]` addressed by
    `summaryIndex`/`contentIndex`, `thread/reverted` drops turns, a `requestId` means a
    pending question; items get `startedAtMs`/`completedAtMs` from the client clock),
    `threadChannel.ts` (`thread:<codex id>`; the join reply's `thread_id` is authoritative —
    an empty thread codex could not resume comes back under a new id; `snapshot()` re-pulls
    in place), `useThreadView.ts` (`refetch`; a `thread/reverted` re-pulls on its own;
    **events fold once per animation frame** — `batch.ts`'s `createBatcher`: codex streams
    deltas every few ms, and a React commit per delta cannot keep up, which React reads as a
    commit that always leaves work pending and kills as "Maximum update depth exceeded";
    test builds fold at once),
    `messages.ts` (codex items → assistant-ui `ThreadMessageLike`: one assistant message per
    turn with `metadata.timing` from the turn's stamps + the last turn's token usage;
    agentMessage/plan → text, reasoning → reasoning, commandExecution / fileChange /
    webSearch / `ns.tool` → tool-call parts (`args`/`result`/`artifact`/`timing`) —
    `displayCommand` strips codex's `zsh -lc '…'` wrapper; a pending `*/requestApproval`
    rides on its part as assistant-ui's `approval` (accept / accept_for_session / decline), a
    pending `item/tool/requestUserInput` is a standalone `requestUserInput` part; either
    makes the message `requires-action`, the only state in which assistant-ui shows the
    controls), `adapter.ts` (`buildAdapter` → `ExternalStoreAdapter`: `onNew` →
    `sendMessage` (no thread yet → `createThread` first; a `dirty_tree` RPC error asks
    `onDirtyTree` for commit / ignore and resends), `onCancel` → `interruptTurn` (or
    `retractTurn` + `onRetract(text)` while the turn ran nothing — `turnHadEffects`),
    `onRespondToToolApproval` → `respond`, `onRefetchThread`, `isLoading` /
    `isSendDisabled` (disconnected: typing yes, sending no) / `isDisabled`
    (unrecoverable, archived), `adapters.threadList`, `queue`, `extras.answerRequest` →
    `answer_request`), `threadList.ts` (`buildThreadListAdapter`: rows → assistant-ui thread
    data, handlers only for what exists: switch, new, rename, archive), `runtime.ts`
    (**`useCodexRuntime({ projectId, defaults, threadId, onOpenThread })`** — the whole thing as one
    hook, the shape of `@assistant-ui/react-opencode`: threads query + live view +
    `createMessageQueue` (a message sent while a turn runs waits and goes out when it
    settles; no `cancel`, so a "steer" only means "next" — codex's `turn/steer` is a
    different thing, not wired) + per-turn model + `TurnState`; the router comes in as a
    callback so React Native can reuse it). **Everything the adapter is built from must be
    referentially stable while nothing changes** (`runtime.test.tsx`): assistant-ui
    re-applies the adapter after every render and a "new" adapter notifies the store on
    every commit — `useMutation`'s result is a new object per render (use `mutateAsync`),
    the mode object is memoised, callbacks are `useCallback`.
  - `js/ui/` — React DOM, **shaped like an IDE with the chat where the editor would be**
    (IDEA's interactions, not its looks): `pages/WelcomePage` (recent projects, search, one
    door to open/create; on top, **what is running now** — `RunningThreads` over
    `useRunningThreads` (RPC `list_running_threads` on `Longx.Projects.Thread` →
    `Projects.running_threads/0`: every root thread with status `:active` across projects,
    its project's slug/name, `waiting` when its ThreadState holds a request for the person;
    polled every 3 s while the page shows), each a link into the thread, the ones waiting on
    the person first and amber; nothing running, no section), `pages/ProjectWizard` (two steps: `components/DirectoryPicker` on
    the server's file system — `Longx.System.list_directory`, git repositories marked, hidden
    toggle, typed path — then name / "initialise git" / advanced sandbox+approval+network;
    a repository directory is an *open*, anything else may get `init_git: true`),
    `frame/ProjectWindow` (desktop: icon rail + docked resizable tool window + status
    strip; phone: chat full-screen, bottom toolbar, tools as bottom sheets — tool windows:
    `frame/tools/{Threads,Git,Process,Turns,Agents,Files}Tool`; ⌘1–6 toggle them; `core/frame.ts` keeps
    the state, remembered per device; `TurnsTool` is the history: the thread's turns with
    status / model / commits, the per-turn diff as `code-diff` per file (`splitDiff`), and
    the restore (proposal → confirm → `restore_files`) and redo (text, model, revert |
    fork, restore first) dialogs over `core/projects.ts`'s `useTurns` / `useRestoreFiles` /
    `useRedoTurn`; the points to fall back to — every turn that started from a commit,
    plus "now" — are the `checkpoint-history` element on top, its restore opening the same
    dialog; `AgentsTool` is the thread's sub-agents as the `background-inbox`
    element over `useSubagents` — a finished one opens its own thread page),
    `frame/StatusStrip` (HEAD, codex, memory, sandbox warning; every item `whitespace-nowrap
    shrink-0` — a narrow phone scrolls the strip sideways, it never folds "codex 就绪" into
    two rows).
    **The centre is an editor area** (`ui/workbench/Workbench`, state in `core/workbench.ts`
    per project on the device): a tab strip — the chat first and always, then files and
    diffs opened from the tools — the chat kept mounted behind an open file; a dirty tab
    asks before closing. `EditorTab` = `ui/editor/CodeEditor` (**CodeMirror 6** as a
    controlled component: lazy languages from `@codemirror/language-data` plus
    `codemirror-lang-elixir`, our tokens as the theme — `--syntax-*` colours in both
    themes — ⌘S, soft wrap on phones; a value from outside never counts as an edit) with a
    draft, save / discard, binary and over-large files said as such; `DiffTab` =
    `ui/editor/DiffView`, **GitHub's file view on `@codemirror/merge`**: the two versions
    from `git_file_versions` as `MergeView` side by side (each pane scrolls sideways on its
    own — `app.css` lifts the merge view's `overflow: hidden`) or `unifiedMergeView` inline
    (a phone's default; a toggle in the tab's bar), the file's language highlighting both,
    changed characters underlined, unchanged stretches collapsed into a "N 行未改动" bar
    (`EditorState.phrases` for the label), colours from our tokens, read-only. **`FilesTool`** (⌘6)
    is the IDE tree: folders first, children on open, git status coloured on files and
    rolled up onto folders, `.gitignore`d paths dimmed, a row menu for new file / folder,
    rename (open tabs follow) and delete (confirm), a filter over codex's fuzzy file index
    (`search_files`); on a phone the tree is a sheet that closes on tap. **`GitTool`** (⌘2)
    is GitHub Desktop's shape in a tool window: a branch button (popover: switch — with a
    stash offered when the tree is dirty — create, delete, pop a stash) and a sync button
    (↓behind ↑fetch/pull/push, the remote set in a dialog when there is none), then Changes
    (every file checked by default, its diff a tap away in the workbench, summary +
    description, commit to the branch, discard behind a confirm, a merge stopped on
    conflicts explained with "abort") and History (commits paged 30 at a time, one commit's
    body and files, a file's diff at that commit, undo of the last commit). Its queries
    live in `core/workspace.ts` (`useFiles`, `useFileContent`, `useGitChanges` — polled
    every 10 s while the tool shows, since the agent edits without telling us —
    `useGitLog`, `useGitShow`, `useGitActions` invalidating everything git, the tree and
    open files after any action).
    `pages/ProjectSettingsPage` (`/p/:slug/settings`: name, description, the thread
    defaults — sandbox, approval, network, dirty_start, model, memory cap — via
    `update_project`; danger zone: clear codex history, archive, each behind a confirm),
    `pages/SettingsPage` (categories tree on desktop, list → sub page on phones):
    `settings/ModelsSection` — every provider as a card (endpoint, kind, key present or
    not, last error / check) with its models (slug, upstream id, window, levels, the
    default starred; 检测 = `check_model`, 设为默认, edit / delete in a menu). **"添加
    Provider" offers the presets first** (`PresetChooser`: a card per `list_presets`
    entry, 已添加 when installed, plus 自定义 → the free form with timeout / concurrency
    folded under 高级); a preset is one step (`PresetDialog`: the key unless the
    provider has one, 获取 API Key / 接入文档 links, the models to add as the registry's
    `model-picker` element turned into a checklist — recommended ones pre-checked,
    installed ones left out, window and 图片 / levels as chips — and which becomes the
    default → `apply_preset`); a provider that came from a preset gets 从模版添加模型 in
    its menu while the preset has models it lacks. The model dialog edits the levels as
    toggles of codex's known efforts (`LevelsEditor`, plus a typed custom one) with the
    default level chosen among them (free text when no level is declared); the
    search provider's key below. Deletes confirm; the default model and its provider
    refuse (`delete_model` / `delete_provider` are guarded actions apart from the plain
    `destroy`; a provider's delete cascades to its models). `settings/ToolsSection` — the
    registry's catalogue with a switch per tool (`set_tool_enabled`).
    `settings/SandboxSection` — the bwrap probe's verdict with 重新检测 (`probe_sandbox`).
    `settings/ProcessesSection` — every running codex, stop per row (above).
    Hooks in `core/ai.ts` (`useProviders`, `useModelRows`, `useSearchProviders`,
    `useTools`, `useAiActions`, `useProbeSandbox`; every write invalidates `["ai"]` and
    the composer's model list). Appearance is the theme,
    `components/CommandPalette` (⌘K, desktop), `sonner` toasts for codex down/ready.
    **The native-shell bridge** (`ui/shell/longxShell.ts`, mounted as `ShellBridge` in
    `Shell`): the Android app (github.com/mjason/longx-android, a WebView loading the SPA
    from the address the person typed; iOS later) injects `LongxAndroid.post(json)` (iOS:
    `webkit.messageHandlers.longx`) — asynchronous JSON both ways, the smallest contract
    both platforms can implement; a browser has neither and nothing is installed. Page →
    shell: `ready {version, theme}` (on mount; twice under StrictMode, harmless), `theme
    {scheme, frame, ground}` (our `--sidebar` / `--background` for the shell's own bars),
    `openExternal {url}` (a link to another origin — intercepted on click), `pick {id, title,
    sections: [{label?, options: [{id, label, detail?}]}], selected}` (`shellPick()` — a
    native single-choice list, a bottom sheet on Android, answered by `LongxShell.picked(id,
    optionId | null)`; a popover is a poor fit for a phone: inside a shell `ComposerTrailing`
    asks for the model this way, then its levels when it has them, instead of opening the
    model-selector popover). Shell → page:
    `window.LongxShell.back()` (closes the top Radix layer — dialog / sheet / popover /
    menu — with an Escape and returns true; false = nothing open, the shell goes back
    itself), `navigate(path)` (a notification's deep link, in-app), `resume()` (back from
    the background: `reconnectSocket()` tears a dead socket down and reopens it at once,
    every query invalidated). `<html data-shell="android">` while installed; the bridge
    keeps `--app-height` at `visualViewport.height` and `app.css` makes `h-dvh` /
    `min-h-dvh` follow it under `[data-shell]` — the keyboard shrinks the visual viewport,
    a WebView does not always resize the layout one, and the composer sat under the
    keyboard. The viewport meta also says `interactive-widget=resizes-content`.
    `routes.tsx` (react-router, browser history; tests use a memory router via
    `ui/test-utils.tsx`, shared `vi.mock` factories in `ui/test-mocks.ts`), `shell/` (Shell,
    TopBar `wide` for the IDE window, Page, BottomBar — **fixed at the bottom on every screen
    size**, a dialog footer: an action must never depend on the page scrolling to be reached;
    long lists scroll in their own box — banners), `components/ui/` (shadcn,
    added with `npx shadcn@latest add …` in `assets/`; `components.json` maps
    `@/ui/components`, `@/lib/utils`; **`DialogContent` is a flex column capped at the
    viewport** with `DialogBody` as the scrolling middle — a tall form keeps its header and
    buttons in view on a phone instead of scrolling them off; wrap what may grow in
    `DialogBody`, a `<form>` between header and footer gets `flex min-h-0 flex-1 flex-col`), `strings.ts` (all UI copy, zh-CN). `core/theme.ts`
    (**follows the OS by default**, dark/light as explicit choices; `ThemeToggle` in the top
    bars cycles them; the CSS also honours `prefers-color-scheme` before JS runs),
    `core/viewport.ts` (phone < 768 ≤ tablet < 1024 ≤ desktop).
    The chat uses **assistant-ui** (`@assistant-ui/react`, `ExternalStoreRuntime`; it has an
    official React Native package) — not AI Elements, not `useChat`. **Do not hand-roll
    chat UI**: find the element in assistant-ui's catalog (the `elements` skill from
    `npx skills add assistant-ui/skills`, or https://www.assistant-ui.com/elements), then `npx assistant-ui@latest add <item>` in `assets/` (answer "n" to
    overwriting existing shadcn files). Elements land in
    `js/ui/components/assistant-ui/elements/` (`*.aui.tsx` read the runtime, the rest are
    props-driven) and are **source we own and adapt**: `thread.aui` (zh-CN strings, no
    attachments/reload/edit until the runtime offers them), `tool-group.aui`, `reasoning`,
    `markdown-text`, `tool-fallback.aui` (dynamic `ns.tool` calls), `terminal-block`
    (`exitCode`/`exitLabel`/`fullCommand` instead of the demo's fixed "exit 0"),
    `code-diff`, `web-search` (real urls), `approval-card` (labels/icon props);
    **renderers** (catalog section "Renderers"): `markdown-text` with `shiki-highlighter`
    for fenced code (tokenises once the part settles; `github-light/dark-default` themes)
    and `mermaid-diagram` for `mermaid` fences (skeleton while streaming, zoom dialog);
    **reasoning is the element's step-panel design** (`reasoning-panel`, the catalog's
    "Static" variant): `ui/chat/ReasoningSteps` fills the `ReasoningGroup` slot of
    `thread.aui` and turns the group's reasoning parts into titled steps down a timeline
    (`core/chat/reasoningSteps.ts`: OpenAI-style bold headings open a step, raw thinking
    makes each paragraph a step titled by its first sentence — CJK stops or `.!?` before
    a space, never inside brackets), a shimmering "思考中" while it streams (open) that
    settles to "思考过程" (folded; the reader's toggle sticks). `reasoning.aui` /
    `streaming-text` stay installed but unused by the thread; the `generative-ui` renderer
    is not wired — nothing produces `generative-ui` parts (codex emits none, OpenUI was
    dropped) —
    `thread-list.aui` (the threads tool is this element over `adapters.threadList`),
    `message-timing.aui` (in the assistant action bar), `elicitation-form` (made
    interactive: `onChange`, labels — codex's questions) — `surfaces.tsx` and
    `../utils/range.ts` are the registry's shared helpers. `ui/chat/`: `ChatProvider`
    (mounted by `ProjectWindow` around the whole window so the threads tool and the centre
    share one runtime: `useCodexRuntime` + `AssistantRuntimeProvider` with `chatConfig` +
    the `DirtyTreeDialog`; `useChat()` reads it), `ThreadPage` (routes `/p/:slug` — a new
    chat whose first message creates the thread — and `/p/:slug/t/:threadId`; Thread
    element; the composer rail is Codex's: `ComposerLeading` (`ModePicker` — the access
    mode for the next turn: sandbox / approval / network in a popover, from the thread row
    or the project defaults, sent with every message; **on a phone the form is a bottom
    `Sheet` that scrolls** (`useViewport() === "phone"`; the popover ran off the top of the
    screen) and the trigger shows the short name (`t.sandboxShort`: 只读 / 可写 / 完全访问)
    — never the icon alone — the full name from `sm` up; and the turn's state) /
    `ComposerTrailing` (the `context-display` ring — codex's last-turn token usage
    against the `modelContextWindow` it reports, `contextUsage(view)`; **its breakdown is a
    click-to-open popover, not the registry's hover tooltip**: the composer sits in the
    thread's scrolling viewport (`ViewportFooter`) and Radix's tooltip closes itself
    whenever an ancestor of its trigger scrolls, which the auto-scroll did on every
    streamed line — and the per-turn
    model with its reasoning level: the registry's **`model-selector`** element used
    standalone (`ModelSelectorRoot` with our `value` / `effort`; no model-context
    registration — our RPC carries the choice), models grouped by provider,
    `efforts` from the row's `reasoningLevels` so the 思考 row shows only for a model
    that has them (`effortLabel` names them in `strings.effortLevels`); `model` /
    `effort` live in `useCodexRuntime` (`setModel` resets the level to the new model's
    default) and a new chat passes both to `start_thread` — the thread's window and
    search mode are start-time config — while a later pick rides on `send_message`; the
    rail names the project's own default model via `defaultModelId`) are slots our
    `thread.aui` copy adds, as are
    `ComposerPopovers` and `UserText`. **The composer has the catalog's Composer
    element's full set** (https://www.assistant-ui.com/elements/composer, all wired
    through the runtime, nothing hand-rolled): **attachments** — the runtime's
    `adapters.attachments` is `CompositeAttachmentAdapter([SimpleImage, SimpleText,
    FileUpload])` (built once in `useCodexRuntime`, like everything the adapter is made
    of), so the `+` button (`ComposerAddAttachment` from `attachment.aui`), paste and drop
    onto the bar stage files as tiles; on send `adapter.ts`'s `inputOf` puts images on
    the RPC as `images` (data urls) and appends text files to the text. **Any other file
    (a zip, a PDF, a dataset)** is `core/chat/fileAttachments.ts`'s
    `FileUploadAttachmentAdapter` (`accept: "*"`, so it is last): `add` uploads it at once
    to `POST /attachments/:project_id` (multipart, the RPC's CSRF token; parser limit
    512 MB) — `LongxWeb.AttachmentController` → `Longx.Projects.Attachments.store/3`, which
    keeps the file as `<stamp>-<name>` under `<attachments dir>/<project id>/` in the data
    directory (`config :longx, Longx.Projects.Attachments, dir:`; dev `data/attachments`,
    prod `$LONGX_DATA_DIR/attachments` — never the working directory, the repository
    stays clean; the name is reduced to a basename); `send` puts one line in the message,
    `<attachment name="…" path="…" size="…" />` + a hint, and the agent reads or unzips
    the path itself (the sandbox sees `/` read-only; live-checked with DeepSeek: a zip
    dropped on the composer, `unzip` into /tmp, contents read back). Deleting a project
    removes its attachments (`Changes.DeleteAttachments`); a sent image comes back in
    codex's `userMessage` content as `image` and `messages.ts` renders it as an image
    part (`UserImagePart`); **dictation** — `adapters.dictation` is
    `WebSpeechDictationAdapter` where the browser has speech recognition (the mic in the
    rail; absent otherwise) — **switched off for now** by `DICTATION = false` in
    `core/chat/runtime.ts` (no adapter → no capability → no button), flip it to bring
    the mic back; **`/` commands** — `ui/chat/SlashCommands` over
    `unstable_useSlashCommandAdapter` and the same `composer-trigger-popover` element
    (`action` behaviour, text cleared on pick): `/new`, `/review` (RPC `review_thread`,
    uncommitted changes), `/compact` (RPC `compact_thread`), `/init` (sends
    `t.initPrompt` through `aui.thread.append`), `/git` `/files` `/history` (tool
    windows), `/settings`; the popover's list is capped and scrolls (the composer sits
    mid-screen on a new chat, with little room above — smaller cap on phones);
    **input history** — `unstable_useComposerInputHistory` spread on the Input: ↑ on an
    empty draft recalls what was sent. jsdom needs `URL.createObjectURL` for the tiles
    (`vitest.setup.ts`). **`@` file mentions** — `FileMentions` is the
    registry's `composer-trigger-popover` over `unstable_useLiveCompletionAdapter` →
    RPC `search_files` (`Projects.search_files/3`: codex's own `fuzzyFileSearch` index under
    the project root, `.git` dropped, 20 best); `core/chat/mentions.ts`'s `fileFormatter`
    writes the pick as `@path` (quoted when it has spaces — what codex's TUI does, the model
    just sees a path and reads the file itself) and `directive-text` renders it as a chip in
    the user message), `toolkit.tsx` (`defineToolkit` with
    `type: "backend"`, `display: "standalone"` renderers per codex item type, **all built
    from the registry's Tool-use elements, one visual language**: every invocation is a
    `tool-call` row (verb · mono chip · check/cross; open while running or failed, a click
    away when done — our copy takes `children`/`failed`) whose body is the element for the
    work — `terminal-block` (commands; `tool-error` when it could not run), `file-tree` +
    `code-diff` (file changes; `treeOf`, `parseDiff`), `web-search`; `approval-card` above a
    row that waits on a decision; `elicitation-form` for codex's questions
    (`QuestionsTool`, answers via `s.thread.extras.answerRequest`); reasoning uses the
    `ghost` variant so it sits with the rows. **Agents** (catalog section "Agents"):
    `messages.ts` folds a sub-agent's `subAgentActivity` items into one `subagent` tool
    call (id = the child's codex thread id; `args.request` = what the child waits approval
    for) whose `messages` is the child's own conversation (`toMessages(childView)` →
    `fromThreadMessageLike`, recursive) — `SubagentTool` renders it as a row with an
    `agent-status` pill and `MessagePartPrimitive.Messages` over the exported
    `AssistantParts` of `thread.aui`, so nested commands/diffs look like the parent's;
    a child's pending approval rides on that part as the parent's `approval`
    (`approval-card`, answered on the parent thread). `collabAgentToolCall` → `collab`:
    spawn / send_message are an `agent-handoff`, wait a `subagent-list` (a wait names every
    agent so far; codex 0.154 completes it with empty `receiverThreadIds`/`agentsStates`, so
    each agent's state falls back to its own latest `subAgentActivity` kind). The turn's plan is a `data-plan` part
    at the top of its message (`PlanUI` = `makeAssistantDataUI` + `agent-plan`, mounted in
    `ChatProvider`, like `CompactionUI` for codex's `contextCompaction` marker). The child views come from `useThreadViews` (one channel per child id
    named by the parent's activities, transitively) and reach the adapter as `subviews`;
    a child's requests count as "等待审批" in the turn bar. The `agent-plan`,
    `subagent-list`, `agent-status`, `agent-handoff`, `background-inbox` copies took
    label / optional-prop tweaks (states per step, no demo glyphs) — still the registry's
    look. Registered through
    `AuiConfig({ tools: Tools({ toolkit }) })`, so they win over `ToolFallback` by name;
    approvals answer with `respondToApproval({ optionId })`. **Never draw a tool's UI from
    scratch — pick the element from the catalog first** (https://www.assistant-ui.com/elements,
    section "Tool use"). `thread.aui` also shows a
    stall hint (`unstable_useMessageStallDetection`, 15 s) and the timing badge.
    `ProjectWindow` is `h-dvh`: the thread scrolls in its own viewport, never the page.
    **The viewport follows the bottom** (no `turnAnchor="top"` on `ThreadPrimitive.Viewport`:
    the registry's top anchor pins the latest user message to the top and switches
    assistant-ui's auto-scroll off, so a long turn — a streaming command, the thinking
    panel growing — ran below the fold); a reader who scrolls up stays put and gets the
    scroll-to-bottom button (measured live: gap to bottom 0 throughout a 12 s stream). Headers and bars are
    solid (`backdrop-blur` on sticky/fixed bars ghosted text in Chromium screenshots).
    After `npm install` adds packages while `mix phx.server` runs, restart it: Vite's
    dependency re-optimisation can otherwise load two copies of React ("Invalid hook call").
  - **Mobile first**: one column; `TopBar` respects the notch (`safe-top`), `Page` keeps
    ≥16 px gutters (`safe-x`), the primary action sits in a fixed `BottomBar` on phones
    (`safe-bottom`) and inline on desktop (`lg:`); touch targets ≥ 44 px (`touch-target`);
    16 px base font (no iOS zoom); the page never scrolls sideways — wide content scrolls
    inside its own box; dark is the default theme, `[data-theme="light"]` the override.
    **Palette** (`css/app.css`): Codex GUI's layout of colour — the transcript on a white /
    near-black ground, the frame (rail, tool panel, top bar, status strip, phone toolbar:
    `bg-sidebar` / `border-sidebar-border`) one step off it, no surface tinted beyond a
    whisper — balanced the way Monokai Pro balances a theme (calm greys, state colours
    muted and on one lightness), with the **LX logo's azure as the one accent**
    (`--primary` `#2f7cf6` dark / `#1b5cf0` light: send button, active rail icon, focus
    ring — never a background wash); green / orange / red for success / warning /
    destructive. Dark ground `#1c1e24`, frame `#15171c`; light `#ffffff` / `#f3f4f7`. The
    logo (`priv/static/images/logo.png`) is the mark; favicon, PWA icons, apple-touch-icon
    and the header mark (`images/logo-mark.png`, `ui/components/Logo`) are regenerated from
    it with `python3 assets/scripts/icons.py`; `theme-color` metas and the manifest carry
    the frame / ground colours.
    `css/app.css`: Tailwind v4 with shadcn token names, **no `@apply`**, no daisyUI; only
    `html` gets `overflow-x: hidden` (on body/#app it can steal touch scrolling).

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
- Use AssistantRuntimeProvider at the app root of the chat (`ui/chat/ThreadPage`).
- Thread component for full chat interface (`elements/thread.aui`, slots via `components`).
- AssistantModal for floating chat widget (not used here — the chat *is* the centre).
- Runtime: `useExternalStoreRuntime` over our codex thread view (`core/chat/adapter.ts`) —
  **not** `useChatRuntime` / AI SDK transport: the model loop lives in codex, the UI only
  projects its events. The closest published analogue is `@assistant-ui/react-opencode`
  (ExternalStoreRuntime + RemoteThreadList over a coding-agent server, permissions on the
  tool-approval contract, questions, `extras` for fork/revert/refresh) — copy its shape,
  not its package.
- Capabilities are handler-driven: `onNew` (send), `onCancel` (stop), `setMessages`
  (branching), `onEdit`, `onReload`, `onRefetchThread`, `adapters.threadList`; a button
  only appears when its handler exists — never hand-roll one.
- Tool UI: toolkit `render` per tool name; `display: "standalone"` keeps a tool out of the
  collapsible trace group (commands / file changes are "informing the user", not a trace).

## Releases

`MIX_ENV=prod mix assets.build && MIX_ENV=prod mix release` builds a self-contained
release; `mix.exs`'s release step `bundles/1` recopies `priv/{codex,git,obscura}` with
their symlinks (a plain copy turns git's 145 builtin links into 700 MB) and drops
`priv/plts`. `config/runtime.exs` (prod) needs only `LONGX_DATA_DIR`: the database, codex's
home and the two secrets live there — `secret_key_base` and `cloak_key` are generated on
first boot into 0600 files unless given as env vars; `PORT` (7788), `PHX_HOST`; the
release serves plain http itself (`server: true`, no `force_ssl` — TLS is a proxy's job).
The endpoint has `check_origin: :conn` (config.exs): a self-hosted instance is opened by
whatever address the person typed, so the socket's Origin is checked against the request's
own Host, never against `PHX_HOST` (the default `true` refused every LAN-IP page with
"Could not check origin" — the "连接已断开" banner on a fresh install; `socket_origin_test`).
A release seeds nothing — providers and keys are created in Settings (presets) — except
the one row the settings page cannot create itself: `Longx.AI.ensure_search_provider/0`
(the Tavily row, default) runs as a boot `Task` after the migrator, else a fresh install
had no 联网搜索 section to enter the key in; the dev /
test database gets `Longx.AI.Seeds.run/0` through `priv/repo/seeds.exs` (DeepSeek preset
without a key as the default model, the OpenAI provider, a Tavily row, the tools — no
API keys from the environment; the `:live` tests read `DEEPSEEK_API_KEY` themselves).
`install.sh` (repo root, `curl … | sh`) installs or upgrades in `~/.longx` (`app` /
`data` / `backups` / `downloads`) as a `systemd --user` service, verifying the sha256,
backing `data` up before a swap, `--rollback` puts `app.old` back; `LONGX_TARBALL=` installs
a local build (how it is tested). `rel/env.sh.eex` sets `ELIXIR_ERL_OPTIONS=+fnu`: file
names stay UTF-8 in a bare environment. `.github/workflows/ci.yml` runs the precommit set on every push / PR (bundled git and
codex fetched and cached; `:integration` stays excluded, and so is `:host_sandbox` — the
bwrap probe test that only a real host passes, a runner cannot set up the loopback); `release.yml` builds on a
`v*` tag for linux x86_64 and arm64, each natively on its own runner
(`ubuntu-24.04` / `ubuntu-24.04-arm`), tars `_build/prod/rel/longx` and attaches the
tarballs to the GitHub release. The repository is public at github.com/mjason/longx (MIT).

## Development workflow — TDD is mandatory

Every change follows red → green → refactor. No production code without a test that
motivated it.

1. Write a failing test first and run it: `mix test test/path/to/file_test.exs:LINE`.
   Confirm it fails for the *expected* reason.
2. Write the minimum code to make it pass.
3. Refactor while green, then run the whole suite: `mix test`.
4. Before declaring done: `mix precommit`
   (`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`).
   `mix dialyzer` (dialyxir; PLT in `priv/plts/`, mix + ex_unit included) must stay at
   zero warnings — not part of precommit (minutes), run it before merging. Two habits it
   enforces: never `Process.sleep(n) && f()` (`:ok && …` is a guard that can never fail —
   write two lines), and no opaque `MapSet` inside a reduce accumulator (dialyzer loses
   the opaque type; a plain map works).

Where tests live / what to use:

- Ash resources & actions → `test/longx/…`, `use Longx.DataCase`; call code interfaces,
  assert on results and on `Ash.Error.*` for failures. See the `ash-framework` skill
  (`references/ash/testing.md`).
- Controllers / LiveViews → `test/longx_web/…`, `use LongxWeb.ConnCase`,
  `Phoenix.LiveViewTest` + `LazyHTML`; assert on element IDs, not raw HTML.
- `Longx.Shim` → `test/longx/shim_test.exs` drives real OS processes (`cat`, `sh -c …`;
  the guard tests need `python3`); the Go side has its own `go test` suite in `native/shim`
  with an in-memory host harness (`guard_test.go` is Linux-only).
- `Longx.Codex.Runtime` / `Longx.Git.Runtime` → tests install from locally built fake
  tarballs (`source: {:file, …}`); the real download is never exercised in the unit suite.
- `Longx.Git` → `test/longx/git_test.exs` runs the *bundled* git on temp repos in the default
  suite (it is a dev prerequisite like Go: `mix setup` fetches it; missing → raises with
  "run `mix git.fetch`"). `Longx.Projects` thread/turn tests combine temp git repos with the
  fake app-server through a per-test `Connection` passed as `conn:`.
- Codex client → `test/support/fake_app_server.exs` is a scripted stand-in for the
  app-server (`say`/`approve`/`stall`/`slow`/`error`/`die`/`server-notify` turns) run under
  `Longx.Shim` exactly like the real binary (its stdio forced to byte mode: with no UTF-8
  locale in the env the VM's latin1 stdio ended the read on a CJK frame); Connection/Thread/ThreadState tests use it, and
  `thread/read` answers with the `startParams`/`lastTurnParams` it received so tests can
  assert what was sent. Tests that go through the pool (no `conn:`) are `Longx.DataCase`
  (the Tracker writes on every `:down`/`:ready`) and clean up with
  `Longx.Test.PoolHelpers.stop_pool!/1`, which drains the Tracker before the sandbox ends.
  Project ids must be uuids even in pool-only tests.
  `Longx.Test.CodexHarness` drives the *real* binary through Connection/Thread for the
  `:integration` / `:live` tests (`serve_endpoint!`, `prepare_home!`, `start_connection!`,
  `run_turn!`). In `mix run` scripts the HTTP server is off — use `PHX_SERVER=true` or codex
  cannot reach the gateway.
- AI gateway → `Bypass` plays the upstream (and Tavily); `Longx.Test.ResponsesFixture`
  builds valid Responses SSE streams (`assistant_message/1`, `function_call/3`). DB tests
  must clear the seeded rows in `setup` (seeds run before the suite). End-to-end:
  `test/longx/codex/gateway_e2e_test.exs` (`:integration`, real codex → real endpoint on a
  random Bandit port → Bypass) and `gateway_live_test.exs` (`:live`, real DeepSeek + Tavily,
  needs `DEEPSEEK_API_KEY` / `TAVILY_API_KEY`).
- Never run the real `codex` binary in the unit suite. Real-Codex tests are
  `@tag :integration`, excluded by default (`test_helper.exs`); run them with
  `mix test --include integration`.
- **Look at it in a real browser** before calling a screen done: `node scripts/browse.mjs
  <url> phone|desktop out.png` (playwright, in `assets/`) loads the page as an iPhone 13 or a
  1280px desktop, prints console/page errors and any element wider than the viewport, and
  saves a screenshot to read back. Point it at the running dev server (never start a second
  one on 7788 if it is already up).
- TypeScript/React → also test-first: vitest + testing-library in `assets/` (`npm test`).
  Pure code in `js/core/` is unit-tested directly; pages render the real route tree with
  `renderAt(path)` from `ui/test-utils.tsx`, mocking `@/ash_rpc` (and `@/core/socket`) with
  `vi.mock`; `setViewport(390)` for phone-width assertions.
- `mix test` runs `ash.setup --quiet` first; the test DB is `longx_test.db` (SQLite) —
  avoid `async: true` on DB-backed tests. Prefer `start_supervised!/1`; never `Process.sleep`
  in tests (monitor / `assert_receive` instead). A test that points a global directory
  (the memory's) at a tmp dir of its own removes it with `Longx.Test.TmpDirs.rm_rf!/1`
  (retries): an async test starting a thread meanwhile re-creates the memory repository
  through `Memory.instructions/1`, and a plain `rm_rf!` failed the cleanup on CI.

## Dev server

- **Port 7788, bound to 0.0.0.0** — the dev box is reached over the LAN. This is set in
  `config/dev.exs` (`http: [ip: {0, 0, 0, 0}, port: 7788]`); the `PORT` env var only applies
  to prod (`config/runtime.exs`). Never change it and never fall back to `localhost:4000`.
  Reach it at `http://<lan-ip>:7788`.
- Start: `mix phx.server` (or `iex -S mix phx.server`). Run it in the background when you
  need the terminal; check first that the port is free: `ss -ltnp | grep ':7788'`.
- **Stop: only kill the process that owns port 7788.**

      fuser -k 7788/tcp            # or: kill $(lsof -ti tcp:7788)

  Other Elixir/BEAM apps run on this machine. **Never** use `pkill beam`, `pkill -f mix`,
  `pkill -f elixir`, `pkill -f phx.server`, `killall erl`/`beam.smp`, or anything else that
  matches by process name. Likewise never kill `codex` processes you did not start.
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
