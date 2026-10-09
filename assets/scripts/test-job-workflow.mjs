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
  assert.match(await page.getByTestId("job-work-status").innerText(), /1 项运行中，1 项待处理/);
  await page.getByRole("button", { name: "查看任务", exact: true }).click();
  assert.equal(await page.getByTestId("job-work-status").getByTestId("thread-job-row").count(), 2);
  await page.getByRole("button", { name: "后台 1", exact: true }).click();
  assert.match(await page.getByTestId("thread-background-popover").innerText(), /dev-service/);
  await page.getByTestId("thread-background-popover").getByRole("button", { name: "查看日志" }).click();
  await page.getByTestId("thread-background-popover").getByText("service-started", { exact: true }).waitFor();
  await page.keyboard.press("Escape");
  await page.screenshot({ path: `${identity.root}/desktop-waiting.png`, fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("button", { name: "后台 1", exact: true }).click();
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
  assert.equal(overflow, false, "phone must not overflow horizontally");
  await page.screenshot({ path: `${identity.root}/phone-background.png`, fullPage: true });
  await page.keyboard.press("Escape");
  const running = page.getByTestId("job-work-status").getByTestId("thread-job-row").filter({ hasText: "running-check" });
  await running.getByRole("button", { name: "停止任务", exact: true }).click();
  await page.getByRole("button", { name: "取消", exact: true }).click();
  let report = await h.rpc("project_jobs", { projectId: identity.project.id }, ["jobs"]);
  assert.equal(report.jobs.find(job => job.name === "running-check").status, "running");
  await running.getByRole("button", { name: "停止任务", exact: true }).click();
  await page.getByRole("button", { name: "确认停止", exact: true }).click();
  await page.getByTestId("job-work-status").getByText("工作未完成", { exact: true }).first().waitFor();
  await page.reload();
  await page.getByTestId("job-work-status").getByText("工作未完成", { exact: true }).first().waitFor();
  await page.getByRole("button", { name: "查看任务", exact: true }).click();
  const stopped = page.getByTestId("job-work-status").getByTestId("thread-job-row").filter({ hasText: "running-check" });
  await stopped.getByRole("button", { name: "任务用途 running-check", exact: true }).click();
  await page.getByRole("button", { name: "确认更改", exact: true }).click();
  // The UI read did not acknowledge ready-result; only the model's explicit review does.
  report = await h.rpc("project_jobs", { projectId: identity.project.id }, ["jobs"]);
  assert.equal(report.jobs.find(job => job.name === "ready-result").review, null);
  // The stopped job's callback has its own turn. Wait for that real turn to
  // finish before starting the explicit review turn.
  await page.waitForFunction(async ({ id }) => {
    const response = await fetch("/gql", {
      method: "POST",
      headers: { "content-type": "application/json", "x-csrf-token": document.querySelector('meta[name="csrf-token"]').content },
      body: JSON.stringify({ query: "query($id: ID!){getThread(id:$id){status}}", variables: { id } }),
    });
    const result = await response.json();
    return result.data?.getThread?.status === "idle";
  }, identity.thread, { timeout: 30000 });
  await page.getByTestId("job-work-status").getByRole("button", { name: "继续检查结果", exact: true }).click();
  await page.getByText("JOB_WORKFLOW_CONFIRMED: the result has been checked.", { exact: true }).waitFor({ timeout: 15000 });
  await page.getByTestId("job-work-status").waitFor({ state: "detached", timeout: 15000 });
  await page.getByRole("button", { name: "后台 1", exact: true }).waitFor();
  await page.screenshot({ path: `${identity.root}/phone-completed-service-running.png`, fullPage: true });
  report = await h.rpc("project_jobs", { projectId: identity.project.id }, ["jobs"]);
  assert.equal(report.jobs.find(job => job.name === "ready-result").review, "complete");
  assert.equal(report.jobs.find(job => job.name === "dev-service").status, "running");
  if (h.problems.length) throw new Error(h.problems.join("\n"));
  console.log("live job workflow: desktop/390px, multiple jobs, non-observing logs, cancel/stop, incomplete after reload, purpose correction, actual model review, background remaining — passed");
} finally {
  await h.stop();
}
