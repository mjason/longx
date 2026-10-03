import { afterEach, expect, test, vi } from "vitest";
import { observeThreadContentSize } from "./scroll";

afterEach(() => vi.unstubAllGlobals());

test("CSS-only content resizing notifies viewport mutations without writing scrollTop", () => {
  let resized!: ResizeObserverCallback;
  const observe = vi.fn();
  const disconnect = vi.fn();
  vi.stubGlobal("ResizeObserver", class {
    constructor(callback: ResizeObserverCallback) { resized = callback; }
    observe = observe;
    disconnect = disconnect;
  });
  const viewport = document.createElement("div");
  const content = document.createElement("div");
  viewport.append(content);
  viewport.scrollTop = 42;
  const setAttribute = vi.spyOn(content, "setAttribute");
  const dispose = observeThreadContentSize(content);
  expect(observe).toHaveBeenCalledWith(content);
  const resize = (height: number) => resized(
    [{ contentRect: { width: 768, height } } as ResizeObserverEntry],
    {} as ResizeObserver,
  );
  resize(1000);
  expect(content).toHaveAttribute("data-scroll-size", "768:1000");
  resize(1000);
  expect(setAttribute).toHaveBeenCalledTimes(1);
  resize(1100);
  expect(content).toHaveAttribute("data-scroll-size", "768:1100");
  expect(viewport.scrollTop).toBe(42);
  dispose();
  expect(disconnect).toHaveBeenCalledOnce();
});
