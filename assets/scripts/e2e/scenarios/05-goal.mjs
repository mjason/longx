// The goal bar: set from the page's RPC it appears with its status, paused
// and resumed from the bar, gone once complete; set active on an idle thread
// the goal starts a turn of its own.
import { expect } from "../lib.mjs";

export async function run(h) {
  await h.project();
  const t = await h.thread();
  await h.send(t.id, "只回答“ok”。");
  await h.idle(t.id);
  const page = h.page;
  await h.open(page, `/p/${h.slug}/t/${t.id}`);
  expect((await page.getByTestId("goal-bar").count()) === 0, "no bar without a goal");

  await h.rpc("set_goal", { threadId: t.id, objective: "e2e 目标", status: "paused" }, ["objective", "status"]);
  await page.getByTestId("goal-bar").waitFor({ timeout: 10_000 });
  const bar = page.getByTestId("goal-bar");
  expect(/e2e 目标/.test(await bar.innerText()), "the objective on the bar");
  expect(/已暂停/.test(await bar.innerText()), "paused");
  await h.shot(page, "paused");

  await h.rpc("set_goal", { threadId: t.id, status: "complete" }, ["objective", "status"]);
  await page.waitForFunction(() => !document.querySelector('[data-testid="goal-bar"]'), null, { timeout: 10_000 });
  await h.rpc("clear_goal", { threadId: t.id }, ["cleared"]);

  // an active goal set on the idle thread starts a turn by itself (codex: "start an
  // idle turn"), the row named after the goal; the bar goes once the model completes it
  await h.rpc(
    "set_goal",
    { threadId: t.id, objective: "回复一个字“好”，然后立刻用 update_goal 把这个目标标记为 complete。", status: "active" },
    ["objective", "status"],
  );
  const turns = await h.idle(t.id, 180_000, 2);
  expect(turns.some((x) => /目标续跑/.test(x.userText || "")), "the goal started a turn of its own");
  await page.waitForFunction(() => !document.querySelector('[data-testid="goal-bar"]'), null, { timeout: 10_000 });
  await h.rpc("clear_goal", { threadId: t.id }, ["cleared"]);
}
