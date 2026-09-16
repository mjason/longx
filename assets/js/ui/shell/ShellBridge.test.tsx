import { screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt } from "@/ui/test-utils";

vi.mock("@/ash_rpc", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

// the app's half of the bridge lives in the router: a deep link from a
// notification is an in-app navigation, a theme change reaches the shell
describe("ShellBridge", () => {
  const post = vi.fn();
  beforeEach(() => {
    window.LongxAndroid = { post };
    post.mockClear();
  });
  afterEach(() => {
    delete window.LongxAndroid;
    delete window.LongxShell;
  });

  test("navigate() from the shell moves the router; the theme is posted on change", async () => {
    const { router } = renderAt("/");
    await waitFor(() => expect(window.LongxShell).toBeDefined());
    expect(JSON.parse(post.mock.calls[0]![0] as string).type).toBe("ready");

    window.LongxShell!.navigate("/settings");
    await screen.findByText("设置");
    expect(router.state.location.pathname).toMatch(/^\/settings/);
  });
});
