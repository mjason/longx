// Real file versions and the real workbench: useful context, full-file
// expansion, and wrapped long prompt lines in both modes and viewports.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { expect } from "../lib.mjs";

async function readable(h, page, label) {
  await page.locator('[data-testid="diff-view"] .cm-content').first().waitFor();
  const measurements = await page.getByTestId("diff-view").evaluate((host) => ({
    wrapped: [...host.querySelectorAll(".cm-content")].every((el) => el.classList.contains("cm-lineWrapping")),
    horizontal: [...host.querySelectorAll(".cm-scroller")].map((el) => ({
      scroll: el.scrollWidth, width: el.clientWidth,
    })),
  }));
  expect(measurements.wrapped, `${label}: all versions wrap`);
  expect(measurements.horizontal.every((m) => m.scroll <= m.width + 1), `${label}: no horizontal scrolling ${JSON.stringify(measurements.horizontal)}`);
  await h.noOverflow(page, label);
}

export async function run(h) {
  await h.context.addInitScript(() => localStorage.setItem("longx:language", "zh-CN"));
  await h.project();
  const thread = await h.thread();
  const lines = Array.from({ length: 81 }, (_, i) => `context ${i}`);
  lines[40] = "Original prompt: " + "A long instruction should remain readable without horizontal scrolling. ".repeat(18) + "token_" + "x".repeat(240);
  const file = path.join(h.root, "prompt.md");
  fs.writeFileSync(file, lines.join("\n") + "\n");
  const git = (...args) => execFileSync("git", args, { cwd: h.root });
  git("init", "-q");
  git("add", "prompt.md");
  git("-c", "user.name=e2e", "-c", "user.email=e2e@example.com", "commit", "-qm", "before");
  lines[40] = lines[40].replace("Original prompt:", "Updated prompt:");
  fs.writeFileSync(file, lines.join("\n") + "\n");

  for (const mode of ["desktop", "phone"]) {
    const page = mode === "phone" ? await h.phone() : h.page;
    if (mode === "phone") {
      await page.context().addInitScript(() => localStorage.setItem("longx:language", "zh-CN"));
    }
    await h.open(page, `/p/${h.slug}/t/${thread.id}`);
    if (mode === "desktop") await page.keyboard.press("ControlOrMeta+2");
    else await page.getByTestId("bottom-toolbar").getByRole("button", { name: "Git", exact: true }).click();
    const panel = page.getByTestId(mode === "desktop" ? "tool-panel" : "tool-sheet");
    await panel.getByRole("button", { name: /prompt\.md/ }).click();
    const tab = page.getByTestId("diff-tab");
    const diff = tab.getByTestId("diff-view");
    await diff.waitFor();
    const expected = mode === "desktop" ? "split" : "unified";
    expect(await diff.getAttribute("data-mode") === expected, `${mode}: default mode ${expected}`);
    expect((await diff.innerText()).includes("context 28"), `${mode}: twelve preceding lines are readable`);
    await readable(h, page, `${mode} default`);
    await h.shot(page, `${mode}-context`);

    const full = tab.getByRole("button", { name: "全文上下文", exact: true });
    await full.click();
    expect(await full.getAttribute("aria-pressed") === "true", `${mode}: full context enabled`);
    expect(await diff.locator(".cm-collapsedLines").count() === 0, `${mode}: no unchanged lines folded`);
    expect((await diff.innerText()).includes("context 0"), `${mode}: the full file is available`);
    await readable(h, page, `${mode} full context`);
    await h.shot(page, `${mode}-full-context`);
    await full.click();
    expect(await diff.locator(".cm-collapsedLines").count() > 0, `${mode}: nearby context restored`);

    await tab.getByRole("tab", { name: mode === "desktop" ? "单栏" : "并排", exact: true }).click();
    await readable(h, page, `${mode} alternate mode`);
    await h.shot(page, `${mode}-alternate`);
  }
}
