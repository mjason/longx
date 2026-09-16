import { describe, expect, test, vi } from "vitest";
import { createSteerQueue } from "./steerQueue";

describe("createSteerQueue", () => {
  test("holds nothing: enqueue and steer both hand the message to onNew at once", async () => {
    const onNew = vi.fn(async () => {});
    const queue = createSteerQueue(onNew);
    const message = { role: "user", content: [{ type: "text", text: "now" }] } as never;
    queue.steer(message);
    queue.enqueue(message);
    expect(onNew).toHaveBeenCalledTimes(2);
    expect(queue.items).toEqual([]);
    expect(queue.steerItems).toEqual([]);
  });
});
