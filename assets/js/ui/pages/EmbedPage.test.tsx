import { screen, waitFor } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { renderAt } from "@/ui/test-utils";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());
import { readFile } from "@/ash_rpc";

// the pieces a phone borrows from the web client through a WebView: the
// editor and the diff, alone on a page with no frame around them
describe("EmbedPage", () => {
  test("/embed/editor/:projectId?path= is the file editor and nothing else", async () => {
    vi.mocked(readFile).mockResolvedValue({ success: true, data: { path: "src/a.ex", content: "defmodule A do\nend\n", size: 20, binary: false, truncated: false } } as never);
    renderAt("/embed/editor/p-1?path=src%2Fa.ex");
    await waitFor(() => expect(readFile).toHaveBeenCalledWith(expect.objectContaining({ input: expect.objectContaining({ projectId: "p-1", path: "src/a.ex" }) })));
    expect(await screen.findByTestId("editor-tab")).toBeInTheDocument();
    expect(document.documentElement.getAttribute("data-embed")).toBe("editor");
    // no frame: no top bar, no rail
    expect(screen.queryByRole("banner")).not.toBeInTheDocument();
    expect(screen.queryByTestId("tool-rail")).not.toBeInTheDocument();
  });

  test("/embed/diff/:projectId?path=&sha= is the diff view", async () => {
    renderAt("/embed/diff/p-1?path=src%2Fa.ex&sha=abc");
    expect(await screen.findByTestId("diff-tab")).toBeInTheDocument();
  });
});
