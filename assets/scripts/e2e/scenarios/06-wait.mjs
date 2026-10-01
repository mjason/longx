// wait_until: the agent's own alarm — a once watch — comes back as a turn even
// though the conversation stays off duty (a bound callback), and a time
// already past is refused with the clock so the model can retry.
import fs from "node:fs";
import path from "node:path";
import { BASE, OUT, expect } from "../lib.mjs";

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
  expect(entry && entry.onDuty === false, "wait_until keeps its creator off duty");

  // the watch fires within a minute's tick and lands once the session is idle
  const turns = await h.idle(t.id, 240_000, 2);
  expect(turns.some((x) => /定时触发/.test(x.userText || "")), "the alarm came back as a turn");
  const after = await h.rpc("directory", { projectId: h.projectId }, ["sessions"]);
  expect(after.sessions.find((s) => s.threadId === t.id)?.onDuty === false, "its own callback did not open the session to other agents");
  const page = h.page;
  await h.open(page, `/p/${h.slug}/t/${t.id}`);
  expect((await page.getByText(/闹钟到了/).count()) >= 1, "the alarm's message is on the page");
  await h.shot(page, "alarm");

  // The original regression: a hand-written watch, not wait_until, also
  // returns to its off-duty author. Its provenance is the real patch tool.
  const author = await h.thread();
  const at = new Date(Date.now() + 60_000).toISOString();
  await h.send(author.id,
    `请用 apply_patch 新建 .longx/local/watches/callback_progress.exs，模块 CallbackProgress，use Longx.Agent.Watch，once "${at}"。run(ctx) 调用 send(ctx, :callback, "手写watch进度回调已到，请只回复收到，不要另建定时任务")，返回 {:ok, %{}}。创建后调用 watch_run("callback_progress") 试跑，随后结束本轮。不要用 wait_until 代替，不要设置 handle、值班或 goal，不要等待。`);
  await h.idle(author.id);
  const beforeCallback = await h.rpc("directory", { projectId: h.projectId }, ["sessions"]);
  expect(beforeCallback.sessions.find((s) => s.threadId === author.id)?.onDuty === false, "the hand-written watch's author remains off duty");
  const writtenTurns = await h.idle(author.id, 240_000, 2);
  expect(writtenTurns.every((turn) => turn.status === "completed"), "the writing turn and its callback both completed");
  expect(writtenTurns.some((turn) => turn.userText === "（定时触发）callback_progress"), "the manual watch returned to its author");
  const watches = await h.rpc("list_watches", { projectId: h.projectId }, ["name", "runs", "sends", "lastError"]);
  const progress = watches.find((watch) => watch.name === "callback_progress");
  expect(progress?.runs === 1 && progress.sends === 1 && progress.lastError === null, "the real manual callback was delivered exactly once");
  const reportUrl = `${BASE}/api/p/${h.slug}/t/${author.id}?full=1`;
  const report = await (await page.request.get(reportUrl)).json();
  expect(report.turns.list[0].items.some((item) =>
    item.type === "fileChange" && item.changes?.some((change) => change.kind === "add" && change.path.endsWith("/watches/callback_progress.exs")),
  ), "the watch was actually created through apply_patch");
  const afterCallback = await h.rpc("directory", { projectId: h.projectId }, ["sessions"]);
  expect(afterCallback.sessions.find((s) => s.threadId === author.id)?.onDuty === false, "the callback never changed the duty switch");
  await h.open(page, `/p/${h.slug}/t/${author.id}`);
  await h.shot(page, "manual-callback");

  // A file written outside the agent tools is not silently adopted. The
  // model sees a failed watch_run with the binding reason, not a success
  // card containing an obscure error.
  fs.writeFileSync(path.join(h.root, ".longx/local/watches/legacy_callback.exs"), `defmodule LegacyCallback do
  use Longx.Agent.Watch
  once "2030-01-01T00:00:00Z"
  def run(ctx) do
    send(ctx, :callback, "legacy callback")
    {:ok, %{}}
  end
end
`);
  await h.send(author.id, "请只调用 watch_run，name=legacy_callback，然后根据工具返回解释为什么不能回调。不要修改或删除文件，不要开启值班，不要建立新任务。");
  await h.idle(author.id, 180_000, 3);
  const rejected = await (await page.request.get(reportUrl)).json();
  const call = rejected.turns.list.at(-1).items.find((item) =>
    item.type === "dynamicToolCall" && item.tool === "watch_run" && item.arguments?.name === "legacy_callback",
  );
  expect(call?.success === false && JSON.stringify(call).includes("no creator binding"), "the real tool reported its binding failure to the model");
  const untouched = (await h.rpc("list_watches", { projectId: h.projectId }, ["name", "runs", "sends", "lastError"])).find((watch) => watch.name === "legacy_callback");
  expect(untouched?.runs === 0 && untouched.sends === 0 && untouched.lastError === null, "the failed dry run did not change the watch state or send anything");
  fs.writeFileSync(path.join(OUT, `${h.name}-callback-verified.json`), JSON.stringify({ waitUntilOffDuty: true, manualCallback: progress, legacyDryRun: untouched, rejectedCall: call }, null, 2) + "\n");
  await h.open(page, `/p/${h.slug}/t/${author.id}`);
  await h.shot(page, "callback-error");
}
