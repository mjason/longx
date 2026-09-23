// The project's agent description, written while its page is open: the
// composer's model follows within seconds (no reload), and a new chat runs on
// the described model at the described level — once the page kept the
// description it loaded and a new thread froze the default model's level.
import fs from "node:fs";
import path from "node:path";
import { expect, sleep } from "../lib.mjs";

export async function run(h) {
  await h.project();
  // a model with a key and at least two levels that is not the default, at a level
  // that is not its own default — so both the model and the level can only come from the file
  const models = await h.rpc("list_models", {}, ["slug", "default", "reasoningLevels", "reasoningEffort", { provider: ["hasApiKey", "credentialId"] }]);
  const pick = models.find(
    (m) => !m.default && m.slug && (m.reasoningLevels || []).length >= 2 && (m.provider?.hasApiKey || m.provider?.credentialId),
  );
  if (!pick) {
    console.log("    (skipped: no second model with levels and a key on this server)");
    return;
  }
  const level = pick.reasoningLevels.find((l) => l !== pick.reasoningEffort);

  const page = h.page;
  await h.open(page, `/p/${h.slug}`);
  const rail = page.getByTestId("model-picker");
  await rail.waitFor({ timeout: 20_000 });

  const file = path.join(h.root, ".longx/local/agent.exs");
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `import Longx.Agent.Config\n\nagent do\n  version 1\n  extends :default\n  model "${pick.slug}", effort: "${level}"\nend\n`);

  // no reload: the page hears the file changed
  const until = Date.now() + 10_000;
  while (!(await rail.innerText()).includes(pick.slug) && Date.now() < until) await sleep(250);
  expect((await rail.innerText()).includes(pick.slug), `the composer names ${pick.slug} without a reload`);
  expect((await rail.innerText()).includes(level), `…at ${level}`);

  const box = page.getByRole("textbox").first();
  await box.fill("只回复 ok");
  await box.press("Enter");
  await page.waitForURL(/\/t\//, { timeout: 20_000 });
  const threadId = page.url().split("/t/")[1];
  const thread = await h.rpc("get_thread", { id: threadId }, ["id", "kernelThreadId"]);
  await h.idle(threadId);

  const log = await h.rpc("gateway_requests", { limit: 20 }, ["requests"]);
  const mine = log.requests.filter((r) => r.threadId === thread.kernelThreadId && r.requestKind === "agent");
  expect(mine.length >= 1, "the chat's model request is in the log");
  expect(mine.every((r) => r.model === pick.slug), `the chat ran on ${pick.slug} (got ${mine.map((r) => r.model)})`);
  expect(mine.every((r) => r.effort === level), `…at ${level} (got ${mine.map((r) => r.effort)})`);
  await h.shot(page, "described");
}
