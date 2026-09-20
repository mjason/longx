import { describe, expect, test } from "vitest";
import { sessionTitle } from "./projects";

describe("sessionTitle", () => {
  test("the title, else the preview clipped to a name's length, else the address", () => {
    expect(sessionTitle({ title: "coder 定义流", preview: "x" }, "~052ca4")).toBe("coder 定义流");
    expect(sessionTitle({ title: null, preview: "你叫小蓝。以后有人问你名字或者叫你做什么，就用一句话回答，说明你是小蓝。" }, "~43c21a")).toBe("你叫小蓝。以后有人问你名字或者叫你做什么，就用一…");
    expect(sessionTitle({ title: null, preview: null }, "~43c21a")).toBe("~43c21a");
  });
});
