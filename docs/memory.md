# Memory as maintained knowledge

[Back to Longx](../README.md)

Longx makes long-term agent memory an explicit collection of Markdown documents.
Useful decisions, proven procedures, preferences, and lessons can be written down as
work happens, inspected by people, corrected, and reused in later conversations.
This is project knowledge development, not simply saving a longer chat history.

## Choose the owner

| Tool path | Storage | Intended use |
| --- | --- | --- |
| `local/<topic>/<name>.md` | `.longx/local/knowledge/` in the project | Machine-local findings and drafts; default write destination |
| `project/<topic>/<name>.md` | `.longx/shared/knowledge/` in the project | Reviewed knowledge the person wants to share with the team |
| `global/<topic>/<name>.md` | `<data>/agent/knowledge/` | Personal preferences and machine knowledge across projects |
| `longx/<topic>/<name>.md` | Longx's bundled knowledge | Read-only guidance for using and extending Longx |

Local notes are gitignored. Review and promote them to the project's shared tree when
they should become team knowledge, then commit them using your normal Git workflow.
Writing project knowledge does not automatically create a project commit.

The global knowledge directory is a separate Git repository when Git is available:
each write is committed. Without Git, it remains a plain directory of Markdown files.
Back it up with the application data. Shared project knowledge moves with the project
repository; local and global notes do not automatically follow a clone.

Keep secrets in Longx credentials, not in knowledge files.

## Write a small, useful document

Every new document needs a topic and front matter with a title and summary. For example,
the tool path `local/testing/checks.md` maps to
`.longx/local/knowledge/testing/checks.md`:

```markdown
---
title: Verification workflow
summary: Checks to run before accepting a change
tags: [testing]
always: false
---

Run the relevant tests, then the full project checks before reporting completion.
```

Prefer improving an existing document to accumulating duplicate notes. Record why a
decision was made, how a procedure was verified, and any conditions under which it applies.
A how-to or skill can be a knowledge document; it does not require a separate runtime.
Standard `.agents/skills/` documents are another file convention, not automatically part
of this knowledge index: the built-in index reads the four roots above.

## Retrieve deliberately

At a request, the Knowledge plug includes a compact index: one line per topic rather
than every document body. A topic's `README.md` can supply its title and summary.

The agent can use:

- `knowledge_read` with `path: "local/testing"` to list a topic's documents.
- `knowledge_read` with `path: "local/testing/checks.md"` to read a document's body.
- `knowledge_search` with `query: "verification workflow"` to find matching lines.
- `knowledge_write` with a path and complete front-matter document to create or replace a note.

Built-in search is text matching: it finds lines containing every query word, including
titles and summaries. It does not require embeddings or a vector database.

`always: true` is for short instructions that genuinely matter on every request.
The default plug budget is 16 KiB for these bodies and 200 topic-index entries; omitted
material remains available through the tools. These are configurable plug options.
Do not turn the whole knowledge library into an always-loaded prompt.

The agent is instructed to read applicable documents before acting and to keep durable
findings up to date. These are behavioral instructions, not a guarantee that a model
will retrieve or obey every relevant note.

## Correct knowledge instead of treating it as truth

A saved note is evidence of what was learned, not proof that the system still behaves
that way. Verify consequential or changeable claims against the current source or system.
When a note is wrong, fix the note. Current shipped guidance takes precedence over an
older note that contradicts it.

Conversation transcripts record the interaction. Compaction makes a handoff summary
to keep the current conversation usable within a model's context window. Neither
automatically turns that conversation into a maintained knowledge document:
the durable lesson needs to be written explicitly.

Implementation: [`Longx.Agent.Knowledge`](../lib/longx/agent/knowledge.ex) and the
[`Knowledge` plug](../lib/longx/agent/plugs/knowledge.ex).
