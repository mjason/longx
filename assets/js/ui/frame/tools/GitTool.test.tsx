import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { _resetFrameStoreForTests } from "@/core/frame";
import { _resetWorkbenchForTests } from "@/core/workbench";
import { channel, ok } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { gitBranches, gitChanges, gitCommit, gitCreateBranch, gitDeleteBranch, gitDiscard, gitFetch, gitLog, gitPull, gitPush, gitSetRemote, gitShow, gitSwitch, gitUndoCommit } from "@/ash_rpc";

const repo = { repository: true, branch: "main", head: "abc123def", changes: [{ path: "lib/a.ex", status: "modified" }, { path: "new.txt", status: "untracked" }], ahead: 1, behind: 2, remotes: [{ name: "origin", url: "git@example.com:x/y.git" }], lfs: false, ignored: [], merging: false };
const log = [
  { sha: "c1c1c1c1", subject: "second", author: "MJ", email: "mj@x", at: "2026-09-13T10:00:00Z" },
  { sha: "b0b0b0b0", subject: "first", author: "MJ", email: "mj@x", at: "2026-09-12T10:00:00Z" },
];

async function openGit(width = 1280) {
  setViewport(width);
  const user = userEvent.setup();
  const r = renderAt("/p/app-1/t/t1");
  await waitFor(() => expect(channel.topics).toContain("thread:thr_1"));
  await user.keyboard("{Meta>}2{/Meta}");
  const panel = await screen.findByTestId(width < 1024 ? "tool-sheet" : "tool-panel");
  await within(panel).findByTestId("git-tool");
  return { user, panel, ...r };
}

