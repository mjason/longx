// The space menu (Spacemacs' leader, no modes): Esc leaves the composer, the
// strip says what Space does, Space shows the which-key panel; SPC f f finds
// a file and opens it, SPC b d closes its tab, SPC ? lists every key, SPC :
// is the command palette, SPC w 4 the files window, SPC SPC back to the
// composer. On a phone Space is only a space.
import fs from "node:fs";
import path from "node:path";
import { expect, sleep } from "../lib.mjs";

async function until(what, fn, ms = 10_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await fn()) return;
    await sleep(150);
  }
  expect(false, what);
}

export async function run(h) {
  await h.project();
  fs.mkdirSync(path.join(h.root, "src"), { recursive: true });
  fs.writeFileSync(path.join(h.root, "src", "keyboard_app.ts"), "export const answer = 42;\n");
  fs.writeFileSync(path.join(h.root, "README.md"), "# keys\n");
  const page = h.page;
  await h.open(page, `/p/${h.slug}`);

  const hint = page.getByTestId("keys-hint");
  const whichKey = page.getByTestId("which-key");
  const activeIsComposer = () => page.evaluate(() => document.activeElement?.classList.contains("aui-composer-input") ?? false);

  // typing: the composer has the focus, Space is a space, Esc leaves it
  await page.locator(".aui-composer-input").click();
  await until("the strip says Esc leaves the text field", async () => (await hint.innerText()).includes("Esc"));
  await page.keyboard.press("Space");
  expect((await whichKey.count()) === 0, "Space in the composer types a space");
  await page.keyboard.press("Escape");
  await until("the strip says Space opens the menu", async () => (await hint.innerText()).includes("空格"));

  // the which-key panel: the groups with their keys
  await page.keyboard.press("Space");
  await whichKey.waitFor({ timeout: 5_000 });
  const top = await whichKey.innerText();
  for (const label of ["和 AI 对话", "+文件", "+Git", "+工具窗口"]) expect(top.includes(label), `the top level lists ${label}: ${top}`);
  await h.shot(page, "which-key");
  await page.keyboard.press("f");
  await until("SPC f lists the file commands", async () => (await whichKey.innerText()).includes("找文件"));
  await h.shot(page, "which-key-f");

  // SPC f f: a file picker over search_files; Enter opens the file in a tab
  await page.keyboard.press("f");
  const picker = page.getByRole("dialog", { name: "找文件" });
  await picker.waitFor({ timeout: 5_000 });
  await page.keyboard.type("keyboard_app");
  await picker.getByRole("option", { name: /keyboard_app\.ts/ }).first().waitFor({ timeout: 10_000 });
  await h.shot(page, "find-file");
  await page.keyboard.press("Enter");
  const tabs = page.getByTestId("workbench-tabs");
  await until("the file opens in a tab", async () => (await tabs.getByRole("tab", { name: /keyboard_app\.ts/ }).count()) === 1);
  await until("the editor shows the file", async () => (await page.locator(".cm-content").first().innerText()).includes("answer = 42"));

  // SPC b d closes the tab (Esc first: the editor may have the focus)
  await page.keyboard.press("Escape");
  await page.keyboard.press("Space");
  await whichKey.waitFor({ timeout: 5_000 });
  await page.keyboard.press("b");
  await until("SPC b lists the tab commands", async () => (await whichKey.innerText()).includes("关闭"));
  await page.keyboard.press("d");
  await until("SPC b d closes the file's tab", async () => (await tabs.getByRole("tab", { name: /keyboard_app\.ts/ }).count()) === 0);

  // SPC ?: every key
  await page.keyboard.press("Space");
  await page.keyboard.press("?");
  const help = page.getByRole("dialog", { name: "全部快捷键" });
  await help.waitFor({ timeout: 5_000 });
  expect((await help.innerText()).includes("SPC f f"), "the key list names SPC f f");
  await h.shot(page, "help");
  await page.keyboard.press("Escape");
  await until("Esc closes the key list", async () => (await help.count()) === 0);

  // SPC :: the command palette, its commands with their keys
  await page.keyboard.press("Space");
  await page.keyboard.press(":");
  const palette = page.getByPlaceholder("输入项目、会话或命令…");
  await palette.first().waitFor({ timeout: 5_000 });
  await h.shot(page, "palette");
  await page.keyboard.press("Escape");

  // SPC w 4: the files window
  await until("the palette is closed", async () => (await page.getByRole("dialog").count()) === 0);
  await page.keyboard.press("Space");
  await page.keyboard.press("w");
  await page.keyboard.press("4");
  await page.getByTestId("tool-panel").getByRole("tree").waitFor({ timeout: 10_000 });

  // SPC SPC: back to the conversation's composer
  await page.keyboard.press("Space");
  await page.keyboard.press("Space");
  await until("SPC SPC focuses the composer", activeIsComposer);
  await h.noOverflow(page, "desktop with the space menu");

  // a phone: no hint, Space opens nothing
  const phone = await h.phone();
  await h.open(phone, `/p/${h.slug}`);
  expect((await phone.getByTestId("keys-hint").count()) === 0, "a phone has no space-menu hint");
  await phone.keyboard.press("Space");
  expect((await phone.getByTestId("which-key").count()) === 0, "Space on a phone opens no menu");
  await phone.context().close();
}
