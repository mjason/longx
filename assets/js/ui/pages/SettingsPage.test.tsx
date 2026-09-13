import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, test, vi } from "vitest";
import { renderAt, setViewport } from "@/ui/test-utils";
import { rpcMock, socketMock } from "@/ui/test-mocks";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

describe("SettingsPage", () => {
  test("phone: a list of sections, then the section", async () => {
    setViewport(390);
    const user = userEvent.setup();
    const { router } = renderAt("/settings");
    await user.click(screen.getByRole("link", { name: /外观/ }));
    await waitFor(() => expect(router.state.location.pathname).toBe("/settings/appearance"));
    expect(screen.getByTestId("section-appearance")).toBeInTheDocument();
  });

  test("desktop: categories beside the content, models first", async () => {
    setViewport(1280);
    const { router } = renderAt("/settings");
    await waitFor(() => expect(router.state.location.pathname).toBe("/settings/models"));
    expect(screen.getByRole("link", { name: "模型与 Provider" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByTestId("section-models")).toBeInTheDocument();
  });
});
