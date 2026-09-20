// Two sessions of one project: A asks B by address through send_message
// while B is on duty; the asker's page shows whom it asked and B's answer.
// Off duty, the same message is refused and the refusal is shown.
import { expect } from "../lib.mjs";

export async function run(h) {
  await h.project();
  const b = await h.thread();
  await h.send(b.id, "你叫小蓝。以后有人问你名字，就用一句话回答你是小蓝。现在只回复“好的”。");
  await h.idle(b.id);
  const dir = await h.rpc("directory", { projectId: h.projectId }, ["sessions"]);
  const entry = dir.sessions.find((s) => s.threadId === b.id);
  expect(entry && entry.onDuty === false, "a fresh session is off duty");
  await h.rpc("set_thread_on_duty", { threadId: b.id, onDuty: true }, ["id", "onDuty"]);

  const a = await h.thread();
  await h.send(a.id, `这个项目里有另一个会话，地址是 ${entry.address}。用 send_message 工具（deliver 设为 now）问它叫什么名字；等它回答后把名字告诉我。`);
  await h.idle(a.id);
  // the answer wakes A into a turn of its own
  await h.idle(a.id);

  const page = h.page;
  await h.open(page, `/p/${h.slug}/t/${a.id}`);
  const rows = page.getByTestId("tool-send-message");
  expect((await rows.count()) >= 1, "the outgoing message is a row of its own");
  expect(/问了/.test(await rows.first().innerText()), "the row says whom it asked");
  expect((await page.getByText(/小蓝/).count()) >= 1, "B's answer is on A's page");
  await h.shot(page, "asked");

  // off duty: refused, and the agent reports the refusal
  await h.rpc("set_thread_on_duty", { threadId: b.id, onDuty: false }, ["id", "onDuty"]);
  await h.send(a.id, `再用 send_message 问一次 ${entry.address}：它今天做了什么。如果发不出去，把工具返回的原话告诉我。`);
  await h.idle(a.id);
  await h.open(page, `/p/${h.slug}/t/${a.id}`);
  expect((await page.getByText(/not on duty/).count()) >= 1, "the refusal is shown");

  // the Agents window lists both with their duty switches
  await page.keyboard.press("Meta+3");
  await page.getByTestId("session-directory").waitFor({ timeout: 10_000 });
  expect((await page.getByRole("switch", { name: "值班" }).count()) >= 2, "a duty switch per session");
  await h.shot(page, "directory");
}
