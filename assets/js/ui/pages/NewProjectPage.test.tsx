import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, test, vi } from "vitest";
import { failed, ok, renderAt } from "@/ui/test-utils";

vi.mock("@/ash_rpc", () => ({
  createProject: vi.fn(),
  getProject: vi.fn(async () => ({ success: true, data: { id: "p1", slug: "my-app", name: "My App", rootPath: "/srv/my-app" } })),
  gitInfo: vi.fn(async () => ({ success: true, data: { repository: true, head: "abc", clean: true, changes: 0, lfs: false } })),
  codexInfo: vi.fn(async () => ({ success: true, data: { home: "/x", exists: false, bytes: 0, files: {}, worker: null } })),
  listThreads: vi.fn(async () => ({ success: true, data: [] })),
  sandboxStatus: vi.fn(async () => ({ success: true, data: { status: "ok", reason: null, checkedAt: "" } })),
}));
vi.mock("@/core/socket", () => ({ socketStatus: () => "open", onSocketStatus: () => () => {}, getSocket: () => ({ channel: () => ({ on() {}, join() {}, leave() {} }) }) }));

import { createProject } from "@/ash_rpc";

describe("NewProjectPage", () => {
  test("submits name + path and navigates to the new project", async () => {
    vi.mocked(createProject).mockResolvedValue(ok({ id: "p1", slug: "my-app", name: "My App", rootPath: "/srv/my-app" }) as never);
    const user = userEvent.setup();
    const { router } = renderAt("/new");

    await user.type(screen.getByLabelText("名称"), "My App");
    await user.type(screen.getByLabelText(/目录/), "/srv/my-app");
    await user.click(screen.getByRole("button", { name: "创建" }));

    await waitFor(() => expect(router.state.location.pathname).toBe("/p/my-app"));
    expect(createProject).toHaveBeenCalledWith(expect.objectContaining({ input: { name: "My App", rootPath: "/srv/my-app", description: undefined } }));
  });

  test("a field error lands under its field", async () => {
    vi.mocked(createProject).mockResolvedValue(failed("must be an existing directory", ["rootPath"]) as never);
    const user = userEvent.setup();
    renderAt("/new");

    await user.type(screen.getByLabelText("名称"), "X");
    await user.type(screen.getByLabelText(/目录/), "/nope");
    await user.click(screen.getByRole("button", { name: "创建" }));

    await waitFor(() => expect(screen.getByText("must be an existing directory")).toBeInTheDocument());
    expect(screen.getByLabelText(/目录/)).toHaveAttribute("aria-invalid", "true");
  });

  test("the button stays disabled until both required fields are filled", async () => {
    renderAt("/new");
    expect(screen.getByRole("button", { name: "创建" })).toBeDisabled();
  });
});
