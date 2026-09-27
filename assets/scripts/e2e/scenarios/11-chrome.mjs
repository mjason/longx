// The person's browser: a second Chromium with the built extension loaded
// pairs with this Longx (the popup takes the address; the settings page
// allows it), the project's description names it, and the agent opens a
// page of the project in it and reads the title back — nobody is asked.
// Needs `priv/static/extension/unpacked` (mix
// assets.build) and a Chromium that runs extensions (playwright's
// `channel: "chromium"`, the new headless).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { BASE, expect, sleep } from "../lib.mjs";

const UNPACKED = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../../../priv/static/extension/unpacked");

export async function run(h) {
  expect(fs.existsSync(path.join(UNPACKED, "manifest.json")), `the extension is built at ${UNPACKED}`);
  await h.project();
  // a page of the project, served by Longx itself (/files/<project>/…)
  fs.writeFileSync(path.join(h.root, "hello.html"), "<!doctype html><title>Longx e2e 页面 4711</title><h1>hello from the project</h1>");
  fs.mkdirSync(path.join(h.root, ".longx/local"), { recursive: true });
  fs.writeFileSync(path.join(h.root, ".longx/local/agent.exs"), 'import Longx.Agent.Config\n\nagent do\n  version 1\n  extends :default\n  plug Browser, browser: "e2e-chrome", max_tabs: 2\nend\n');

  // the person's Chrome: a persistent context with the extension
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "longx-e2e-chrome-"));
  const chrome = await chromium.launchPersistentContext(profile, {
    channel: "chromium",
    args: [`--disable-extensions-except=${UNPACKED}`, `--load-extension=${UNPACKED}`],
  });
  try {
    let [worker] = chrome.serviceWorkers();
    if (!worker) worker = await chrome.waitForEvent("serviceworker", { timeout: 15_000 });
    const extensionId = new URL(worker.url()).host;

    // the popup: the address of this Longx, 连接
    const popup = await chrome.newPage();
    await popup.goto(`chrome-extension://${extensionId}/popup.html`);
    await popup.getByLabel(/Longx 地址/).fill(BASE);
    await popup.getByRole("button", { name: "连接" }).click();
    await popup.getByText(/等待|允许/).first().waitFor({ timeout: 15_000 });

    // Longx: the request appears in the settings page and is allowed there
    const page = h.page;
    await h.open(page, "/settings/browsers");
    const pending = page.getByTestId("pending-row").first();
    await pending.waitFor({ timeout: 15_000 });
    await pending.getByRole("button", { name: "允许" }).click();
    await page.getByTestId("browser-row").first().waitFor({ timeout: 15_000 });
    await popup.getByText(/已连接/).waitFor({ timeout: 15_000 });
    await h.shot(popup, "popup");

    // its id, the alias the description names
    const { browsers } = await h.rpc("list_chrome_browsers", {}, ["browsers"]);
    const browser = browsers.find((b) => b.status === "approved" && b.connected);
    expect(browser, `an approved, connected browser: ${JSON.stringify(browsers)}`);
    await h.rpc("set_chrome_alias", { name: "e2e-chrome", browsers: [browser.id] }, ["aliases"]);

    // the agent opens the page in it, without an ask
    const t = await h.thread();
    await h.open(page, `/p/${h.slug}/t/${t.id}`);
    const url = `${BASE}/files/${h.projectId}/hello.html?inline=1`;
    await h.send(t.id, `用 javascript 工具在我的浏览器里打开 ${url}，用 page.info() 读出页面标题，然后只回复标题原文。`);

    const turns = await h.idle(t.id, 180_000);
    expect(turns[0].status === "completed", `the turn: ${JSON.stringify(turns)}`);
    await page.getByTestId("tool-javascript").first().waitFor({ timeout: 30_000 });
    await page.getByText(/Longx e2e 页面 4711/).first().waitFor({ timeout: 30_000 });
    await h.shot(page, "chat");

    // the session's tab sits in a group named after it, in the person's Chrome
    await sleep(500);
    const titles = await Promise.all(chrome.pages().map((p) => p.title().catch(() => "")));
    expect(titles.some((x) => /Longx e2e 页面 4711/.test(x)), `the tab is open in the person's Chrome: ${titles}`);
  } finally {
    await chrome.close().catch(() => {});
    fs.rmSync(profile, { recursive: true, force: true });
  }
}
