// @vitest-environment jsdom
import { afterEach, describe, expect, test, vi } from "vitest";
import { copyText, installClipboardFallback } from "./clipboard";

const nav = navigator as unknown as { clipboard?: unknown };

describe("clipboard on a plain-http LAN address", () => {
  afterEach(() => {
    delete nav.clipboard;
    vi.restoreAllMocks();
  });

  test("copyText falls back to a selection + execCommand('copy') when the Clipboard API is absent (an insecure context)", async () => {
    delete nav.clipboard;
    const exec = vi.fn(() => true);
    (document as unknown as { execCommand: unknown }).execCommand = exec;
    await copyText("sudo systemctl daemon-reload");
    expect(exec).toHaveBeenCalledWith("copy");
    // the scratch element is gone again
    expect(document.querySelector("textarea")).toBeNull();
  });

  test("copyText rejects when neither way works", async () => {
    delete nav.clipboard;
    (document as unknown as { execCommand: unknown }).execCommand = () => false;
    await expect(copyText("x")).rejects.toThrow();
  });

  test("selection copying stays inside a modal menu's focus trap", async () => {
    delete nav.clipboard;
    const menu = document.createElement("div");
    const item = document.createElement("button");
    menu.appendChild(item);
    document.body.appendChild(menu);
    item.focus();
    const trap = (event: FocusEvent) => {
      if (!menu.contains(event.target as Node)) item.focus();
    };
    document.addEventListener("focusin", trap);
    (document as unknown as { execCommand: unknown }).execCommand = vi.fn(() => {
      const active = document.activeElement as HTMLTextAreaElement;
      return active.tagName === "TEXTAREA" && active.value === "/srv/app/lib";
    });
    try {
      await expect(copyText("/srv/app/lib")).resolves.toBeUndefined();
      expect(document.activeElement).toBe(item);
      expect(menu.querySelector("textarea")).toBeNull();
    } finally {
      document.removeEventListener("focusin", trap);
      menu.remove();
    }
  });

  test("a Clipboard API rejection also uses the HTTP-compatible selection fallback", async () => {
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: vi.fn().mockRejectedValue(new Error("denied")) },
      configurable: true,
    });
    const exec = vi.fn(() => true);
    (document as unknown as { execCommand: unknown }).execCommand = exec;
    await copyText("lib");
    expect(exec).toHaveBeenCalledWith("copy");
  });

  test("installClipboardFallback gives the page a navigator.clipboard.writeText so every copy button works, and leaves a real one alone", async () => {
    delete nav.clipboard;
    const exec = vi.fn(() => true);
    (document as unknown as { execCommand: unknown }).execCommand = exec;
    installClipboardFallback();
    await (navigator.clipboard as { writeText: (t: string) => Promise<void> }).writeText("hello");
    expect(exec).toHaveBeenCalledWith("copy");

    const real = { writeText: vi.fn(async () => {}) };
    Object.defineProperty(navigator, "clipboard", { value: real, configurable: true });
    installClipboardFallback();
    expect(nav.clipboard).toBe(real);
    await copyText("via the api");
    expect(real.writeText).toHaveBeenCalledWith("via the api");
  });
});
