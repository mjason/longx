// A background job: the agent starts it by name and ends its turn; the job's
// end wakes the agent with a turn of its own, drawn as a marker (后台任务 … 结束)
// instead of a bubble from the person; `jobs` lists it as exited.
import { expect } from "../lib.mjs";

export async function run(h) {
  await h.project();
  const t = await h.thread();
  await h.send(
    t.id,
    "用 start_job 在后台启动一个名为 tally 的任务，命令是 `sleep 20; echo tally-finished; exit 3`。启动后就结束这一轮，只回复“已启动”。等它结束你会被唤醒：那时用一句话告诉我它的退出码。",
  );
  const first = await h.idle(t.id);
  expect(first[0].status === "completed", `first turn: ${JSON.stringify(first)}`);

  // the end comes back as a turn of its own, named after the job
  const turns = await h.idle(t.id, 180_000, 2);
  const woken = turns.find((x) => /后台任务结束/.test(x.userText || ""));
  expect(woken, `the job's end came back as a turn: ${JSON.stringify(turns)}`);
  expect(woken.status === "completed", `the woken turn: ${JSON.stringify(woken)}`);

  const page = h.page;
  await h.open(page, `/p/${h.slug}/t/${t.id}`);
  const marker = page.getByTestId("job-notice").first();
  await marker.waitFor({ timeout: 30_000 });
  const label = await marker.textContent();
  expect(/后台任务 tally 结束/.test(label) && /退出码 3/.test(label), `the marker: ${label}`);
  // the notice the model read opens under the marker
  await marker.getByRole("button").click();
  await page.getByText(/tally-finished/).first().waitFor({ timeout: 5_000 });
  expect((await page.getByText(/3/).count()) >= 1, "the answer names the exit code");
  await h.shot(page, "job");
}
