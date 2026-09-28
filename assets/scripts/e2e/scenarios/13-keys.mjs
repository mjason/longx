// The keys: the space menu (Spacemacs' leader, no modes) — Esc leaves the
// composer, the strip says what Space does, Space shows the which-key panel;
// SPC f f finds a file and opens it, SPC b d closes its tab, SPC ? lists
// every key, SPC : is the palette, SPC w 4 the files window, SPC SPC back to
// the composer — then the chords: ⌥↓ / ⌥↑ between conversations from the
// composer, ⌘K listing this project's conversations, Esc Esc stopping a real
// running turn, and in the installed app's window (display-mode standalone,
// stood in for) ⌘W closing a tab, ⌘⇧T reopening it, Ctrl+Tab by last use.
// On a phone Space is only a space.
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

  // ⌥↓ / ⌥↑ from the composer: the conversation below or above in the list
  const first = await h.thread();
  const second = await h.thread();
  await h.open(page, `/p/${h.slug}/t/${second.id}`);
  await page.locator(".aui-composer-input").click();
  await page.keyboard.press("Alt+ArrowDown");
  await until("⌥↓ opens the conversation below", async () => page.url().endsWith(`/t/${first.id}`));
  await page.keyboard.press("Alt+ArrowUp");
  await until("⌥↑ goes back up", async () => page.url().endsWith(`/t/${second.id}`));

  // ⌘K: this project's conversations first; one picked opens
  await page.keyboard.press("ControlOrMeta+k");
  const here = page.getByRole("group", { name: "这个项目的会话" });
  await here.waitFor({ timeout: 10_000 });
  expect((await here.getByRole("option").count()) >= 2, "⌘K lists the project's conversations");
  await h.shot(page, "palette-threads");
  await page.keyboard.press("ControlOrMeta+k");
  await until("⌘K again closes the palette", async () => (await page.getByRole("dialog").count()) === 0);

  // Esc Esc stops a turn that runs: the first leaves the composer and says so, the second stops
  await h.send(first.id, "用 exec_command 在前台直接运行 `sleep 120`（不要用 start_job，不要改成别的命令），等它结束后说“done”。");
  await h.open(page, `/p/${h.slug}/t/${first.id}`);
  await page.getByTestId("tool-command").first().waitFor({ timeout: 90_000 });
  await page.locator(".aui-composer-input").click();
  await page.keyboard.press("Escape");
  await until("the strip says a second Esc stops", async () => (await hint.innerText()).includes("再按 Esc"));
  await h.shot(page, "esc-armed");
  await page.keyboard.press("Escape");
  const turns = await h.idle(first.id, 60_000);
  expect(turns[0].status === "interrupted", `Esc Esc stopped the turn: ${JSON.stringify(turns)}`);

  // the installed app's window: the browser keeps no key, ⌘W and Ctrl+Tab are the page's
  const appContext = await h.browser.newContext({ viewport: { width: 1280, height: 900 } });
  await appContext.addInitScript(() => {
    const real = window.matchMedia.bind(window);
    window.matchMedia = (q) =>
      q.includes("display-mode: standalone")
        ? { matches: true, media: q, onchange: null, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {}, dispatchEvent: () => false }
        : real(q);
  });
  const appPage = await h.watch(await appContext.newPage());
  await h.open(appPage, `/p/${h.slug}/t/${second.id}`);
  const appTabs = appPage.getByTestId("workbench-tabs");
  const openFile = async (name) => {
    await appPage.keyboard.press("Escape");
    await appPage.keyboard.press("Space");
    await appPage.keyboard.press("f");
    await appPage.keyboard.press("f");
    const finder = appPage.getByRole("dialog", { name: "找文件" });
    await finder.waitFor({ timeout: 5_000 });
    await appPage.keyboard.type(name);
    await finder.getByRole("option", { name: new RegExp(name) }).first().waitFor({ timeout: 10_000 });
    await appPage.keyboard.press("Enter");
    await until(`${name} opens`, async () => (await appTabs.getByRole("tab", { name: new RegExp(name) }).count()) === 1);
  };
  await openFile("keyboard_app");
  await openFile("README");
  // Ctrl+Tab: the tab used before (keyboard_app), Ctrl let go settles there
  await appPage.keyboard.press("Escape");
  await appPage.keyboard.press("Control+Tab");
  await until("Ctrl+Tab goes to the tab used before", async () => (await appTabs.getByRole("tab", { selected: true }).innerText()).includes("keyboard_app"));
  await appPage.keyboard.press("ControlOrMeta+w");
  await until("⌘W closes the tab in the app", async () => (await appTabs.getByRole("tab", { name: /keyboard_app/ }).count()) === 0);
  await appPage.keyboard.press("ControlOrMeta+Shift+t");
  await until("⌘⇧T reopens it", async () => (await appTabs.getByRole("tab", { name: /keyboard_app/ }).count()) === 1);
  await h.shot(appPage, "app-window");
  await appContext.close();

  // a phone: no hint, Space opens nothing
  const phone = await h.phone();
  await h.open(phone, `/p/${h.slug}`);
  expect((await phone.getByTestId("keys-hint").count()) === 0, "a phone has no space-menu hint");
  await phone.keyboard.press("Space");
  expect((await phone.getByTestId("which-key").count()) === 0, "Space on a phone opens no menu");
  await phone.context().close();
}
