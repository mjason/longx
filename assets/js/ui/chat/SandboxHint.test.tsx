import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, test, vi } from "vitest";
import { ok, project } from "@/ui/test-mocks";
import { SandboxHint } from "./SandboxHint";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
import { listProjects, sandboxStatus, updateProject } from "@/ash_rpc";

const chat = (over: Partial<{ networkAccess: boolean; sandbox: string }> = {}) =>
  ({ projectId: "id-1", mode: { sandbox: "workspace_write", approvalPolicy: "on_request", networkAccess: false, ...over }, setMode: vi.fn() }) as any;

function show(output: string, c = chat()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(<QueryClientProvider client={client}><SandboxHint output={output} chat={c} /></QueryClientProvider>);
}

describe("SandboxHint", () => {
  test("a read-only cache: one click adds the directory to the project's writable roots", async () => {
    vi.mocked(listProjects).mockResolvedValue(ok([{ ...project(1), writableRoots: ["/data"] }]) as never);
    const user = userEvent.setup();
    show('Caused by: Read-only file system (os error 30) at path "/home/mj/.cache/uv/.tmpX"');
    const hint = await screen.findByTestId("sandbox-hint");
    expect(hint).toHaveTextContent("沙箱不让写 ~/.cache/uv");
    await user.click(screen.getByRole("button", { name: "允许" }));
    await waitFor(() => expect(updateProject).toHaveBeenCalledWith(expect.objectContaining({ identity: "id-1", input: { writableRoots: ["/data", "~/.cache/uv"] } })));
    await screen.findByText("已允许，下一轮起生效");
  });

  test("the driver's socket: the network switch, on the project and on this thread's next turn", async () => {
    vi.mocked(listProjects).mockResolvedValue(ok([project(1)]) as never);
    const user = userEvent.setup();
    const c = chat();
    show("cuInit(0) failed: CUDA_ERROR_OPERATING_SYSTEM", c);
    await screen.findByText(/连本机 socket/);
    await user.click(screen.getByRole("button", { name: "允许" }));
    await waitFor(() => expect(updateProject).toHaveBeenCalledWith(expect.objectContaining({ input: { networkAccess: true } })));
    expect(c.setMode).toHaveBeenCalledWith(expect.objectContaining({ networkAccess: true }));
  });

  test("no GPU in the sandbox: the machine's GPU preset goes into the passthrough; a restart is what makes it real", async () => {
    vi.mocked(listProjects).mockResolvedValue(ok([project(1)]) as never);
    vi.mocked(sandboxStatus).mockResolvedValue(ok({ status: "ok", reason: null, bwrap: "/usr/bin/bwrap", gpu: true, presets: [{ id: "gpu", label: "GPU", paths: ["/dev/dxg"], danger: false }], cachePresets: [], platform: "linux", home: "/home/mj", checkedAt: "" }) as never);
    const user = userEvent.setup();
    show("NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.");
    await screen.findByText(/看不到这台机器的 GPU/);
    await user.click(screen.getByRole("button", { name: "允许" }));
    await waitFor(() => expect(updateProject).toHaveBeenCalledWith(expect.objectContaining({ input: { passthroughPaths: ["/dev/dxg"] } })));
    await screen.findByText(/重启这个项目的 codex/);
  });

  test("an ordinary failure shows nothing", async () => {
    vi.mocked(listProjects).mockResolvedValue(ok([project(1)]) as never);
    show("KeyError: 'x'");
    await waitFor(() => expect(listProjects).toHaveBeenCalled());
    expect(screen.queryByTestId("sandbox-hint")).not.toBeInTheDocument();
  });
});
