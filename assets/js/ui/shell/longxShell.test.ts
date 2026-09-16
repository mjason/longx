import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { closeTopLayer, installShell, shellPost, shellPresent } from "./longxShell";

// the Android shell injects `LongxAndroid.post(json)`; iOS will inject
// `webkit.messageHandlers.longx`; a browser has neither
describe("LongxShell bridge", () => {
  const post = vi.fn();
  beforeEach(() => {
    (window as unknown as { LongxAndroid?: unknown }).LongxAndroid = { post };
    post.mockClear();
    document.documentElement.setAttribute("data-theme", "dark");
  });
  afterEach(() => {
    delete (window as unknown as { LongxAndroid?: unknown }).LongxAndroid;
    delete (window as unknown as { LongxShell?: unknown }).LongxShell;
    document.documentElement.removeAttribute("data-shell");
    document.body.innerHTML = "";
  });

  test("a browser has no shell: nothing is installed, posting is a no-op", () => {
    delete (window as unknown as { LongxAndroid?: unknown }).LongxAndroid;
    expect(shellPresent()).toBe(false);
    shellPost({ type: "openExternal", url: "https://x" });
    const off = installShell({ navigate: vi.fn(), resume: vi.fn() });
    expect(window.LongxShell).toBeUndefined();
    expect(document.documentElement.getAttribute("data-shell")).toBeNull();
    off();
  });

  test("with a shell: LongxShell is installed, the page marked, ready posted with the theme", () => {
    const off = installShell({ navigate: vi.fn(), resume: vi.fn() });
    expect(shellPresent()).toBe(true);
    expect(document.documentElement.getAttribute("data-shell")).toBe("android");
    expect(window.LongxShell?.version).toBe(1);
    const msg = JSON.parse(post.mock.calls[0]![0] as string);
    expect(msg.type).toBe("ready");
    expect(msg.theme.scheme).toBe("dark");
    off();
    expect(window.LongxShell).toBeUndefined();
  });

  test("back() closes the top layer (a dialog, a sheet, a popover) with Escape and says so; nothing open → false", () => {
    installShell({ navigate: vi.fn(), resume: vi.fn() });
    expect(window.LongxShell!.back()).toBe(false);

    document.body.innerHTML = `<div role="dialog" data-state="open"><button id="b">x</button></div>`;
    const escapes: KeyboardEvent[] = [];
    document.addEventListener("keydown", (e) => e.key === "Escape" && escapes.push(e));
    expect(window.LongxShell!.back()).toBe(true);
    expect(escapes).toHaveLength(1);
    expect(closeTopLayer()).toBe(true);
  });

  test("navigate and resume reach the app; a link to another host goes to the shell as openExternal", () => {
    const navigate = vi.fn();
    const resume = vi.fn();
    installShell({ navigate, resume });
    window.LongxShell!.navigate("/p/x/t/1");
    expect(navigate).toHaveBeenCalledWith("/p/x/t/1");
    window.LongxShell!.resume();
    expect(resume).toHaveBeenCalled();

    document.body.innerHTML = `<a id="ext" href="https://example.com/doc">doc</a><a id="int" href="/p/x">in</a>`;
    post.mockClear();
    const ext = document.getElementById("ext")!;
    const prevented = !ext.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    expect(prevented).toBe(true);
    expect(JSON.parse(post.mock.calls[0]![0] as string)).toEqual({ type: "openExternal", url: "https://example.com/doc" });
    post.mockClear();
    document.getElementById("int")!.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    expect(post).not.toHaveBeenCalled();
  });

  test("the keyboard: the visual viewport's height becomes --app-height", () => {
    const listeners: (() => void)[] = [];
    const vv = { height: 600, addEventListener: (_: string, l: () => void) => listeners.push(l), removeEventListener: vi.fn() };
    Object.defineProperty(window, "visualViewport", { value: vv, configurable: true });
    const off = installShell({ navigate: vi.fn(), resume: vi.fn() });
    expect(document.documentElement.style.getPropertyValue("--app-height")).toBe("600px");
    vv.height = 320;
    listeners.forEach((l) => l());
    expect(document.documentElement.style.getPropertyValue("--app-height")).toBe("320px");
    off();
    expect(document.documentElement.style.getPropertyValue("--app-height")).toBe("");
  });
});
