import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { ok, project, rpcMock, socketMock } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { listProjects } from "@/ash_rpc";

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

  test("empty state hides the search box", async () => {
    vi.mocked(listProjects).mockResolvedValueOnce(ok([]) as never);
    renderAt("/");
    await waitFor(() => expect(screen.getByText("还没有项目")).toBeInTheDocument());
    expect(screen.queryByLabelText("搜索项目…")).not.toBeInTheDocument();
    expect(project(1).slug).toBe("app-1");
  });
});
