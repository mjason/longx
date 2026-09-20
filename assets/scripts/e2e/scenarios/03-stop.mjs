// A running command is stopped from the page: the turn ends interrupted, the
// thread takes the next message.
import { expect, sleep } from "../lib.mjs";

export async function run(h) {
  await h.project();
  const t = await h.thread();
  await h.send(t.id, "运行 `sleep 120` 这条命令（不要改成别的），等它结束后说“done”。");
  const page = h.page;
  await h.open(page, `/p/${h.slug}/t/${t.id}`);
  // the command row appears, then the composer's stop
  await page.getByTestId("tool-command").first().waitFor({ timeout: 90_000 });
  await sleep(1000);
  await page.getByRole("button", { name: /停止|stop/i }).first().click();
  const turns = await h.idle(t.id, 60_000);
  expect(turns[0].status === "interrupted", `after stop: ${JSON.stringify(turns)}`);
  await h.send(t.id, "只回答“ok”。");
  const again = await h.idle(t.id);
  expect(again[1].status === "completed", `next turn: ${JSON.stringify(again)}`);
}
