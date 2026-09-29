// A conservative guard for review-sensitive agent instructions. Run this
// before a workflow continues; finding a candidate change requires asking the
// person for confirmation. After they approve it, pass --confirmed (or set
// LONGX_PROMPT_CHANGES_CONFIRMED=1) for the guarded command.
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function git(...args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
}

const changed = new Set([
  ...git("diff", "--name-only", "HEAD", "--").split("\n"),
  ...git("ls-files", "--others", "--exclude-standard").split("\n"),
].filter(Boolean));

const isPromptPath = (file) =>
  /(^|\/)(CLAUDE|AGENTS)\.md$/i.test(file) ||
  /(^|\/)\.claude\//i.test(file) ||
  /(^|\/)\.longx\//i.test(file) ||
  /^priv\/agent\//i.test(file) ||
  /^lib\/longx\/agent\//i.test(file) ||
  /^assets\/scripts\/e2e\/scenarios\//i.test(file) ||
  /^test\/support\/fixtures\/.*(prompt|instruction|system)/i.test(file) ||
  /(^|\/)(prompt|prompts|base_prompt|instructions_template|summary_prefix|continuation)(\.|\/|$)/i.test(file);

const candidates = [...changed].filter(isPromptPath).sort();

if (candidates.length === 0) {
  console.log("Prompt guard: no prompt or agent-instruction changes detected.");
  process.exit(0);
}

console.error("WARNING: prompt/agent-instruction changes detected:");
for (const file of candidates) console.error(`  ${file}`);

if (process.argv.includes("--confirmed") || process.env.LONGX_PROMPT_CHANGES_CONFIRMED === "1") {
  console.log("Prompt guard: explicit confirmation override supplied.");
  process.exit(0);
}

console.error("Stop here and ask the person to review and confirm these changes.");
console.error("After confirmation, rerun with --confirmed or LONGX_PROMPT_CHANGES_CONFIRMED=1.");
process.exit(2);
