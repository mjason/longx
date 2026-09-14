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
    (`:commit` | `:ask` | `:off`). Whether it is a git repo is read live (`git_info/1`), never
    stored; `init_git/1` sets git up with `Longx.Git.Ignore.default/0` and a first commit.
    The UI warns when a project has no git.
  - **Each project has its own codex process and its own `CODEX_HOME`**
    (`Longx.Codex.Pool`, below). `Projects` never needs a `conn:` — `start_thread/2` takes
    the project's pooled connection, `send_message/3` the connection hosting the thread
    (resuming it on the project's codex first when nobody hosts it, i.e. after a restart);
    tests pass `conn:` to use their own fake. The codex is a project resource:
    `codex_info/1` (home path, size, sqlite files, worker status incl. OS pid), `stop_codex/2`
    (refuses while a turn runs unless `force: true`), `restart_codex/1`,
    `clear_codex_history/1` (stop + delete codex's state in the home, keep our config; the
    threads become `:unrecoverable`), `reset_codex_home/1` (whole directory), archive stops
    the worker and keeps the home, `delete_project/2` needs `confirm: true` and removes the
    home (never the working directory).
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
    real one). **Slash commands of the composer**: `compact_thread/2` (`thread/compact/start`,
    refused while a turn runs; codex marks the fold with a `contextCompaction` item) and
    `review_thread/3` (`review/start` with `delivery: inline` — the review is a turn of the
    thread: a Turn row with `user_text` "/review …", bookmarked like any turn but **never
    committed first**, since a review of the uncommitted changes needs them uncommitted;
    targets `:uncommitted` | `{:commit, sha}` | `{:base_branch, name}` | `{:custom, text}`).
    Over RPC: `images` on `send_message`, `compact_thread`, `review_thread` (`target` +
    `value`). `delete_thread/1`
    removes the row and its turns (not while a turn runs; codex's own copy stays — the
    project-level wipe is `clear_codex_history/1`).
  - **Opening a thread** (`LongxWeb.ThreadChannel` join → `Projects.host_thread/1`): a
    thread nobody hosts is resumed on its project's codex; an *empty* one codex cannot
    resume (it only writes a thread to disk on its first turn) is started again under a
    new codex id (`Thread` action `rehost`; the join reply carries the id to follow);
    `:unrecoverable`/`:archived` threads join read-only. A resume (`ThreadState.backfill`)
    and a dying connection (`Connection.terminate` → `withdraw_inbound`) both withdraw
    pending approvals nobody can answer any more.
  - **When codex dies** (`Longx.Projects.Tracker` on `"codex:connection"`): `:down` → every
    `:in_progress` turn of that project fails with "codex restarted…", its `:active` threads
    become `:disconnected`; `:ready` → those are `thread/resume`d on the new process (→
    `:idle`) or marked `:unrecoverable`. Idle threads are resumed lazily by `send_message/3`.
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
- **Memory, two layers.** (1) *Project memory is codex's own*: `Home.prepare/1` writes
  `features.memories = true` and `[memories] dedicated_tools = true` into every home
  (`config :longx, Longx.Codex.Home, memories: false` turns it off), so codex runs its
  extraction / consolidation pipeline per project (at root-session start, on rollouts idle
  ≥ 6 h, through our gateway — it costs tokens) and injects its read path (memory summary
  + "grep MEMORY.md"). Its **dedicated tools stay off** (`[memories] dedicated_tools =
  false`): they would hand the model a second "remember this" (`memories.add_ad_hoc_note`,
  into the project's home) beside Longx's global `memory.note`, and asked to remember, a
  model picked codex's. Verified against the real binary in `gateway_e2e_test`: the
  `memories` namespace is not offered, ours is; codex 0.154 emits **no item** for its own
  memory tool calls anyway, so the UI could not have shown them. `clear_codex_history` keeps
  `memories/` (what codex learned is not history; `reset_codex_home` wipes it). (2) *Global
  memory is Longx's*: `Longx.Memory` — one directory across projects and homes
  (`config :longx, Longx.Memory, dir:`; dev `data/memory`, prod `$LONGX_DATA_DIR/memory`),
  a git repository where every write is a commit: `MEMORY.md` (the curated part) +
  `notes/<utc ts>-<slug>.md` (the append-only inbox, front matter `at` / `project` /
  `thread`). `instructions/1` (how to use it, the index, the latest 20 notes; capped at
  32 KB) goes to every new thread as `thread/start.developerInstructions` unless
  `Project.global_memory` is false; the `memory.*` tools (`lib/longx/tools/memory/`:
  `note` — when the person says remember / forget / from now on — `search`, `read`)
  are Elixir tools in the `memory` namespace, on by default (`enabled_by_default?/0`, a
  new optional `Longx.Codex.Tool` callback the registry sync honours; a switch someone
  turned off stays off; `enabled_tool_names/0` syncs the registry first so a default-on
  tool counts before anyone opened the tools page). **`Project.tools == []` means the
  globally enabled set** (`start_thread` resolves it) — a project never has to know about
  a new default-on tool; "none" is a decision for the tools page. The instructions name
  the tools as functions in the `memory` namespace, not as `memory.note` in backticks:
  DeepSeek Flash read the latter as a shell command and wrapped it in `exec_command`.
  Live-checked: "记住…" → one `memory.note` call → a note with provenance. RPC: `memory_index` / `memory_write_index` / `memory_notes` /
  `memory_search` / `memory_delete_note` on `Longx.System` — no page yet. Not built:
  automatic extraction into the global memory and consolidation of notes into
  `MEMORY.md` (a note is handed to the model raw until then).
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
    plus optional `reasoning_effort` (free string, what the model advertises),
    `reasoning_summary` (codex's enum) and `max_output_tokens`).
    `Longx.AI.resolve_target/0` = default model + its provider's decrypted key. Seeds
    (`priv/repo/seeds.exs`, run by `mix ash.setup`/`mix test`) create DeepSeek +
    `deepseek-flash` as default, taking the key from `DEEPSEEK_API_KEY`. Columns added
    after rows existed get a backfill migration (`kind` for api.openai.com rows, `slug` from
    `upstream_id`) — a new NOT NULL column needs a `default:` in the migration (SQLite).
  - **What codex is told about a model** comes from the row, per thread:
    `Longx.AI.thread_options/1` (slug or nil for the default → `model:` only when explicit,
    `model_context_window:`, `reasoning_effort:`, `reasoning_summary:`, `web_search:`) is
    what `Longx.Projects.start_thread/2` and fork pass to `Longx.Codex.Thread.start/1`, which
    turns them into `thread/start.config` overrides — the same dotted keys as `codex -c`
    (`model_reasoning_effort`, `web_search`, `features.standalone_web_search`, …; verified
    against the bundled binary in `gateway_e2e_test`). `turn_options/1` (`model:`, `effort:`,
    `summary:`) goes on `turn/start` when a turn switches models. `max_output_tokens` is not
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
    `:hosted` when the model's provider has `supports_hosted_web_search` (OpenAI —
    the Responses API runs `web_search` inside the provider; config `web_search = "live"`),
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
    thread view's `plan`. Dev aid: `config :longx, Longx.AI.Gateway, dump_requests_to:`
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
    `apply_patch` helper on PATH under CODEX_HOME); the `custom`/freeform tool is OpenAI-only.
  - Upstreams are all OpenAI **Responses API** (codex 0.154 dropped `wire_api = "chat"`):
    OpenAI `https://api.openai.com/v1`, DeepSeek `https://api.deepseek.com/v1`, GLM
    `https://open.bigmodel.cn/api/paas/v4`. Adding a provider = a DB row, no code.
  - `Longx.Codex.Home` writes our own `CODEX_HOME` (`data/codex_home`, prod
    `$LONGX_DATA_DIR/codex_home`; never `~/.codex`, never a tmp dir) with a generated
    `config.toml`: one provider `longx` → `http://127.0.0.1:<port>/ai/v1`,
    `env_key = LONGX_GATEWAY_TOKEN`, `requires_openai_auth = false` → **codex needs no
    login**. `Home.prepare/1` returns the env to spawn codex with.
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
    `max_uptime_ms` (12 h) / `max_rss_bytes` (2 GiB, whole tree) / `max_turns` (200) — the
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
  - `Longx.Codex.Sandbox` — codex sandboxes commands itself (Linux bubblewrap from the
    bundle, macOS seatbelt, Windows restricted token); bubblewrap needs unprivileged user
    namespaces (WSL1, most containers, hardened distros refuse → codex rejects every sandboxed
    command at turn time). `probe/0` runs the bundled `bwrap` once at boot (a `Task` in the
    tree; non-Linux is assumed ok), `report/0`/`status/0` are cached for the UI to warn.
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
    only events with `seq > snapshot.seq`.** `Thread.resume/2` rebuilds the view from
    `thread/read`. Nothing is persisted to the DB yet; codex's own sqlite in CODEX_HOME is the
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
    `onDirtyTree` for commit / ignore and resends), `onCancel` → `interruptTurn`,
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
    door to open/create), `pages/ProjectWizard` (two steps: `components/DirectoryPicker` on
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
    `frame/StatusStrip` (HEAD, codex, memory, sandbox warning).
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
    not, last error / check) with its models (slug, upstream id, window, effort, the
    default starred; 检测 = `check_model`, 设为默认, edit / delete in a menu) and dialogs
    to add / edit a provider (slug derived from the name on create) or a model; the
    search provider's key below. Deletes confirm; the default model and its provider
    refuse (`delete_model` / `delete_provider` are guarded actions apart from the plain
    `destroy`; a provider's delete cascades to its models). `settings/ToolsSection` — the
    registry's catalogue with a switch per tool (`set_tool_enabled`).
    `settings/SandboxSection` — the bwrap probe's verdict with 重新检测 (`probe_sandbox`).
    Hooks in `core/ai.ts` (`useProviders`, `useModelRows`, `useSearchProviders`,
    `useTools`, `useAiActions`, `useProbeSandbox`; every write invalidates `["ai"]` and
    the composer's model list). Appearance is the theme,
    `components/CommandPalette` (⌘K, desktop), `sonner` toasts for codex down/ready.
    `routes.tsx` (react-router, browser history; tests use a memory router via
    `ui/test-utils.tsx`, shared `vi.mock` factories in `ui/test-mocks.ts`), `shell/` (Shell,
    TopBar `wide` for the IDE window, Page, BottomBar — **fixed at the bottom on every screen
    size**, a dialog footer: an action must never depend on the page scrolling to be reached;
    long lists scroll in their own box — banners), `components/ui/` (shadcn,
    added with `npx shadcn@latest add …` in `assets/`; `components.json` maps
    `@/ui/components`, `@/lib/utils`), `strings.ts` (all UI copy, zh-CN). `core/theme.ts`
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
    or the project defaults, sent with every message — and the turn's state) /
    `ComposerTrailing` (the `context-display` ring — codex's last-turn token usage
    against the `modelContextWindow` it reports, `contextUsage(view)` — and the per-turn
    model with its reasoning effort) are slots our `thread.aui` copy adds, as are
    `ComposerPopovers` and `UserText`. **The composer has the catalog's Composer
    element's full set** (https://www.assistant-ui.com/elements/composer, all wired
    through the runtime, nothing hand-rolled): **attachments** — the runtime's
    `adapters.attachments` is `CompositeAttachmentAdapter([SimpleImage, SimpleText])`
    (built once in `useCodexRuntime`, like everything the adapter is made of), so the
    `+` button (`ComposerAddAttachment` from `attachment.aui`), paste and drop onto the
    bar stage files as tiles; on send `adapter.ts`'s `inputOf` puts images on the RPC as
    `images` (data urls) and appends text files to the text; a sent image comes back in
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
    `ProjectWindow` is `h-dvh`: the thread scrolls in its own viewport, never the page. Headers and bars are
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
`.github/workflows/ci.yml` runs the precommit set on every push / PR (bundled git and
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
  in tests (monitor / `assert_receive` instead).

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
