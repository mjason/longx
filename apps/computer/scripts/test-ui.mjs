import { chromium } from "../../../assets/node_modules/playwright/index.mjs";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import assert from "node:assert/strict";

// Isolated browser and mocked IPC: never start Driver, reset TCC or install.
const config = JSON.parse(await readFile(new URL("../src-tauri/tauri.conf.json", import.meta.url), "utf8"));
assert.equal(typeof config.plugins?.updater?.pubkey, "string", "Updater plugin needs an initial config even when release updates are disabled");
const root = new URL("../ui/", import.meta.url);
const server = createServer(async (req, res) => {
  try {
    const name = new URL(req.url, "http://localhost").pathname.slice(1) || "index.html";
    if (!["index.html", "style.css", "theme.css", "app.js"].includes(name)) {
      res.writeHead(404).end();
      return;
    }
    const data = await readFile(new URL(name, root));
    res.setHeader("Content-Type", name.endsWith(".css") ? "text/css" : name.endsWith(".js") ? "text/javascript" : "text/html");
    res.end(data);
  } catch {
    res.writeHead(500).end();
  }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
let browser;
try {
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage({ viewport: { width: 640, height: 780 } });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.addInitScript(() => {
    window.calls = [];
    window.updateEnabled = false;
    window.failCheck = false;
    window.__TAURI__ = { core: { invoke: async (name, args) => {
      window.calls.push({ name, args });
      if (name === "report") return {
        config: { bind_address: "127.0.0.1", port: 7797, allow_remote: false, allow_foreground: false },
        running: false, busy: false, clients: 0,
        permissions: { accessibility: true, screen_recording: false, note: "授权后重启。" },
      };
      if (name === "update_status") return { current: "0.1.0", enabled: false, available: null, note: "开发版未配置更新源。" };
      if (name === "check_update") {
        if (window.failCheck) throw new Error("mock network failure");
        return { current: "0.1.0", enabled: true, available: "0.2.0", note: "签名更新" };
      }
      if (name === "access_credential") return "mock-ui-key";
    } } };
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  for (const theme of ["dark", "light"]) {
    await page.emulateMedia({ colorScheme: theme });
    await page.goto(url);
    await page.waitForFunction(() => document.querySelector("#service-badge").textContent === "已停止");
    assert.equal(await page.evaluate(() => getComputedStyle(document.body).backgroundColor),
      theme === "dark" ? "rgb(28, 30, 36)" : "rgb(255, 255, 255)");
    assert.equal(await page.locator("#check-update").isDisabled(), true);
    assert.equal(await page.locator("#install-update").isVisible(), false);
  }
  await page.locator("#refresh-permissions").click();
  await page.waitForFunction(() => document.querySelector("#permission-feedback").textContent.includes("重新检测"));
  page.once("dialog", dialog => dialog.dismiss());
  await page.locator('[data-reset="screen_recording"]').click();
  assert.equal(await page.evaluate(() => window.calls.some(call => call.name === "reset_permission")), false);
  page.once("dialog", dialog => dialog.accept());
  await page.locator('[data-reset="screen_recording"]').click();
  await page.waitForFunction(() => document.querySelector("#permission-feedback").textContent.includes("已重置"));
  assert.equal(await page.evaluate(() => window.calls.find(call => call.name === "reset_permission").args.kind), "screen_recording");
  await page.evaluate(() => { document.querySelector("#check-update").disabled = false; });
  await page.locator("#check-update").click();
  await page.locator("#install-update").waitFor({ state: "visible" });
  await page.evaluate(() => { window.failCheck = true; });
  await page.locator("#check-update").click();
  await page.waitForFunction(() => document.querySelector("#update-status").textContent.includes("失败"));
  assert.equal(await page.locator("#install-update").isVisible(), false);
  await page.evaluate(() => { window.failCheck = false; });
  await page.locator("#check-update").click();
  await page.locator("#install-update").waitFor({ state: "visible" });
  page.once("dialog", dialog => dialog.accept());
  await page.locator("#install-update").click();
  await page.waitForFunction(() => document.querySelector("#update-status").textContent.includes("更新已安装"));
  assert.equal(await page.locator("#check-update").isDisabled(), true);
  await page.locator("#reveal").click();
  assert.equal(await page.locator("#key").inputValue(), "mock-ui-key");
  await page.evaluate(() => window.dispatchEvent(new Event("blur")));
  assert.equal(await page.locator("#key").inputValue(), "");
  await page.locator("#stop").click();
  assert(await page.evaluate(() => window.calls.some(call => call.name === "stop_service")));
  await page.setViewportSize({ width: 460, height: 780 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  assert.deepEqual(errors, []);
  console.log("UI passed: themes/layout, explicit permission reset, refresh, disabled updater, offers/check failure/install, key clearing, stop.");
} finally {
  await browser?.close();
  server.close();
}
