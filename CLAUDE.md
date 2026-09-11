# Longx

Agent application. **Ash 3 + Phoenix 1.8 (Bandit, SQLite)** backend that drives the
**OpenAI Codex app-server** (`codex app-server`, JSON-RPC) and renders the agent UI with
**React 19 + AI Elements** (https://elements.ai-sdk.dev/docs).

## Architecture

- `lib/longx/` — Ash domains & resources (`AshSqlite`). Business logic lives in Ash actions
  and is called through code interfaces — never in controllers/LiveViews.
- `lib/longx/shim.ex` + `native/shim/` (Go) — `Longx.Shim`: runs external programs through
  our own port middleware (adapted from ex_cmd/odu, see `NOTICE`). Gives back-pressured
  stdin/stdout, a separate stderr stream, `close_stdin` independent of stdout, and clean
  termination: `kill/2` SIGTERMs the child's whole process group then SIGKILLs after a grace
  period; if the owner process or the BEAM dies the shim sees its stdin close and does the
  same. Protocol is defined twice — `native/shim/proto.go` and `lib/longx/shim/proto.ex` —
  keep them in sync and bump the version in both when it changes. The binary is built by
  `Mix.Tasks.Compile.Shim` into `priv/bin/` (gitignored) on `mix compile`; **Go must be on
  PATH**. `mix precommit` also runs `gofmt`, `go vet`, `go test` in `native/shim`.
  Windows support is via `CREATE_NEW_PROCESS_GROUP` + CTRL_BREAK + `taskkill /T`.
- `lib/longx/codex/runtime.ex` — `Longx.Codex.Runtime`: the **bundled** `codex-app-server`.
  Never use the machine's `codex`. Pinned to upstream release `rust-v0.154.0`; the
  `codex-app-server-package-<target>.tar.gz` asset (bare binary + `bwrap`/`rg`/`zsh` the
  Linux sandbox needs; the only variant with published SHA256s) is downloaded by
  `mix codex.fetch`, checksum-verified against hashes pinned in the module, and unpacked to
  `priv/codex/<target>/` (gitignored; `priv` ships in `mix release`, so CI runs
  `mix codex.fetch [--target …]` before `mix release`). `mix setup` runs it too.
  `Longx.Codex.Runtime.executable/0` resolves the binary; `LONGX_CODEX_APP_SERVER` overrides.
  Bumping the version = change `@version` + the six `@sha256` entries from the release's
  `codex-package_SHA256SUMS`, then `mix codex.fetch --force`.
- `lib/longx/platform.ex` — `Longx.Platform`: runtime-safe os/arch detection and the Rust
  triple / GOOS-GOARCH naming for it. Anything that resolves a binary path at runtime goes
  through this, never through `Mix.*` (Mix is absent in releases).
- `lib/longx/codex/` (client, to be created) — Codex app-server client on top of
  `Longx.Shim`, launching `Longx.Codex.Runtime.executable/0`. The app-server speaks
  newline-delimited JSON-RPC over stdio (messages omit `"jsonrpc":"2.0"`). Protocol facts
  that shape the design:
  - Handshake: `initialize` (params `clientInfo{name,version}`, optional `capabilities`
    incl. `optOutNotificationMethods`, `experimentalApi`) → then send the `initialized`
    notification. Nothing else is accepted before that.
  - **Bidirectional**: besides notifications the server sends *requests* we must answer by
    id — approvals (`item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
    `item/permissions/requestApproval`), `item/tool/call`, `item/tool/requestUserInput`,
    `mcpServer/elicitation/request`, `account/chatgptAuthTokens/refresh`. The client must
    route these to a handler (UI via PubSub) and reply, with a timeout → `cancel`/`decline`.
  - One app-server hosts many threads (`thread/start|resume|fork|list`); turns via
    `turn/start|steer|interrupt`. Notifications carry `threadId`/`turnId`/`itemId` → PubSub
    topic per thread. Item types (`agentMessage`, `reasoning`, `commandExecution`,
    `fileChange`, `plan`, `webSearch`, `mcpToolCall`…) plus `item/*/delta` streams map
    onto AI Elements components.
  - Docs: https://learn.chatgpt.com/docs/app-server. The exact schema for the bundled
    version is authoritative over the docs:
    `priv/codex/<target>/bin/codex-app-server generate-json-schema --out DIR`
    (also `generate-ts` for the React side). Regenerate into the scratchpad/`tmp/`, don't
    commit the 4 MB output.
- `lib/longx_web/` — Phoenix web layer. Two entry points:
  - React SPA: `assets/js/index.tsx` mounts at `#app`, served with the `spa_root` layout
    (`PageController.index`). Agent chat UI lives here.
  - LiveView/HEEx pages use the `root` layout + `<Layouts.app>`.
- `assets/js/` — TypeScript/React bundled by esbuild (`--alias:@=.` so `@/…` resolves to
  `assets/`). `ash_rpc.ts` and `ash_types.ts` are **generated** by `mix ash_typescript.codegen`
  — never edit by hand; re-run after changing any RPC-exposed resource/action
  (endpoints `/rpc/run`, `/rpc/validate`).
- AI Elements components are shadcn-style source you own: add with
  `npx ai-elements@latest add <component>` (run in `assets/`), they land in
  `assets/js/components/ai-elements/`. Prerequisites (set up on first use, test-first like
  everything else): shadcn/ui `components.json` + `cn()` util, Tailwind v4 in CSS-variables
  mode, and the `ai` package. Keep them working alongside the daisyUI plugin already in
  `assets/css/app.css`. Do not hand-roll chat/message/prompt UI that AI Elements provides.

## Development workflow — TDD is mandatory

Every change follows red → green → refactor. No production code without a test that
motivated it.

1. Write a failing test first and run it: `mix test test/path/to/file_test.exs:LINE`.
   Confirm it fails for the *expected* reason.
2. Write the minimum code to make it pass.
3. Refactor while green, then run the whole suite: `mix test`.
4. Before declaring done: `mix precommit`
   (`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`).

Where tests live / what to use:

- Ash resources & actions → `test/longx/…`, `use Longx.DataCase`; call code interfaces,
  assert on results and on `Ash.Error.*` for failures. See the `ash-framework` skill
  (`references/ash/testing.md`).
- Controllers / LiveViews → `test/longx_web/…`, `use LongxWeb.ConnCase`,
  `Phoenix.LiveViewTest` + `LazyHTML`; assert on element IDs, not raw HTML.
- `Longx.Shim` → `test/longx/shim_test.exs` drives real OS processes (`cat`, `sh -c …`);
  the Go side has its own `go test` suite in `native/shim` with an in-memory host harness.
- `Longx.Codex.Runtime` → tests install from a locally built fake package tarball
  (`source: {:file, …}`); the real download is never exercised in the unit suite.
- Codex client → unit-test against a fake app-server (a tiny script that echoes JSON-RPC),
  never against the real `codex` binary in the unit suite. Real-Codex tests are
  `@tag :integration`, excluded by default (`test_helper.exs`); run them with
  `mix test --include integration`.
- TypeScript/React → also test-first. Use `vitest` + `@testing-library/react` in `assets/`
  (add on first need: `npm i -D vitest jsdom @testing-library/react --prefix assets`).
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
- Phoenix: consult the `phoenix-framework` skill for the web layer. Phoenix 1.8 rules that
  still apply: LiveView templates start with `<Layouts.app flash={@flash} …>`;
  `<.flash_group>` only inside `layouts.ex`; icons via `<.icon name="hero-…">`; form inputs
  via `<.input>` from `core_components.ex`.
- Assets: keep the Tailwind v4 import block in `app.css`
  (`@import "tailwindcss" source(none);` + `@source …`); never `@apply`; only the `app.js` /
  `index.js` / `app.css` bundles are served — no inline `<script>` in templates and no
  vendored `<script src>`; import dependencies through `assets/package.json`.
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
