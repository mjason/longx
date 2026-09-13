import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, test, vi } from "vitest";
import { renderAt } from "@/ui/test-utils";
import { failed, ok, project, rpcMock, socketMock } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { createDirectory, createProject } from "@/ash_rpc";

describe("ProjectWizard", () => {
  test("browse to a directory, name defaults to its basename, git is offered, project created", async () => {
    vi.mocked(createProject).mockResolvedValue(ok(project(1)) as never);
    const user = userEvent.setup();
    const { router } = renderAt("/new");

    const entries = await screen.findByTestId("directory-entries");
    await user.click(await within(entries).findByText("code"));
    await user.click(await within(entries).findByText("my-app"));
    expect(screen.getByTestId("chosen-directory")).toHaveTextContent("/home/me/code/my-app");

    await user.click(screen.getByRole("button", { name: "就用这个目录" }));
    expect(screen.getByLabelText("名称")).toHaveValue("my-app");
    const gitOption = screen.getByRole("checkbox", { name: /初始化 git/ });
    expect(gitOption).toBeChecked();

    await user.click(screen.getByRole("button", { name: "创建" }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/p/app-1"));
    expect(createProject).toHaveBeenCalledWith(
      expect.objectContaining({ input: expect.objectContaining({ name: "my-app", rootPath: "/home/me/code/my-app", initGit: true }) }),
    );
  });

  test("a directory that is already a repository is an open: no git checkbox", async () => {
    const user = userEvent.setup();
    renderAt("/new");
    const entries = await screen.findByTestId("directory-entries");
    expect(await within(entries).findByText("git 仓库")).toBeInTheDocument();
    await user.click(within(entries).getByText("repo"));
    await user.click(screen.getByRole("button", { name: "就用这个目录" }));
    expect(screen.getByText("这个目录已经是 git 仓库")).toBeInTheDocument();
    expect(screen.queryByRole("checkbox", { name: /初始化 git/ })).not.toBeInTheDocument();
  });

  test("hidden directories and a typed path", async () => {
    const user = userEvent.setup();
    renderAt("/new");
    const entries = await screen.findByTestId("directory-entries");
    expect(within(entries).queryByText(".dotfiles")).not.toBeInTheDocument();
    await user.click(screen.getByRole("checkbox", { name: "显示隐藏目录" }));
    expect(await within(entries).findByText(".dotfiles")).toBeInTheDocument();

    await user.type(screen.getByPlaceholderText("或直接输入路径"), "/home/me/code");
    await user.click(screen.getByRole("button", { name: "前往" }));
    expect(screen.getByTestId("chosen-directory")).toHaveTextContent("/home/me/code");
  });

  test("a new directory is made under the one being looked at and becomes the choice", async () => {
    const user = userEvent.setup();
    renderAt("/new");
    await screen.findByTestId("directory-entries");
    await user.click(screen.getByRole("button", { name: "新建目录" }));
    await user.type(screen.getByRole("textbox", { name: "目录名" }), "fresh-app{Enter}");
    await waitFor(() => expect(createDirectory).toHaveBeenCalledWith(expect.objectContaining({ input: { parent: "/home/me", name: "fresh-app" } })));
    await waitFor(() => expect(screen.getByTestId("chosen-directory")).toHaveTextContent("/home/me/fresh-app"));
  });

  test("server-side errors land on the form", async () => {
    vi.mocked(createProject).mockResolvedValue(failed("has already been taken", ["rootPath"]) as never);
    const user = userEvent.setup();
    renderAt("/new");
    const entries = await screen.findByTestId("directory-entries");
    await user.click(await within(entries).findByText("code"));
    await user.click(screen.getByRole("button", { name: "就用这个目录" }));
    await user.click(screen.getByRole("button", { name: "创建" }));
    await waitFor(() => expect(screen.getByText("has already been taken")).toBeInTheDocument());
  });
});
