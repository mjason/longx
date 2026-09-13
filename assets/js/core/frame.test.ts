import { describe, expect, test } from "vitest";
import { createFrameStore, DEFAULT_FRAME, resizePanel, toggleTool, toolForShortcut } from "./frame";

describe("frame transitions", () => {
  test("toggle opens, toggling the same tool closes, another switches", () => {
    let s = DEFAULT_FRAME;
    s = toggleTool(s, "git");
    expect(s.tool).toBe("git");
    s = toggleTool(s, "git");
    expect(s.tool).toBeNull();
    s = toggleTool(s, "process");
    expect(s.tool).toBe("process");
  });

  test("panel width is clamped", () => {
    expect(resizePanel(DEFAULT_FRAME, 10).panelWidth).toBe(240);
    expect(resizePanel(DEFAULT_FRAME, 9999).panelWidth).toBe(560);
    expect(resizePanel(DEFAULT_FRAME, 400.4).panelWidth).toBe(400);
  });

  test("⌘1..4 map to the tools in rail order", () => {
    expect(toolForShortcut("1")).toBe("threads");
    expect(toolForShortcut("2")).toBe("git");
    expect(toolForShortcut("4")).toBe("files");
    expect(toolForShortcut("5")).toBeNull();
    expect(toolForShortcut("k")).toBeNull();
  });
});

describe("frame store", () => {
  test("remembers per device and survives garbage", () => {
    const mem = new Map<string, string>();
    const storage = { getItem: (k: string) => mem.get(k) ?? null, setItem: (k: string, v: string) => mem.set(k, v) };
    const a = createFrameStore(storage);
    a.open("files");
    a.resize(500);
    const b = createFrameStore(storage);
    expect(b.get()).toEqual({ tool: "files", panelWidth: 500 });

    mem.set("longx:frame", "{not json");
    expect(createFrameStore(storage).get()).toEqual(DEFAULT_FRAME);
    mem.set("longx:frame", JSON.stringify({ tool: "nope", panelWidth: "x" }));
    expect(createFrameStore(storage).get()).toEqual(DEFAULT_FRAME);
  });
});
