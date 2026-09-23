// The file watcher, while the project's page is open: a file written on disk
// appears in the tree with no refresh; a built-in ignore dims its directory;
// a .longxignore `!` line brings part of it back — the directory stays dim,
// what came back does not; git init and a commit reach the git window and
// the status strip.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { expect, sleep } from "../lib.mjs";

async function until(what, fn, ms = 10_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await fn()) return;
    await sleep(200);
  }
  expect(false, what);
}

export async function run(h) {
  await h.project();
  const page = h.page;
  await h.open(page, `/p/${h.slug}`);
  await page.keyboard.press("Meta+4");
  const panel = page.getByTestId("tool-panel");
  const tree = panel.getByRole("tree");
  await tree.waitFor({ timeout: 10_000 });
  const row = (name) => tree.getByRole("treeitem", { name, exact: true });

  // written by someone else — an editor, a script — and shown without 刷新
  fs.writeFileSync(path.join(h.root, "hello.txt"), "hi\n");
  await until("a file written on disk appears in the tree", async () => (await row("hello.txt").count()) === 1);

  fs.mkdirSync(path.join(h.root, "target/reports"), { recursive: true });
  fs.writeFileSync(path.join(h.root, "target/reports/r.txt"), "r\n");
  fs.writeFileSync(path.join(h.root, "target/x.bin"), "x\n");
  await until("the new directory appears", async () => (await row("target").count()) === 1);
  await until("target/ (a built-in ignore) is dimmed", async () => (await row("target").getAttribute("data-ignored")) === "true");
  const found = await h.rpc("search_files", { id: h.projectId, query: "r.txt" }, ["path"]).catch(() => null);
  if (found) expect(!found.some((f) => f.path === "target/reports/r.txt"), "the @ search leaves an ignored file out");

  fs.writeFileSync(path.join(h.root, ".longxignore"), "!target/reports/\n");
  await row("target").click();
  await until("reports/ shows under target", async () => (await row("reports").count()) === 1);
  await until("what .longxignore brings back is not dimmed", async () => (await row("reports").getAttribute("data-ignored")) === null);
  expect((await row("x.bin").getAttribute("data-ignored")) === "true", "the rest of target/ stays dimmed");
  expect((await row("target").getAttribute("data-ignored")) === "true", "target itself stays dimmed");
  await h.shot(page, "tree");

  // git: init and a commit — the git window follows (HEAD, the index)
  execFileSync("git", ["init", "-q"], { cwd: h.root });
  await page.keyboard.press("Meta+2");
  const git = page.getByTestId("tool-panel");
  await until("the git window sees the repository and the untracked file", async () => (await git.getByText("hello.txt").count()) > 0, 15_000);
  execFileSync("git", ["add", "-A"], { cwd: h.root });
  execFileSync("git", ["-c", "user.name=e2e", "-c", "user.email=e2e@example.com", "commit", "-qm", "first"], { cwd: h.root });
  await until("the commit clears the changes list", async () => (await git.getByText("hello.txt").count()) === 0, 15_000);
  const head = execFileSync("git", ["rev-parse", "--short=8", "HEAD"], { cwd: h.root }).toString().trim();
  await until("the status strip shows the new HEAD", async () => (await page.getByTestId("status-strip").innerText()).includes(head));
  await h.shot(page, "git");
}
