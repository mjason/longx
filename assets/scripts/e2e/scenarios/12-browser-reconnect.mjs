// No model call: real extension pairing, reconnect, same-name device identity,
// alias editing, and the mobile settings layout on an isolated dev server.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { BASE, expect } from "../lib.mjs";

const UNPACKED = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../../../priv/static/extension/unpacked");

export async function run(h) {
  const profiles = [];
  const contexts = [];
  const ids = [];
  const alias = `e2e-reconnect-${Date.now()}`;
  try {
    for (let index = 0; index < 2; index++) {
      const profile = fs.mkdtempSync(path.join(os.tmpdir(), "longx-reconnect-"));
      profiles.push(profile);
      const context = await chromium.launchPersistentContext(profile, {
        channel: "chromium",
        args: [`--disable-extensions-except=${UNPACKED}`, `--load-extension=${UNPACKED}`],
      });
      contexts.push(context);
      let [worker] = context.serviceWorkers();
      if (!worker) worker = await context.waitForEvent("serviceworker", { timeout: 15_000 });
      const popup = await context.newPage();
      await popup.goto(`chrome-extension://${new URL(worker.url()).host}/popup.html`);
      await popup.waitForFunction(() => document.querySelector("#device-name")?.value.length > 0);
      const generated = await popup.getByLabel("设备名称").inputValue();
      expect(generated.includes("Chrome") && generated.includes("Linux"), `generated name: ${generated}`);
      await popup.getByLabel("设备名称").fill("E2E 同名 Chrome");
      await popup.getByLabel("Longx 地址").fill(BASE);
      await popup.getByRole("button", { name: "连接", exact: true }).click();
      await popup.locator('#status[data-status="pending"]').waitFor({ timeout: 15_000 });
      const before = await h.rpc("list_chrome_browsers", {}, ["browsers"]);
      const pending = before.browsers.find((b) => b.status === "pending" && b.connected && !ids.includes(b.id));
      expect(pending, "this test extension has a pending connected row");
      expect(pending.name === "E2E 同名 Chrome", "registration uses the extension's chosen name");
      ids.push(pending.id);
      expect(pending.device.peerIp === "127.0.0.1", `transport IP: ${JSON.stringify(pending.device)}`);
      await h.rpc("approve_chrome_browser", { id: pending.id });
      await popup.locator('#status[data-status="approved"]').waitFor({ timeout: 15_000 });
      expect((await popup.locator("#identity").textContent()).includes(pending.id), "popup shows its complete device ID");
      await popup.getByLabel("设备名称").fill("E2E 重命名 Chrome");
      await popup.getByRole("button", { name: "保存名称", exact: true }).click();
      await popup.getByText("已连接：E2E 重命名 Chrome", { exact: true }).waitFor({ timeout: 15_000 });
      const renamed = await h.rpc("list_chrome_browsers", {}, ["browsers"]);
      expect(renamed.browsers.find((b) => b.id === pending.id)?.name === "E2E 重命名 Chrome", "popup rename updates the same server device");
      await popup.getByLabel("设备名称").fill("E2E 同名 Chrome");
      await popup.getByRole("button", { name: "保存名称", exact: true }).click();
      await popup.getByText("已连接：E2E 同名 Chrome", { exact: true }).waitFor({ timeout: 15_000 });

      await popup.getByRole("button", { name: "重新连接", exact: true }).click();
      await popup.locator('#status[data-status="approved"]').waitFor({ timeout: 15_000 });
      await popup.getByRole("button", { name: "断开", exact: true }).click();
      await popup.locator('#status[data-status="disconnected"]').waitFor();
      await popup.getByRole("button", { name: "连接", exact: true }).click();
      await popup.locator('#status[data-status="approved"]').waitFor({ timeout: 15_000 });
      expect((await popup.locator("#identity").textContent()).includes(pending.id), "reconnect keeps the same paired device");
    }
    await h.rpc("set_chrome_alias", { name: alias, browsers: [ids[0]] }, ["aliases"]);
    await h.open(h.page, "/settings/browsers");
    const aliases = h.page.getByTestId("chrome-aliases");
    const row = aliases.getByTestId("alias-row").filter({ hasText: alias });
    await row.getByRole("button", { name: /^(编辑|Edit)$/ }).click();
    await aliases.getByRole("checkbox", { name: new RegExp(ids[0].slice(-8)) }).uncheck();
    await aliases.getByRole("checkbox", { name: new RegExp(ids[1].slice(-8)) }).check();
    await aliases.getByRole("button", { name: /^(保存别名|Save alias)$/ }).click();
    await h.page.waitForTimeout(500);
    const mapping = await h.rpc("chrome_aliases", {}, ["aliases", "default"]);
    expect(mapping.aliases.find((a) => a.name === alias)?.browsers[0] === ids[1], "alias edits select the exact second device");
    await h.noOverflow(h.page, "desktop browser settings");
    await h.shot(h.page, "desktop");
    const phone = await h.phone();
    await h.open(phone, "/settings/browsers");
    await phone.getByTestId("browser-row").first().waitFor();
    await h.noOverflow(phone, "phone browser settings");
    await h.shot(phone, "phone");
  } finally {
    await h.rpc("delete_chrome_alias", { name: alias }, ["aliases"]).catch(() => {});
    for (const id of ids) await h.rpc("reject_chrome_browser", { id }).catch(() => {});
    for (const context of contexts) await context.close().catch(() => {});
    for (const profile of profiles) fs.rmSync(profile, { recursive: true, force: true });
  }
}
