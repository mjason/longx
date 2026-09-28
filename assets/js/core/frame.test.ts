import { describe, expect, test } from "vitest";
import { createFrameStore, DEFAULT_FRAME, resizePanel, toggleTool } from "./frame";

describe("frame transitions", () => {
  test("toggle opens, toggling the same tool closes, another switches", () => {
    let s = DEFAULT_FRAME;
    s = toggleTool(s, "git");
    expect(s.tool).toBe("git");
    s = toggleTool(s, "git");
    expect(s.tool).toBeNull();
    s = toggleTool(s, "agents");
    expect(s.tool).toBe("agents");
  });

  test("panel width is clamped", () => {
    expect(resizePanel(DEFAULT_FRAME, 10).panelWidth).toBe(240);
    expect(resizePanel(DEFAULT_FRAME, 9999).panelWidth).toBe(560);
    expect(resizePanel(DEFAULT_FRAME, 400.4).panelWidth).toBe(400);
  });
});

describe("frame store", () => {
  test("remembers per device and survives garbage", () => {
    const mem = new Map<string, string>();
    const storage = { getItem: (k: string) => mem.get(k) ?? null, setItem: (k: string, v: string) => mem.set(k, v) };
    const a = createFrameStore(storage);
    a.open("agents");
    a.resize(500);
    const b = createFrameStore(storage);
    expect(b.get()).toEqual({ tool: "agents", panelWidth: 500 });

    // a device that remembered the history tool (gone) falls back to the default
    mem.set("longx:frame", JSON.stringify({ tool: "history", panelWidth: 500 }));
    expect(createFrameStore(storage).get()).toEqual({ ...DEFAULT_FRAME, panelWidth: 500 });

    mem.set("longx:frame", "{not json");
    expect(createFrameStore(storage).get()).toEqual(DEFAULT_FRAME);
    mem.set("longx:frame", JSON.stringify({ tool: "nope", panelWidth: "x" }));
    expect(createFrameStore(storage).get()).toEqual(DEFAULT_FRAME);
  });
});
