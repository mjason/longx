// Real UI/API/job/kernel test, only against job_workflow_e2e_server.exs.
// No API or socket fixtures; the isolated server uses a deterministic local model.
import fs from "node:fs";
import assert from "node:assert/strict";
const identity = JSON.parse(fs.readFileSync(process.env.LONGX_JOB_E2E_IDENTITY, "utf8"));
assert.equal(identity.test_only, true);
assert.equal(identity.kind, "job-workflow");
assert.match(identity.url, /^http:\/\/127\.0\.0\.1:\d+$/);
process.env.LONGX_E2E_URL = identity.url;
const { Harness } = await import("./e2e/lib.mjs");
const h = new Harness("job-workflow-live");
await h.start();
try {
  const { page } = h;
  await page.evaluate(() => localStorage.setItem("longx:language", "zh-CN"));
  const url = `${identity.url}/p/${identity.project.slug}/t/${identity.thread.id}`;
  await page.goto(url);
  await page.getByTestId("job-work-status").waitFor();
  assert.match(await page.getByTestId("turn-bar").innerText(), /等待任务结果\s+· 2/);
  const composer = page.getByRole("textbox", { name: "随心输入" });
  await composer.fill("保留草稿");
  assert.equal(await page.locator("[data-sonner-toast]").filter({ hasText: "留意任务栏" }).count(), 0, "typing must be quiet");
  await page.getByTestId("job-work-status").getByRole("button").click();
  assert.match(await page.getByTestId("job-work-popover").innerText(), /1 项运行中，1 项待处理/);
  assert.equal(await page.getByTestId("job-work-popover").getByTestId("thread-job-row").count(), 2);
  assert.equal(await composer.inputValue(), "保留草稿");
  await page.keyboard.press("Escape");
  await page.getByRole("button", { name: "后台 1", exact: true }).click();
  assert.match(await page.getByTestId("thread-background-popover").innerText(), /dev-service/);
  await page.getByTestId("thread-background-popover").getByRole("button", { name: "查看日志" }).click();
  await page.getByTestId("thread-background-popover").getByText("service-started", { exact: true }).waitFor();
  await page.keyboard.press("Escape");
  await page.screenshot({ path: `${identity.root}/desktop-waiting.png`, fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await composer.fill("");
  await composer.fill("手机草稿");
  assert.equal(await page.locator("[data-sonner-toast]").filter({ hasText: "留意任务栏" }).count(), 0, "phone typing must be quiet");
  await page.getByRole("button", { name: "后台 1", exact: true }).click();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
  assert.equal(overflow, false, "phone must not overflow horizontally");
  await page.screenshot({ path: `${identity.root}/phone-background.png`, fullPage: true });
  await page.keyboard.press("Escape");
  await page.getByTestId("job-work-status").getByRole("button").click();
  const running = page.getByTestId("job-work-popover").getByTestId("thread-job-row").filter({ hasText: "running-check" });
  await running.getByRole("button", { name: "停止任务", exact: true }).click();
  await page.getByRole("button", { name: "取消", exact: true }).click();
  let report = await h.rpc("project_jobs", { projectId: identity.project.id }, ["jobs"]);
  assert.equal(report.jobs.find(job => job.name === "running-check").status, "running");
  await running.getByRole("button", { name: "停止任务", exact: true }).click();
  await page.getByRole("button", { name: "确认停止", exact: true }).click();
  await page.getByTestId("job-work-status").getByText(/工作未完成/).first().waitFor();
  await page.reload();
  await page.getByTestId("job-work-status").getByText(/工作未完成/).first().waitFor();
  await page.getByTestId("job-work-status").getByRole("button").click();
  const stopped = page.getByTestId("job-work-popover").getByTestId("thread-job-row").filter({ hasText: "running-check" });
  await stopped.getByRole("button", { name: "任务用途 running-check", exact: true }).click();
  await page.getByRole("button", { name: "确认更改", exact: true }).click();
  // The UI read did not acknowledge ready-result; only the model's explicit review does.
  report = await h.rpc("project_jobs", { projectId: identity.project.id }, ["jobs"]);
  assert.equal(report.jobs.find(job => job.name === "ready-result").review, null);
  // The stopped job's callback has its own turn. Wait for that real turn to
  // finish before starting the explicit review turn.
  await h.idle(identity.thread.id, 30_000, 0);
  await page.keyboard.press("Escape");
  await composer.fill("AFTER_WORK_E2E");
  await composer.press("Enter");
  const queue = page.getByTestId("message-queue");
  await queue.getByText("AFTER_WORK_E2E", { exact: true }).waitFor();
  assert.match(await queue.innerText(), /任务收尾后自动发送/);
  const beforeReview = await h.rpc("list_turns", { threadId: identity.thread.id }, ["userText"]);
  assert.equal(beforeReview.some(turn => turn.userText === "AFTER_WORK_E2E"), false, "queued work must not send before review");
  await page.waitForFunction(() => {
    const box = document.querySelector('[data-testid="message-queue"]')?.getBoundingClientRect();
    return box && box.left >= 0 && box.right <= innerWidth;
  });
  await page.screenshot({ path: `${identity.root}/phone-work-queue.png`, fullPage: true });
  await page.getByTestId("job-work-status").getByRole("button").click();
  await page.getByTestId("job-work-popover").getByRole("button", { name: "继续检查结果", exact: true }).click();
  await page.getByText("JOB_WORKFLOW_CONFIRMED: the result has been checked.", { exact: true }).waitFor({ timeout: 15000 });
  await page.getByTestId("job-work-status").waitFor({ state: "detached", timeout: 15000 });
  await queue.waitFor({ state: "detached", timeout: 15000 });
  await h.idle(identity.thread.id, 30_000);
  const afterReview = await h.rpc("list_turns", { threadId: identity.thread.id }, ["userText"]);
  assert.equal(afterReview.filter(turn => turn.userText === "AFTER_WORK_E2E").length, 1, "queued work sends once after result review");
  await page.getByRole("button", { name: "后台 1", exact: true }).waitFor();
  await page.screenshot({ path: `${identity.root}/phone-completed-service-running.png`, fullPage: true });
  report = await h.rpc("project_jobs", { projectId: identity.project.id }, ["jobs"]);
  assert.equal(report.jobs.find(job => job.name === "ready-result").review, "complete");
  assert.equal(report.jobs.find(job => job.name === "dev-service").status, "running");
  if (h.problems.length) throw new Error(h.problems.join("\n"));
  console.log("live job workflow: desktop/390px, quiet typing, queue waits for actual model review then sends once, cancel/stop, incomplete after reload, purpose correction, background remaining — passed");
} finally {
  await h.stop();
}
