// Isolated real HTTP/SSE -> kernel -> UI errors, never a real provider.
import fs from "node:fs";
import assert from "node:assert/strict";
const identity = JSON.parse(fs.readFileSync(process.env.LONGX_JOB_E2E_IDENTITY, "utf8"));
assert.equal(identity.test_only, true);
assert.equal(identity.kind, "job-workflow");
assert.match(identity.url, /^http:\/\/127\.0\.0\.1:\d+$/);
process.env.LONGX_E2E_URL = identity.url;
const { Harness } = await import("./e2e/lib.mjs");
const h = new Harness("request-errors-live");
await h.start();
try {
  const { page } = h;
  await page.context().grantPermissions(["clipboard-read", "clipboard-write"], { origin: identity.url });
  await page.evaluate(() => localStorage.setItem("longx:language", "zh-CN"));
  await page.goto(`${identity.url}/p/${identity.project.slug}/t/${identity.thread.id}`);
  await page.getByRole("textbox", { name: "随心输入" }).waitFor();
  await h.idle(identity.thread.id, 30_000, 0);
  for (const scenario of [
    { text: "FORCE_HTTP_503_E2E", status: 503, source: "HTTP 请求失败", id: "http-error-e2e-503", viewport: { width: 1280, height: 900 } },
    { text: "FORCE_STREAM_ERROR_E2E", status: 200, source: "响应流内错误", id: "stream-error-e2e-200", viewport: { width: 390, height: 844 } },
  ]) {
    await page.setViewportSize(scenario.viewport);
    await h.rpc("send_message", { threadId: identity.thread.id, text: scenario.text }, ["id"]);
    const rail = page.getByTestId("turn-bar");
    const status = page.getByTestId("status-strip");
    await status.getByRole("button", { name: "查看错误", exact: true }).waitFor();
    assert.equal((await rail.innerText()).includes(scenario.id), false, "rail must not show the raw error");
    assert.equal(await rail.getByRole("button", { name: "查看错误", exact: true }).count(), 0);
    await status.getByRole("button", { name: "查看错误", exact: true }).click();
    const details = page.getByTestId("request-error-details");
    await details.getByText(scenario.source, { exact: true }).waitFor();
    assert.match(await details.innerText(), new RegExp(`HTTP ${scenario.status}`));
    assert.match(await details.innerText(), new RegExp(scenario.id));
    await details.getByRole("button", { name: "复制错误信息", exact: true }).click();
    const copied = await page.evaluate(() => navigator.clipboard.readText());
    assert.match(copied, new RegExp(`HTTP ${scenario.status}`));
    assert.match(copied, new RegExp(scenario.id));
    await page.waitForFunction(() => {
      const detail = document.querySelector('[data-testid="request-error-details"]');
      if (!detail) return false;
      const box = detail.getBoundingClientRect();
      return box.left >= 0 && box.right <= innerWidth && box.top >= 0 && box.bottom <= innerHeight;
    });
    await page.screenshot({ path: `${identity.root}/error-${scenario.status}-${scenario.viewport.width}.png`, fullPage: true });
    // The fixture creates a thread row directly; its status can remain idle
    // during a turn. Check the turn rows too before starting another request.
    await h.idle(identity.thread.id, 30_000);
    await page.reload();
    await page.getByTestId("status-strip").getByRole("button", { name: "查看错误", exact: true }).click();
    assert.match(await page.getByTestId("request-error-details").innerText(), new RegExp(`HTTP ${scenario.status}`));
    await page.keyboard.press("Escape");
  }
  if (h.problems.length) throw new Error(h.problems.join("\n"));
  console.log("request errors: actual HTTP 503 and HTTP 200 SSE failure, compact rail, full details/copy, desktop/390px bounds, persisted after reload — passed");
} finally {
  await h.stop();
}
