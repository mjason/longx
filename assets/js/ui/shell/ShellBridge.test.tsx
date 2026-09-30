import { act, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { renderAt } from "@/ui/test-utils";
import { setTheme } from "@/core/theme";

vi.mock("@/core/api", async () => (await import("@/ui/test-mocks")).rpcMock());
vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

// the app's half of the bridge lives in the router: a deep link from a
// notification is an in-app navigation, a theme change reaches the shell
describe("ShellBridge", () => {
  const post = vi.fn();
  const setChrome = vi.fn();
  beforeEach(() => {
    window.LongxAndroid = { post };
    post.mockClear();
    setChrome.mockClear();
    (window as unknown as { longxNative: { setChrome: typeof setChrome } }).longxNative = { setChrome };
    localStorage.setItem("longx:theme", "dark");
    document.documentElement.style.setProperty("--sidebar", "#15171c");
  });
  afterEach(() => {
    vi.restoreAllMocks();
    delete window.LongxAndroid;
    delete window.LongxShell;
    delete (window as unknown as { longxNative?: unknown }).longxNative;
    document.documentElement.style.removeProperty("--sidebar");
    localStorage.clear();
  });

  test("the page sends the current chrome palette on route and theme changes", async () => {
    const { router } = renderAt("/");
    await waitFor(() => expect(window.LongxShell).toBeDefined());
    expect(JSON.parse(post.mock.calls[0]![0] as string)).toEqual({ type: "ready", version: 1 });
    await waitFor(() => expect(setChrome).toHaveBeenLastCalledWith({ background: "#15171c", theme: "dark" }));

    window.LongxShell!.navigate("/settings");
    await screen.findByText("设置");
    expect(router.state.location.pathname).toMatch(/^\/settings/);
    await waitFor(() => expect(setChrome).toHaveBeenCalledTimes(2));

    setTheme("light");
    document.documentElement.style.setProperty("--sidebar", "#f3f4f7");
    await waitFor(() => expect(setChrome).toHaveBeenLastCalledWith({ background: "#f3f4f7", theme: "light" }));

    setTheme("system");
    document.documentElement.style.setProperty("--sidebar", "#15171c");
    await waitFor(() => expect(setChrome).toHaveBeenLastCalledWith({ background: "#15171c", theme: "system" }));
  });

  test("system appearance changes refresh the page background sent to the native shell", async () => {
    const listeners: (() => void)[] = [];
    let systemDark = false;
    vi.spyOn(window, "matchMedia").mockImplementation(
      () =>
        ({
          matches: systemDark,
          media: "(prefers-color-scheme: dark)",
          onchange: null,
          addEventListener: (_type: string, listener: EventListener) => listeners.push(listener as () => void),
          removeEventListener: vi.fn(),
          addListener: vi.fn(),
          removeListener: vi.fn(),
          dispatchEvent: vi.fn(),
        }) as unknown as MediaQueryList,
    );
    localStorage.setItem("longx:theme", "system");
    document.documentElement.style.setProperty("--sidebar", "#f3f4f7");
    renderAt("/");
    await waitFor(() => expect(setChrome).toHaveBeenLastCalledWith({ background: "#f3f4f7", theme: "system" }));

    systemDark = true;
    document.documentElement.style.setProperty("--sidebar", "#15171c");
    act(() => listeners.forEach((listener) => listener()));
    await waitFor(() => expect(setChrome).toHaveBeenLastCalledWith({ background: "#15171c", theme: "system" }));
  });
});
