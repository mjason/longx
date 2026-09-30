import { afterEach, describe, expect, it } from "vitest";
import { emptyView } from "./thread";
import { cacheThreadView, clearThreadViewCache, getCachedThreadView } from "./threadViewCache";

afterEach(clearThreadViewCache);

describe("thread view cache", () => {
  it("keeps views in a bounded LRU and refreshes recency on access", () => {
    for (let i = 0; i < 6; i++) cacheThreadView(emptyView(`t${i}`));
    expect(getCachedThreadView("t0")).toBeDefined();
    cacheThreadView(emptyView("t6"));
    expect(getCachedThreadView("t1")).toBeUndefined();
    expect(getCachedThreadView("t0")).toBeDefined();
  });

  it("bounds a cached conversation while recording the trimmed items as earlier history", () => {
    const view = emptyView("large");
    view.items = Array.from({ length: 3002 }, (_, i) => ({ id: `${i}`, type: "message" }));
    cacheThreadView(view);
    const cached = getCachedThreadView("large")!;
    expect(cached.items).toHaveLength(3000);
    expect(cached.items[0]!.id).toBe("2");
    expect(cached.earlier.items).toBe(2);
    expect(view.items).toHaveLength(3002);
  });
});
