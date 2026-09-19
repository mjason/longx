import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { ok, project, rpcMock, socketMock } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { listProjects, listRunningThreads } from "@/ash_rpc";

describe("WelcomePage", () => {
  beforeEach(() => setViewport(390));

  test("recent projects with search, one door to open/create", async () => {
    const user = userEvent.setup();
    renderAt("/");
    await waitFor(() => expect(screen.getByTestId("project-list")).toBeInTheDocument());
    expect(screen.getByText("App 1").closest("a")).toHaveAttribute("href", "/p/app-1");
    expect(screen.getByRole("link", { name: /新建 \/ 打开项目/ })).toHaveAttribute("href", "/new");

    await user.type(screen.getByLabelText("搜索项目…"), "app-2");
    expect(screen.queryByText("App 1")).not.toBeInTheDocument();
    expect(screen.getByText("App 2")).toBeInTheDocument();
  });

  test("what is running now sits on top, each a link into its thread, the ones waiting on the person marked", async () => {
    vi.mocked(listRunningThreads).mockResolvedValue(
      ok({
        threads: [
          { id: "t-1", kernelThreadId: "thr_1", title: null, preview: "跑一下测试", lastActivityAt: new Date().toISOString(), projectId: "id-1", projectSlug: "app-1", projectName: "App 1", waiting: true },
          { id: "t-2", kernelThreadId: "thr_2", title: "重构登录", preview: "…", lastActivityAt: new Date().toISOString(), projectId: "id-2", projectSlug: "app-2", projectName: "App 2", waiting: false },
          // the parent is idle, its researcher at work: the session is busy all the same
          { id: "t-3", kernelThreadId: "thr_3", title: "找研报", preview: "…", lastActivityAt: new Date().toISOString(), projectId: "id-2", projectSlug: "app-2", projectName: "App 2", waiting: false, working: ["researcher"] },
        ],
      }) as never,
    );
    renderAt("/");
    const list = await screen.findByTestId("running-threads");
    const links = within(list).getAllByRole("link");
    expect(links.map((l) => l.getAttribute("href"))).toEqual(["/p/app-1/t/t-1", "/p/app-2/t/t-2", "/p/app-2/t/t-3"]);
    expect(links[2]).toHaveTextContent("researcher 工作中");
    expect(links[0]).toHaveTextContent("App 1");
    expect(links[0]).toHaveTextContent("跑一下测试");
    expect(links[0]).toHaveTextContent("等待你");
    expect(links[1]).toHaveTextContent("重构登录");
    expect(links[1]).toHaveTextContent("进行中");
    vi.mocked(listRunningThreads).mockResolvedValue(ok({ threads: [] }) as never);
  });

  test("nothing running: no section at all", async () => {
    renderAt("/");
    await waitFor(() => expect(screen.getByTestId("project-list")).toBeInTheDocument());
    expect(screen.queryByTestId("running-threads")).not.toBeInTheDocument();
  });

  test("empty state hides the search box", async () => {
    vi.mocked(listProjects).mockResolvedValueOnce(ok([]) as never);
    renderAt("/");
    await waitFor(() => expect(screen.getByText("还没有项目")).toBeInTheDocument());
    expect(screen.queryByLabelText("搜索项目…")).not.toBeInTheDocument();
    expect(project(1).slug).toBe("app-1");
  });
});
