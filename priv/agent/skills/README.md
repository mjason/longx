# Skills prompt provenance

`prompt.md` follows `SKILLS_HOW_TO_USE_WITH_HOST_ALIASES` in
`codex-rs/ext/skills/src/catalog_prompt.rs`, OpenAI Codex commit
`3e238776e857eccd3bde6bff3026e2e9798f6524` (Apache-2.0; see `NOTICE`).

The source usage text is locked in `test/support/fixtures/codex_skills_usage.md`.
The alignment test permits only replacing short/root-aliased paths with absolute
filesystem paths. Trigger rules, complete instruction reads, relative reference
resolution, main-agent responsibility, announcements, sequencing, context hygiene,
and fallback wording are unchanged.

Longx-specific tool names and metadata/permission guidance are added separately by
the Skills plug, not silently substituted into the Codex fixture. There are no cloud
or executor-package locators in this first project-filesystem implementation.

Placement follows Codex's capability slot, not the project/role instruction slot.
In the pinned Codex source, `core/src/session/world_state.rs` adds extension
capability sections after environment/apps/plugins/tools sections and before
multi-agent sections. Longx places Skills after Credentials (the last default
tool-capability plug) and before Agents. Project/role prompts remain beside
AGENTS.md. An order regression checks both the pipeline and final request text.
Longx still aggregates these instruction sections into its `instructions` field;
this does not claim byte-identical Codex developer/user message grouping.
