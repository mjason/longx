import { screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, test, vi } from "vitest";
import { ok, renderAt, setViewport } from "@/ui/test-utils";

vi.mock("@/ash_rpc", () => ({
  listProjects: vi.fn(),
  sandboxStatus: vi.fn(async () => ({ success: true, data: { status: "ok", reason: null, checkedAt: "2026-09-12T00:00:00Z" } })),
}));
vi.mock("@/core/socket", () => ({ socketStatus: () => "open", onSocketStatus: () => () => {}, getSocket: () => ({ channel: () => ({ on() {}, join() {}, leave() {} }) }) }));

import { listProjects } from "@/ash_rpc";

const project = (n: number) => ({
  id: `id-${n}`, slug: `app-${n}`, name: `App ${n}`, description: null, rootPath: `/srv/app-${n}`,
  sandbox: "workspace_write", approvalPolicy: "on_request", networkAccess: false, dirtyStart: "commit",
  tools: [], memoryLimitMb: null, archivedAt: null, updatedAt: "2026-09-12T00:00:00Z",
});

describe("ProjectsPage", () => {
  beforeEach(() => setViewport(390));

  test("lists projects with their paths and links to them", async () => {
    vi.mocked(listProjects).mockResolvedValue(ok([project(1), project(2)]) as never);
    renderAt("/");
    await waitFor(() => expect(screen.getByTestId("project-list")).toBeInTheDocument());
    expect(screen.getByText("App 1")).toBeInTheDocument();
    expect(screen.getByText("/srv/app-2")).toBeInTheDocument();
    expect(screen.getByText("App 1").closest("a")).toHaveAttribute("href", "/p/app-1");
  });

  test("empty state and the always-reachable new-project action", async () => {
    vi.mocked(listProjects).mockResolvedValue(ok([]) as never);
    renderAt("/");
    await waitFor(() => expect(screen.getByText("还没有项目")).toBeInTheDocument());
    expect(screen.getByRole("link", { name: /新建项目/ })).toHaveAttribute("href", "/new");
  });

  test("an RPC failure is shown, not swallowed", async () => {
    vi.mocked(listProjects).mockResolvedValue({ success: false, errors: [{ type: "x", message: "boom", shortMessage: "boom", vars: {}, fields: [], path: [], details: {} }] } as never);
    renderAt("/");
    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("boom"));
  });
});
