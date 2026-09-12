import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, test, vi } from "vitest";
import { ok, renderAt } from "@/ui/test-utils";

vi.mock("@/ash_rpc", () => ({
  getProject: vi.fn(async () => ok({ id: "p1", slug: "my-app", name: "My App", rootPath: "/srv/my-app" })),
  gitInfo: vi.fn(),
  initGit: vi.fn(),
  codexInfo: vi.fn(async () => ok({ home: "/x", exists: false, bytes: 0, files: {}, worker: null })),
  listThreads: vi.fn(async () => ok([{ id: "t1", codexThreadId: "thr_1", title: null, preview: "fix the tests", status: "idle", modelSlug: "glm-5", lastActivityAt: "2026-09-12T00:00:00Z", insertedAt: "2026-09-12T00:00:00Z" }])),
  startThread: vi.fn(async () => ok({ id: "t2", codexThreadId: "thr_2" })),
  stopCodex: vi.fn(),
  restartCodex: vi.fn(),
  sandboxStatus: vi.fn(async () => ok({ status: "unavailable", reason: "user_namespaces: refused", checkedAt: "" })),
}));
const channel = { on: vi.fn(), join: vi.fn(), leave: vi.fn() };
vi.mock("@/core/socket", () => ({ socketStatus: () => "closed", onSocketStatus: () => () => {}, getSocket: () => ({ channel: () => channel }) }));

import { gitInfo, initGit } from "@/ash_rpc";

describe("ProjectPage", () => {
  test("warns when the directory has no git and initialises it on tap", async () => {
    vi.mocked(gitInfo).mockResolvedValue(ok({ repository: false, head: null, clean: null, changes: 0, lfs: false }) as never);
    vi.mocked(initGit).mockResolvedValue(ok({ repository: true, head: "372bb0366a5ae41b", clean: true, changes: 0, lfs: false }) as never);
    const user = userEvent.setup();
    renderAt("/p/my-app");

    await waitFor(() => expect(screen.getByText("这个目录还不是 git 仓库")).toBeInTheDocument());
    await user.click(screen.getByRole("button", { name: "初始化 git" }));
    await waitFor(() => expect(screen.getByText("372bb036")).toBeInTheDocument());
    expect(initGit).toHaveBeenCalledWith(expect.objectContaining({ input: { id: "p1" } }));
  });

  test("shows threads, joins the project channel, and surfaces the banners", async () => {
    vi.mocked(gitInfo).mockResolvedValue(ok({ repository: true, head: "abc", clean: false, changes: 3, lfs: true }) as never);
    renderAt("/p/my-app");

    await waitFor(() => expect(screen.getByTestId("thread-list")).toBeInTheDocument());
    expect(screen.getByText("fix the tests").closest("a")).toHaveAttribute("href", "/p/my-app/t/t1");
    expect(screen.getByText("3 个文件有改动")).toBeInTheDocument();
    expect(channel.join).toHaveBeenCalled();
    // sandbox unavailable + socket closed are both visible at the top
    expect(screen.getByTestId("sandbox-banner")).toHaveTextContent("user_namespaces");
    expect(screen.getByTestId("connection-banner")).toBeInTheDocument();
  });
});
