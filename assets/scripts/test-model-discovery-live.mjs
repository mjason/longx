// Run only against the disposable instance started by ModelDiscoveryBrowserTest.
// Real built UI, GraphQL, model actions and SQLite; only the vendor is a fixture.
import assert from "node:assert/strict";
import { chromium } from "playwright";

const [base, lsId, providerId] = process.argv.slice(2);
assert.match(base ?? "", /^http:\/\/localhost:\d+$/);
assert.ok(lsId && providerId);
const browser = await chromium.launch();
try {
  for (const width of [1280, 390]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, locale: "zh-CN" });
    const page = await context.newPage();
    page.setDefaultTimeout(15000);
    const errors = [];
    page.on("pageerror", e => { errors.push(e.message); console.error(`fixture pageerror: ${e.message}`); });
    page.on("console", message => { if (message.type() === "error") console.error(`fixture console: ${message.text()}`); });
    page.on("requestfailed", request => console.error(`fixture request failed: ${new URL(request.url()).pathname} ${request.failure()?.errorText}`));
    page.on("response", async response => {
      if (response.url().endsWith("/gql") && response.status() >= 400)
        console.error(`fixture GraphQL HTTP ${response.status()}`);
    });
    await page.goto(`${base}/settings/providers`);
    const card = page.getByTestId(`provider-${providerId}`);
    await card.waitFor().catch(async error => {
      console.error((await page.locator("body").innerText()).slice(0, 2500));
      throw error;
    });
    const heading = card.getByRole("button", { name: "ChatGPT fixture", exact: true });
    if (await heading.getAttribute("aria-expanded") === "false") await heading.click();
    await card.getByRole("button", { name: "ChatGPT fixture 的操作" }).click();
    await page.getByRole("menuitem", { name: "从接口获取模型" }).click();
    const dialog = page.getByRole("dialog");
    if (width === 1280) {
      for (const id of ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"])
        await dialog.getByRole("checkbox", { name: id, exact: true }).click();
      await dialog.getByRole("button", { name: "添加 3 个" }).click();
      await dialog.waitFor({ state: "hidden" });
      for (const id of ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"])
        await card.getByText(`chatgpt-${id}`, { exact: true }).waitFor();
      const ls = page.getByTestId(`provider-${lsId}`);
      if (await ls.getByRole("button", { name: "LS fixture", exact: true }).getAttribute("aria-expanded") === "false")
        await ls.getByRole("button", { name: "LS fixture", exact: true }).click();
      for (const id of ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra"])
        await ls.getByText(id, { exact: true }).waitFor();
    } else {
      // Reopening discovery after import excludes the installed upstream ids,
      // despite their different local slugs.
      await dialog.getByText("接口没有列出未添加的模型").waitFor();
      await dialog.getByRole("button", { name: "取消" }).click();
    }

    const row = card.locator("li").filter({ has: page.getByText("chatgpt-gpt-6-astra", { exact: true }) });
    await row.getByRole("button", { name: /的操作/ }).click();
    await page.getByRole("menuitem", { name: "检测", exact: true }).click();
    await row.getByText(/模型可用/).waitFor();
    const denied = card.locator("li").filter({ has: page.getByText("chatgpt-gpt-5.6-terra", { exact: true }) });
    await denied.getByRole("button", { name: /的操作/ }).click();
    await page.getByRole("menuitem", { name: "检测", exact: true }).click();
    await denied.getByText(/fixture model not allowed/).waitFor();
    assert.deepEqual(errors, []);
    console.log(`${width}px real model discovery and health checks passed`);
    await context.close();
  }
} finally {
  await browser.close();
}
