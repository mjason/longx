import { describe, expect, test } from "vitest";
import { reasoningSteps } from "./reasoningSteps";

describe("reasoningSteps", () => {
  test("bold headings (OpenAI-style summaries) title the steps, the paragraphs after them are the body", () => {
    const text = "**Planning the fix**\n\nI'll look at the schema first.\n\nThen the diagram.\n\n**Writing it**\n\nDone.";
    expect(reasoningSteps(text)).toEqual([
      { title: "Planning the fix", body: "I'll look at the schema first.\n\nThen the diagram." },
      { title: "Writing it", body: "Done." },
    ]);
  });

  test("raw thinking (no headings): each paragraph is a step, its first sentence the title", () => {
    const text = "好的，用户让我看这张图。图里是一个红色方块，很明显。\n\n所以直接回答颜色就行";
    expect(reasoningSteps(text)).toEqual([
      { title: "好的，用户让我看这张图。", body: "图里是一个红色方块，很明显。" },
      { title: "所以直接回答颜色就行", body: "" },
    ]);
  });

  test("a question mark inside brackets does not end the sentence", () => {
    expect(reasoningSteps("The user shows an image (white/blank?). Let me think.")).toEqual([{ title: "The user shows an image (white/blank?).", body: "Let me think." }]);
    expect(reasoningSteps("这是红的（还是白的？）。再看看")).toEqual([{ title: "这是红的（还是白的？）。", body: "再看看" }]);
  });

  test("a long first sentence is cut for the title, the whole paragraph stays the body; markdown marks are dropped", () => {
    const long = "This `first` sentence goes on and on without any stop to speak of for quite a while indeed";
    const [step] = reasoningSteps(long);
    expect(step!.title.length).toBeLessThanOrEqual(61);
    expect(step!.title.endsWith("…")).toBe(true);
    expect(step!.title).not.toContain("`");
    expect(step!.body).toBe(long.replace(/`/g, ""));
    expect(reasoningSteps("")).toEqual([]);
  });
});
