// A fresh project, no .longx at all: asked for a custom tool, the agent reads
// the reference doc (the Local paragraph names it; the reference no longer
// rides along in every request), writes the plug and the description line,
// and uses the tool at its next step. What the person asked for — the tool's
// words — comes back.
import fs from "node:fs";
import path from "node:path";
import { BASE, expect } from "../lib.mjs";

export async function run(h) {
  await h.project();
  expect(!fs.existsSync(path.join(h.root, ".longx")), "the project starts without a .longx");

  const t = await h.thread();
  const page = h.page;
  await h.open(page, `/p/${h.slug}/t/${t.id}`);
  await h.send(
    t.id,
    "给这个项目加一个自定义工具：写一个 plug，提供工具 greet(name)，返回字符串 \"hello, <name>\"。加好之后用它对 e2e 打招呼，把工具返回的原文回复给我。",
  );
  const turns = await h.idle(t.id, 300_000);
  expect(turns[0].status === "completed", `the turn: ${JSON.stringify(turns)}`);

  // what happened, read from the API without waking anything
  const report = await fetch(`${BASE}/api/p/${encodeURIComponent(h.slug)}/t/${t.id}?turns=1`).then((r) => r.json());
  const items = report.turns.list.at(-1).items;
  const calls = items.filter((i) => i.type === "dynamicToolCall");
  const read = calls.find((c) => c.tool === "knowledge_read" && JSON.stringify(c.arguments).includes("writing-plugs"));
  expect(read, `the agent read longx/writing-plugs.md before writing the plug: ${JSON.stringify(calls.map((c) => [c.tool, c.arguments]))}`);
  const greet = calls.find((c) => c.tool === "greet" && c.status === "completed");
  expect(greet, `the new tool was called: ${JSON.stringify(calls.map((c) => [c.tool, c.status]))}`);
  const answer = items.filter((i) => i.type === "agentMessage").map((i) => i.text).join("\n");
  expect(/hello, e2e/i.test(answer), `the tool's words came back: ${answer}`);

  // the two files of a custom tool, in local/
  const plugs = fs.existsSync(path.join(h.root, ".longx/local/plugs")) ? fs.readdirSync(path.join(h.root, ".longx/local/plugs")) : [];
  expect(plugs.some((f) => f.endsWith(".exs")), `a plug file in local/plugs: ${plugs}`);
  const description = fs.readFileSync(path.join(h.root, ".longx/local/agent.exs"), "utf8");
  expect(/plug\s+\w+/.test(description), `local/agent.exs mounts it:\n${description}`);
  await h.shot(page, "plug");
}
