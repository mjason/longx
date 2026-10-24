// Run only with the disposable instance and synthetic shell from
// ShellEnvironmentBrowserTest. No production server or startup file is touched.
import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { chromium } from "playwright";

const [base, shell] = process.argv.slice(2);
assert.match(base ?? "", /^http:\/\/localhost:\d+$/);
assert.match(shell ?? "", /\/longx-shell-refresh-\d+\/shell$/);
const browser = await chromium.launch();
try {
  for (const width of [1280, 390]) {
    const context = await browser.newContext({ viewport: {width, height: 950}, locale: "zh-CN" });
    const page = await context.newPage();
    page.setDefaultTimeout(15000);
    const errors = [];
    const replies = [];
    page.on("pageerror", error => errors.push(error.message));
    page.on("response", response => {
      if (response.url().endsWith("/gql") && response.request().postData()?.includes("refreshShellEnvironment"))
        replies.push(response.json());
    });
    await page.goto(base + "/settings/connections");
    const settings = page.getByTestId("agent-settings");
    const section = settings.getByTestId("shell-environment-refresh");
    const refresh = () => section.getByRole("button", {name:"刷新 shell 环境",exact:true});
    await refresh().waitFor();
    assert.match(await section.textContent(), /不改变已有任务、用户组或权限/);
    if (width === 1280) {
      await settings.getByLabel("额外 PATH 目录").fill("/fixture-extra");
      assert.equal(await refresh().isDisabled(), true);
      let releaseSave;
      let saving;
      const saveGate = new Promise(resolve => { releaseSave = resolve; });
      const saveStarted = new Promise(resolve => { saving = resolve; });
      const holdSave = async route => {
        if (route.request().postData()?.includes("setAgentSettings")) {
          saving();
          await saveGate;
        }
        await route.continue();
      };
      await page.route("**/gql", holdSave);
      await settings.getByRole("button", {name:"保存全局默认",exact:true}).click();
      await saveStarted;
      assert.equal(await settings.getByLabel("额外 PATH 目录").isDisabled(), true);
      assert.equal(await settings.getByLabel("命令使用的 Shell").isDisabled(), true);
      assert.equal(await settings.getByRole("button", {name:"恢复默认",exact:true}).isDisabled(), true);
      assert.equal(await refresh().isDisabled(), true);
      releaseSave();
      await refresh().waitFor();
      await page.waitForFunction(() => [...document.querySelectorAll("button")].some(b => b.textContent === "刷新 shell 环境" && !b.disabled));
      await page.unroute("**/gql", holdSave);
      await writeFile(shell + ".block", "");
    }
    await writeFile(shell + ".state", `ready-${width}`);
    await refresh().click();
    const pending = section.getByRole("button", {name:"正在刷新 shell 环境…",exact:true});
    if (width === 1280) {
      await pending.waitFor();
      assert.equal(await pending.isDisabled(), true);
      assert.equal(await settings.getByRole("button", {name:"保存全局默认",exact:true}).isDisabled(), true);
      await writeFile(shell + ".release", "");
    }
    await section.getByRole("status").filter({hasText:shell}).waitFor();
    await writeFile(shell + ".state", "fail");
    await refresh().click();
    await section.getByRole("alert").filter({hasText:"未更新现有环境快照"}).waitFor();
    await writeFile(shell + ".state", `ready-${width}`);
    await refresh().click();
    await section.getByRole("status").filter({hasText:shell}).waitFor();
    for (const reply of await Promise.all(replies)) {
      const data = reply.data?.refreshShellEnvironment;
      if (data) assert.deepEqual(Object.keys(data).sort(), ["refreshedAt", "shell"]);
      assert.ok(!JSON.stringify(reply).includes("fixture-env-secret"));
      assert.ok(!JSON.stringify(reply).includes("fixture-stderr-secret"));
    }
    assert.equal(replies.length, 3);
    assert.deepEqual(errors, []);
    console.log(`shell environment browser ${width}px passed`);
    await context.close();
  }
} finally {
  await browser.close();
}
