import { describe, expect, test } from "vitest";
import { createBatcher } from "./batch";

describe("createBatcher", () => {
  test("items pushed before the scheduled flush go out together, in order; the next push schedules again", () => {
    const flushed: number[][] = [];
    const ticks: (() => void)[] = [];
    const b = createBatcher<number>((items) => flushed.push(items), (cb) => ticks.push(cb));
    b.push(1);
    b.push(2);
    expect(ticks).toHaveLength(1);
    expect(flushed).toEqual([]);
    ticks[0]!();
    expect(flushed).toEqual([[1, 2]]);
    b.push(3);
    expect(ticks).toHaveLength(2);
    ticks[1]!();
    expect(flushed).toEqual([[1, 2], [3]]);
  });

  test("cancel drops what is pending", () => {
    const flushed: number[][] = [];
    const ticks: (() => void)[] = [];
    const b = createBatcher<number>((items) => flushed.push(items), (cb) => ticks.push(cb));
    b.push(1);
    b.cancel();
    ticks[0]!();
    expect(flushed).toEqual([]);
  });
});
