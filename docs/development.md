# Development and contributing

[Back to Longx](../README.md) · [Project guidance](../AGENTS.md)

Using and customizing an installed agent does not require building Longx itself.
Project tools, roles, and loop strategies belong in the project's `.longx/` tree;
start with [Writing plugs](../priv/agent/knowledge/writing-plugs.md).

## Run Longx from source

The CI toolchain is Elixir 1.19 / OTP 28, Node.js 22, and Go as specified by
[`native/shim/go.mod`](../native/shim/go.mod) (currently 1.25). Go must be on PATH:
`mix compile` builds the command shim. Install the machine's `git` as well.

```sh
mix setup
mix phx.server
```

The development page is at `http://localhost:7798`; Vite serves hot-reloaded assets on
7799. Production uses 7788. For testing from a phone on your LAN:

```sh
LONGX_DEV_HOST=<lan-ip> mix phx.server
```

Configure providers and model aliases in the UI. Local development state is stored in
`longx_dev.db` and `data/`, both ignored by Git.

## Change, test, review

Follow the conventions in [AGENTS.md](../AGENTS.md).
Framework references are in [Ash skills](../.agents/skills/ash-framework/SKILL.md) and
[Phoenix skills](../.agents/skills/phoenix-framework/SKILL.md).

Use red → green → refactor for code changes:

```sh
mix test test/path/to/file_test.exs
mix precommit
mix dialyzer
```

`mix precommit` covers compilation, formatting, Go checks, schema generation checks,
frontend checks, and the unit suite. Dialyzer is a separate check before merging.
Do not run two Elixir test suites at once; they share a SQLite test database.
Integration and live-provider tests are opt-in; see the
[testing reference](reference.zh-CN.md#测试).

Regenerate dependency guidance with `mix usage_rules.sync` after dependency changes.
It updates the managed sections of `AGENTS.md` and `.agents/skills/`.

## Reuse the runtime when extending it

The agent runtime is `lib/longx/agent.ex` plus `lib/longx/agent/kernel/`.
Most behavior belongs in plugs, not new branches in the state machine.
Use phases and effects for policies, task-based tools for work, role definitions for
child agents, and jobs/watches for work that outlives a turn. Keep callbacks non-blocking.

If you override `call/2` in a plug that declares instructions or tools, call
`Longx.Agent.Plug.mount(step, __MODULE__)` in its `:request` handler to mount them.
Turn-local strategy state belongs in `step.state`; do not reset it on every request.

- [Plug API and project layout](../priv/agent/knowledge/writing-plugs.md)
- [Kernel design patterns (中文)](agent-kernel-design.md)
- [Kernel design history (中文)](agent-kernel-plan.md)
- [Operations and extension reference (中文)](reference.zh-CN.md)

## Build a release

```sh
MIX_ENV=prod mix assets.build
MIX_ENV=prod mix release
```

The result is `_build/prod/rel/longx`. Release automation is in
[`.github/workflows/release.yml`](../.github/workflows/release.yml).
