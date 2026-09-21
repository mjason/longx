// wait_until: the agent's own alarm — a once watch — comes back as a turn even
// though the conversation was off duty (the tool puts it on duty), and a time
// already past is refused with the clock so the model can retry.
import { expect } from "../lib.mjs";

export async function run(h) {
  await h.project();
  const t = await h.thread();
  await h.send(
    t.id,
    "调用 wait_until 工具：at 设为大约 1 分钟之后的时刻（ISO 8601，带时区偏移；如果工具回答说这个时间在过去，就按它回答里给出的当前时间加 1 分钟再调一次），message 写“闹钟到了”。写完就结束这一轮，只回复“等着”。不要做别的事。",
  );
  await h.idle(t.id);
  const dir = await h.rpc("directory", { projectId: h.projectId }, ["sessions"]);
  const entry = dir.sessions.find((s) => s.threadId === t.id);
  expect(entry && entry.onDuty === true, "wait_until put the session on duty");

  // the watch fires within a minute's tick and lands once the session is idle
  const turns = await h.idle(t.id, 240_000, 2);
  expect(turns.some((x) => /定时触发/.test(x.userText || "")), "the alarm came back as a turn");
  const page = h.page;
  await h.open(page, `/p/${h.slug}/t/${t.id}`);
  expect((await page.getByText(/闹钟到了/).count()) >= 1, "the alarm's message is on the page");
  await h.shot(page, "alarm");
}
