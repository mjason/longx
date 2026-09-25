// What arrives while a turn runs waits above the composer, never in it; a stop
// is an interrupt that leaves the composer alone and a stopped-run card under
// the turn (继续 / 丢弃); after the person's stop what waits holds until they
// let it in. Here a background job ends while a foreground command runs.
import { expect, sleep } from "../lib.mjs";

export async function run(h) {
  await h.project();
  const t = await h.thread();
  await h.send(
    t.id,
    "按顺序做两件事：1) 用 start_job 启动名为 tick 的后台任务，命令是 `sleep 5; echo tick-done`；2) 然后立刻用 exec_command 在前台运行 `sleep 60`（不要用 start_job，不要改成别的命令）。两件都做完后只回复 done。",
  );
  const page = h.page;
  await h.open(page, `/p/${h.slug}/t/${t.id}`);
  const composer = page.getByRole("textbox", { name: "随心输入" });

  // the job ends while `sleep 60` runs: its own row above the composer
  const row = page.getByTestId("waiting-message").first();
  await row.waitFor({ timeout: 120_000 });
  expect(/后台任务 tick/.test(await row.textContent()), `the row names the job: ${await row.textContent()}`);
  expect((await composer.inputValue()) === "", "the composer stays empty");
  await h.shot(page, "waiting");

  // the person stops the turn: an interrupt, the composer untouched, the card, the list paused
  await page.getByRole("button", { name: /停止/ }).first().click();
  const card = page.getByTestId("stopped-turn");
  await card.waitFor({ timeout: 30_000 });
  expect(/你停止了这一轮/.test(await card.textContent()), `the card: ${await card.textContent()}`);
  expect((await composer.inputValue()) === "", "a stop never writes the composer");
  await page.getByText("你停止了这一轮，这些消息等你继续再处理").waitFor({ timeout: 10_000 });
  const stopped = await h.idle(t.id, 30_000);
  expect(stopped[0].status === "interrupted", `after stop: ${JSON.stringify(stopped)}`);
  // nothing starts by itself while it is paused
  await sleep(4000);
  const still = await h.rpc("list_turns", { threadId: t.id }, ["id", "status"]);
  expect(still.length === 1, `no turn started by itself after the stop: ${JSON.stringify(still)}`);
  await h.shot(page, "stopped");

  // 立即插入: the job's end becomes a turn of its own now
  await page.getByTestId("waiting-message").first().getByRole("button", { name: /立即插入/ }).click();
  const after = await h.idle(t.id, 180_000, 2);
  const woken = after.find((x) => /后台任务结束/.test(x.userText || ""));
  expect(woken, `the released job's end ran as a turn: ${JSON.stringify(after)}`);
  await page.getByTestId("waiting-messages").waitFor({ state: "detached", timeout: 10_000 });

  // a reply stopped mid-way and thrown away: 丢弃 takes the turn out, the composer stays empty
  await h.send(t.id, "写一首 40 行的中文长诗，慢慢写。");
  await page.getByRole("button", { name: /停止/ }).first().waitFor({ timeout: 30_000 });
  await sleep(1500);
  await page.getByRole("button", { name: /停止/ }).first().click();
  const card2 = page.getByTestId("stopped-turn");
  await card2.waitFor({ timeout: 30_000 });
  await h.idle(t.id, 30_000, 3);
  await card2.getByRole("button", { name: "丢弃" }).click();
  await page.getByText("写一首 40 行的中文长诗，慢慢写。").waitFor({ state: "detached", timeout: 15_000 });
  expect((await composer.inputValue()) === "", "丢弃 never writes the composer");
  await h.shot(page, "discarded");
}
