import { afterEach, describe, expect, test, vi } from "vitest";
import { gitPollInterval, uploadWorkspaceFile } from "./workspace";

describe("gitPollInterval", () => {
  test("the git window polls only while nothing watches the files", () => {
    expect(gitPollInterval(false, null)).toBe(false);
    // not known yet, or the watcher down: poll
    expect(gitPollInterval(true, null)).toBe(10_000);
    expect(gitPollInterval(true, { watching: false, error: "stopped" })).toBe(10_000);
    // a watcher that could not watch everything: poll as well
    expect(gitPollInterval(true, { watching: true, error: "could not watch a: too many" })).toBe(10_000);
    // watching: HEAD, the index and the files arrive as events
    expect(gitPollInterval(true, { watching: true, error: null })).toBe(false);
  });
});

describe("uploadWorkspaceFile", () => {
  afterEach(() => vi.unstubAllGlobals());

  test("sends the selected directory and binary file with the session CSRF token", async () => {
    document.head.innerHTML = '<meta name="csrf-token" content="csrf-test">';
    const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      path: "src/icon.png", name: "icon.png", kind: "file", size: 3,
    }), { status: 201, headers: { "content-type": "application/json" } }));
    vi.stubGlobal("fetch", fetch);
    const file = new File([new Uint8Array([0, 1, 255])], "icon.png", { type: "image/png" });

    await expect(uploadWorkspaceFile("project-1", "src", file)).resolves.toMatchObject({
      path: "src/icon.png", size: 3,
    });

    expect(fetch).toHaveBeenCalledWith("/uploads/project-1", expect.objectContaining({
      method: "POST",
      credentials: "same-origin",
      headers: { "X-CSRF-Token": "csrf-test" },
    }));
    const body = fetch.mock.calls[0]![1]!.body as FormData;
    expect(body.get("path")).toBe("src");
    expect((body.get("file") as File).name).toBe("icon.png");
  });

  test("reports a server conflict without claiming upload succeeded", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response('{"error":"already exists"}', { status: 409 })));
    await expect(uploadWorkspaceFile("project-1", "", new File(["x"], "same.txt"))).rejects.toThrow("already exists");
  });
});
