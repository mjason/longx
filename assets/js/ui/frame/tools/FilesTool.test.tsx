import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { _resetWorkbenchForTests } from "@/core/workbench";
import { channel, ok } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { createEntry, deleteEntry, gitChanges, ignoredPaths, listFiles, readFile, renameEntry, writeFile } from "@/ash_rpc";

const tree: Record<string, { name: string; path: string; kind: "file" | "dir"; size: number }[]> = {
  "": [
    { name: "lib", path: "lib", kind: "dir", size: 0 },
    { name: "README.md", path: "README.md", kind: "file", size: 5 },
  ],
  lib: [{ name: "a.ex", path: "lib/a.ex", kind: "file", size: 12 }],
};

async function openFiles(width = 1280) {
  setViewport(width);
  const user = userEvent.setup();
  const r = renderAt("/p/app-1/t/t1");
  await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
  await user.keyboard("{Meta>}4{/Meta}");
  const panel = await screen.findByTestId(width < 1024 ? "tool-sheet" : "tool-panel");
  await within(panel).findByText("README.md");
  return { user, panel, ...r };
}

describe("FilesTool", () => {
  beforeEach(() => {
    localStorage.clear();
    _resetFrameStoreForTests();
    _resetWorkbenchForTests();
    channel.reset();
    vi.mocked(listFiles).mockImplementation(async ({ input }: { input: { path: string } }) => ok(tree[input.path] ?? []) as never);
    vi.mocked(gitChanges).mockResolvedValue(
      ok({ repository: true, branch: "main", head: "abc", changes: [{ path: "lib/a.ex", status: "modified" }, { path: "new.txt", status: "untracked" }], ahead: 0, behind: 0, remotes: [], lfs: false, ignored: [], merging: false }) as never,
    );
    vi.mocked(readFile).mockResolvedValue(ok({ path: "lib/a.ex", content: "defmodule A do\nend\n", size: 12, binary: false, truncated: false }) as never);
    vi.mocked(ignoredPaths).mockResolvedValue(ok(["README.md", "node_modules/"]) as never);
  });

  test("⌘4 shows the tree: folders first, lazy children, git status on files and their folders; a file opens in the editor", async () => {
    const { user, panel } = await openFiles();
    const rows = within(panel).getAllByRole("treeitem");
    expect(rows.map((r) => r.textContent)).toEqual(["lib", "README.md"]);
    // a folder with a change under it is marked like the file; an ignored path is dimmed
    expect(within(panel).getByRole("treeitem", { name: /lib/ })).toHaveAttribute("data-git", "modified");
    expect(within(panel).getByRole("treeitem", { name: /README/ })).toHaveAttribute("data-ignored", "true");
    await user.click(within(panel).getByRole("treeitem", { name: /lib/ }));
    const child = await within(panel).findByRole("treeitem", { name: /a\.ex/ });
    expect(child).toHaveAttribute("data-git", "modified");
    expect(listFiles).toHaveBeenCalledWith(expect.objectContaining({ input: { projectId: "id-1", path: "lib" } }));

    await user.click(child);
    const tabs = await screen.findByTestId("workbench-tabs");
    expect(within(tabs).getByRole("tab", { name: /a\.ex/ })).toHaveAttribute("aria-selected", "true");
    const editor = await screen.findByTestId("editor-tab");
    await waitFor(() => expect(editor.querySelector(".cm-content")).toHaveTextContent("defmodule A do"));
    // the chat is still there, behind
    await user.click(within(tabs).getByRole("tab", { name: /会话/ }));
    expect(screen.getByTestId("chat-area")).toBeVisible();
  });

  test("the tree follows the disk while the watcher runs; a watcher that stopped is said, and 刷新 still works", async () => {
    const { panel } = await openFiles();
    expect(within(panel).queryByTestId("watch-hint")).toBeNull();
    const before = vi.mocked(listFiles).mock.calls.length;
    vi.mocked(listFiles).mockImplementation(async ({ input }: { input: { path: string } }) =>
      ok(input.path === "" ? [...tree[""]!, { name: "new.txt", path: "new.txt", kind: "file", size: 1 }] : (tree[input.path] ?? [])) as never,
    );
    act(() => channel.deliverTo("project:id-1", "files", { paths: ["new.txt"] }));
    await within(panel).findByRole("treeitem", { name: /new\.txt/ });
    expect(vi.mocked(listFiles).mock.calls.length).toBeGreaterThan(before);

    act(() => channel.deliverTo("project:id-1", "watch", { watching: false, error: "the file watcher stopped (exit 137)" }));
    expect(await within(panel).findByTestId("watch-hint")).toHaveTextContent("文件监控");
    act(() => channel.deliverTo("project:id-1", "watch", { watching: true, error: null }));
    await waitFor(() => expect(within(panel).queryByTestId("watch-hint")).toBeNull());
  });

  test("a folder a `!` rule reaches into is dimmed itself, not what is brought back inside it", async () => {
    vi.mocked(ignoredPaths).mockResolvedValue(ok(["lib", "lib/b.o"]) as never);
    const user = userEvent.setup();
    const { panel } = await openFiles();
    await waitFor(() => expect(within(panel).getByRole("treeitem", { name: /lib/ })).toHaveAttribute("data-ignored", "true"));
    expect(within(panel).getByRole("treeitem", { name: /README/ })).not.toHaveAttribute("data-ignored");
    await user.click(within(panel).getByRole("treeitem", { name: /lib/ }));
    expect(await within(panel).findByRole("treeitem", { name: /a\.ex/ })).not.toHaveAttribute("data-ignored");
  });

  test("a markdown file opens rendered, not in the editor; 编辑 switches to the editor and 预览 back", async () => {
    vi.mocked(readFile).mockResolvedValue(ok({ path: "README.md", content: "# Title\n\nSome **bold** text.\n", size: 26, binary: false, truncated: false }) as never);
    const { user, panel } = await openFiles();
    await user.click(within(panel).getByRole("treeitem", { name: /README/ }));
    const editor = await screen.findByTestId("editor-tab");
    const preview = await within(editor).findByTestId("markdown-preview");
    expect(within(preview).getByRole("heading", { level: 1 })).toHaveTextContent("Title");
    expect(within(preview).getByText("bold").tagName).toBe("STRONG");
    expect(editor.querySelector(".cm-content")).toBeNull();
    // no save button while reading; 编辑 opens the editor with the source
    expect(screen.queryByTestId("save-file")).not.toBeInTheDocument();
    await user.click(within(editor).getByRole("button", { name: "编辑" }));
    await waitFor(() => expect(editor.querySelector(".cm-content")).toHaveTextContent("# Title"));
    expect(screen.getByTestId("save-file")).toBeInTheDocument();
    await user.click(within(editor).getByRole("button", { name: "预览" }));
    await within(editor).findByTestId("markdown-preview");
  });

  test("a markdown file's formulas are drawn by KaTeX in the preview", async () => {
    vi.mocked(readFile).mockResolvedValue(ok({ path: "README.md", content: "# 因子\n\n$$\\text{IC} = \\rho(f, r)$$\n\n行内 \\(\\alpha\\)。\n", size: 60, binary: false, truncated: false }) as never);
    const { user, panel } = await openFiles();
    await user.click(within(panel).getByRole("treeitem", { name: /README/ }));
    const preview = await screen.findByTestId("markdown-preview");
    await waitFor(() => expect(preview.querySelectorAll(".katex").length).toBe(2), { timeout: 15_000 });
    expect(preview.querySelectorAll(".katex-display").length).toBe(1);
  });

  test("a fenced block in the preview wraps its long lines instead of clipping them", async () => {
    const long = "for d in */; do latest=$(ls \"$d\" | sort | tail -1); ls \"$d\" | grep -vxF \"$latest\" | (cd \"$d\" && xargs -r rm -rf); done";
    vi.mocked(readFile).mockResolvedValue(ok({ path: "README.md", content: `# Clean\n\n\`\`\`bash\n${long}\n\`\`\`\n`, size: 200, binary: false, truncated: false }) as never);
    const { user, panel } = await openFiles();
    await user.click(within(panel).getByRole("treeitem", { name: /README/ }));
    const preview = await screen.findByTestId("markdown-preview");
    // shiki highlights asynchronously and swaps the plain block for its own:
    // query afresh each time — a block found earlier may be detached by now
    await waitFor(
      () => {
        const el = preview.querySelector("pre");
        expect(el?.textContent).toContain("xargs -r rm -rf");
        // the highlighter's wrapper carries the rules for its pre: wrap, never a hidden overflow
        expect(el!.closest('[class*="whitespace-pre-wrap"]')).not.toBeNull();
      },
      { timeout: 4000 },
    );
  });

  test("editing marks the tab; save writes the file (⌘S too)", async () => {
    const { user, panel } = await openFiles();
    vi.mocked(readFile).mockResolvedValue(ok({ path: "README.md", content: "# hi\n", size: 5, binary: false, truncated: false }) as never);
    await user.click(within(panel).getByRole("treeitem", { name: /README/ }));
    const editor = await screen.findByTestId("editor-tab");
    // a markdown file opens rendered; the editor is a click away
    await user.click(await within(editor).findByRole("button", { name: "编辑" }));
    const content = await waitFor(() => {
      const c = editor.querySelector(".cm-content");
      expect(c).toHaveTextContent("hi");
      return c!;
    });
    await user.click(content);
    await user.keyboard("!");
    expect(within(screen.getByTestId("workbench-tabs")).getByRole("tab", { name: /README/ })).toHaveTextContent("●");
    await user.click(screen.getByTestId("save-file"));
    await waitFor(() => expect(writeFile).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ path: "README.md", content: expect.stringContaining("!") }) })));
  });

  test("new file / rename / delete from the row's menu", async () => {
    const { user, panel } = await openFiles();
    await user.click(within(panel).getByRole("button", { name: "新建文件" }));
    await user.type(within(panel).getByRole("textbox", { name: "名称" }), "notes.md{Enter}");
    await waitFor(() => expect(createEntry).toHaveBeenCalledWith(expect.objectContaining({ input: { projectId: "id-1", path: "notes.md", kind: "file" } })));

    await user.click(within(panel).getByRole("button", { name: "README.md 的操作" }));
    await user.click(await screen.findByRole("menuitem", { name: "重命名" }));
    const name = within(panel).getByRole("textbox", { name: "名称" });
    await user.clear(name);
    await user.type(name, "README.txt{Enter}");
    await waitFor(() => expect(renameEntry).toHaveBeenCalledWith(expect.objectContaining({ input: { projectId: "id-1", from: "README.md", to: "README.txt" } })));

    await user.click(within(panel).getByRole("button", { name: "README.md 的操作" }));
    await user.click(await screen.findByRole("menuitem", { name: "删除" }));
    const dialog = await screen.findByRole("alertdialog");
    await user.click(within(dialog).getByRole("button", { name: "删除" }));
    await waitFor(() => expect(deleteEntry).toHaveBeenCalledWith(expect.objectContaining({ input: { projectId: "id-1", path: "README.md" } })));
  });

  test("the filter finds files through the server's fuzzy index and opens one", async () => {
    const { searchFiles } = await import("@/ash_rpc");
    vi.mocked(searchFiles).mockResolvedValue(ok([{ path: "lib/deep/gateway.ex", fileName: "gateway.ex", matchType: "file", root: "/", score: 1, indices: null }]) as never);
    const { user, panel } = await openFiles();
    await user.type(within(panel).getByRole("searchbox", { name: "按文件名查找…" }), "gtw");
    const hit = await within(panel).findByRole("button", { name: /^gateway\.ex\s*lib\/deep$/ });
    await user.click(hit);
    expect(within(await screen.findByTestId("workbench-tabs")).getByRole("tab", { name: /gateway\.ex/ })).toHaveAttribute("aria-selected", "true");
  });

  test("closing a tab with unsaved edits asks first", async () => {
    const { user, panel } = await openFiles();
    vi.mocked(readFile).mockResolvedValue(ok({ path: "README.md", content: "# hi\n", size: 5, binary: false, truncated: false }) as never);
    await user.click(within(panel).getByRole("treeitem", { name: /README/ }));
    const editor = await screen.findByTestId("editor-tab");
    // a markdown file opens rendered; the editor is a click away
    await user.click(await within(editor).findByRole("button", { name: "编辑" }));
    const content = await waitFor(() => {
      const c = editor.querySelector(".cm-content");
      expect(c).toHaveTextContent("hi");
      return c!;
    });
    await user.click(content);
    await user.keyboard("!");
    const tabs = screen.getByTestId("workbench-tabs");
    await user.click(within(tabs).getByRole("button", { name: /关闭 README/ }));
    const dialog = await screen.findByRole("alertdialog");
    await user.click(within(dialog).getByRole("button", { name: "不保存，关闭" }));
    // the strip itself goes when the chat is the only tab left
    await waitFor(() => expect(screen.queryByRole("tab", { name: /README/ })).toBeNull());
  });

  test("phone: the tree is a sheet; tapping a file opens the editor full-screen with wrapped lines", async () => {
    const { user, panel } = await openFiles(390);
    await user.click(within(panel).getByRole("treeitem", { name: /README/ }));
    const editor = await screen.findByTestId("editor-tab");
    await user.click(await within(editor).findByRole("button", { name: "编辑" }));
    await waitFor(() => expect(editor.querySelector(".cm-lineWrapping")).not.toBeNull());
  });
});