describe("GitTool", () => {
  beforeEach(() => {
    localStorage.clear();
    _resetFrameStoreForTests();
    _resetWorkbenchForTests();
    channel.reset();
    vi.mocked(gitChanges).mockResolvedValue(ok(repo) as never);
    vi.mocked(gitLog).mockResolvedValue(ok(log) as never);
    vi.mocked(gitShow).mockResolvedValue(ok({ ...log[0]!, body: "the body", parents: ["b0b0b0b0"], files: [{ path: "lib/a.ex", status: "modified" }] }) as never);
    vi.mocked(gitBranches).mockResolvedValue(ok({ current: "main", branches: [{ name: "main", sha: "abc", current: true, upstream: "origin/main" }, { name: "feature", sha: "def", current: false, upstream: null }], stashes: [] }) as never);
    for (const m of [gitCommit, gitDiscard, gitSwitch, gitCreateBranch, gitDeleteBranch, gitFetch, gitPull, gitPush, gitSetRemote, gitUndoCommit]) vi.mocked(m).mockClear();
  });

  test("changes: the files with their status, a file opens its diff, the checked ones are committed with summary + description", async () => {
    const { user, panel } = await openGit();
    expect(within(panel).getByTestId("git-tool")).toHaveTextContent("main");
    const rows = within(panel).getAllByRole("checkbox", { name: /lib\/a\.ex|new\.txt/ });
    expect(rows).toHaveLength(2);
    expect(rows.every((r) => (r as HTMLInputElement).getAttribute("aria-checked") === "true" || (r as HTMLInputElement).checked)).toBe(true);

    await user.click(within(panel).getByRole("button", { name: /lib\/a\.ex/ }));
    const tabs = await screen.findByTestId("workbench-tabs");
    expect(within(tabs).getByRole("tab", { name: /a\.ex ±/ })).toHaveAttribute("aria-selected", "true");
    await screen.findByTestId("diff-tab");

    await user.click(within(panel).getByRole("checkbox", { name: /new\.txt/ }));
    await user.type(within(panel).getByRole("textbox", { name: "摘要" }), "fix a");
    await user.type(within(panel).getByRole("textbox", { name: "描述（可选）" }), "why");
    await user.click(within(panel).getByRole("button", { name: /提交到 main/ }));
    await waitFor(() => expect(gitCommit).toHaveBeenCalledWith(expect.objectContaining({ input: { projectId: "id-1", paths: ["lib/a.ex"], message: "fix a\n\nwhy" } })));
  });

  test("discarding the checked files asks first", async () => {
    const { user, panel } = await openGit();
    await user.click(within(panel).getByRole("button", { name: "丢弃所选改动" }));
    const dialog = await screen.findByRole("alertdialog");
    expect(dialog).toHaveTextContent("lib/a.ex");
    await user.click(within(dialog).getByRole("button", { name: "丢弃" }));
    await waitFor(() => expect(gitDiscard).toHaveBeenCalledWith(expect.objectContaining({ input: { projectId: "id-1", paths: ["lib/a.ex", "new.txt"] } })));
  });

  test("history: commits, one commit's message and files, a file's diff at that commit, undo of the last commit", async () => {
    const { user, panel } = await openGit();
    await user.click(within(panel).getByRole("tab", { name: "历史" }));
    await within(panel).findByText("second");
    await user.click(within(panel).getByRole("button", { name: /second/ }));
    await within(panel).findByText("the body");
    await user.click(within(panel).getByRole("button", { name: /lib\/a\.ex/ }));
    const tabs = await screen.findByTestId("workbench-tabs");
    expect(within(tabs).getByRole("tab", { name: /a\.ex ±/ })).toBeInTheDocument();

    await user.click(within(panel).getByRole("button", { name: "撤销上一次提交" }));
    await user.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "撤销提交" }));
    await waitFor(() => expect(gitUndoCommit).toHaveBeenCalled());
  });

  test("branches: switch (with a stash when the tree is dirty), create, delete", async () => {
    const { user, panel } = await openGit();
    await user.click(within(panel).getByRole("button", { name: /当前分支 main/ }));
    const menu = await screen.findByRole("dialog", { name: "分支" });
    await user.click(within(menu).getByRole("button", { name: /^feature$/ }));
    // the working tree has changes: offered a stash
    const ask = await screen.findByRole("alertdialog");
    await user.click(within(ask).getByRole("button", { name: "暂存并切换" }));
    await waitFor(() => expect(gitSwitch).toHaveBeenCalledWith(expect.objectContaining({ input: { projectId: "id-1", name: "feature", stash: true } })));

    await user.click(within(panel).getByRole("button", { name: /当前分支 main/ }));
    const menu2 = await screen.findByRole("dialog", { name: "分支" });
    await user.type(within(menu2).getByRole("textbox", { name: "新分支名" }), "topic{Enter}");
    await waitFor(() => expect(gitCreateBranch).toHaveBeenCalledWith(expect.objectContaining({ input: { projectId: "id-1", name: "topic" } })));

    await user.click(within(panel).getByRole("button", { name: /当前分支 main/ }));
    const menu3 = await screen.findByRole("dialog", { name: "分支" });
    await user.click(within(menu3).getByRole("button", { name: "删除分支 feature" }));
    await user.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "删除" }));
    await waitFor(() => expect(gitDeleteBranch).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ name: "feature" }) })));
  });

  test("sync: ahead/behind on the button; pull, push and fetch", async () => {
    const { user, panel } = await openGit();
    const sync = within(panel).getByRole("button", { name: /同步/ });
    expect(sync).toHaveTextContent("↓2");
    expect(sync).toHaveTextContent("↑1");
    await user.click(sync);
    await user.click(await screen.findByRole("menuitem", { name: /拉取/ }));
    await waitFor(() => expect(gitPull).toHaveBeenCalled());
    await user.click(within(panel).getByRole("button", { name: /同步/ }));
    await user.click(await screen.findByRole("menuitem", { name: /推送/ }));
    await waitFor(() => expect(gitPush).toHaveBeenCalled());
    await user.click(within(panel).getByRole("button", { name: /同步/ }));
    await user.click(await screen.findByRole("menuitem", { name: /获取/ }));
    await waitFor(() => expect(gitFetch).toHaveBeenCalled());
  });

  test("without a remote the sync menu asks for one; without git the tool offers to init", async () => {
    vi.mocked(gitChanges).mockResolvedValue(ok({ ...repo, ahead: null, behind: null, remotes: [] }) as never);
    const { user, panel } = await openGit();
    await user.click(within(panel).getByRole("button", { name: /同步/ }));
    await user.click(await screen.findByRole("menuitem", { name: /添加远程仓库/ }));
    const dialog = await screen.findByRole("dialog", { name: "远程仓库" });
    await user.type(within(dialog).getByRole("textbox", { name: "地址" }), "git@example.com:x/y.git");
    await user.click(within(dialog).getByRole("button", { name: "保存" }));
    await waitFor(() => expect(gitSetRemote).toHaveBeenCalledWith(expect.objectContaining({ input: { projectId: "id-1", name: "origin", url: "git@example.com:x/y.git" } })));

  });

  test("a merge stopped on conflicts is said so, with a way out", async () => {
    const { gitAbortMerge } = await import("@/ash_rpc");
    vi.mocked(gitChanges).mockResolvedValue(ok({ ...repo, merging: true, changes: [{ path: "lib/a.ex", status: "unmerged" }] }) as never);
    const { user, panel } = await openGit();
    expect(within(panel).getByRole("alert")).toHaveTextContent("正在合并");
    await user.click(within(panel).getByRole("button", { name: "放弃合并" }));
    await user.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: "放弃合并" }));
    await waitFor(() => expect(gitAbortMerge).toHaveBeenCalled());
  });

  test("without git the tool offers to init", async () => {
    vi.mocked(gitChanges).mockResolvedValue(ok({ repository: false, branch: null, head: null, changes: [], ahead: null, behind: null, remotes: [], lfs: false }) as never);
    const { panel } = await openGit();
    expect(within(panel).getByRole("button", { name: "初始化 git" })).toBeInTheDocument();
  });
});
