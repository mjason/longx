import { render, screen, waitFor } from "@testing-library/react";
import { describe, expect, test } from "vitest";
import { DiffView } from "./DiffView";

describe("DiffView (@codemirror/merge)", () => {
  test("split: both versions side by side, the changed line marked, unchanged stretches collapsed", async () => {
    const before = ["a", ...Array.from({ length: 20 }, (_, i) => `same ${i}`), "old"].join("\n");
    const after = ["a", ...Array.from({ length: 20 }, (_, i) => `same ${i}`), "new"].join("\n");
    render(<DiffView path="lib/x.ex" before={before} after={after} mode="split" />);
    const view = await screen.findByTestId("diff-view");
    expect(view.querySelector(".cm-mergeView")).not.toBeNull();
    expect(view.querySelectorAll(".cm-mergeViewEditor")).toHaveLength(2);
    await waitFor(() => expect(view.querySelector(".cm-changedLine")).not.toBeNull());
    expect(view.querySelector(".cm-collapsedLines")).toHaveTextContent(/\d+ 行未改动/);
    // read-only on both sides
    for (const c of view.querySelectorAll(".cm-content")) expect(c).toHaveAttribute("contenteditable", "false");
  });

  test("unified: one editor with the old text inline; a side that did not exist is empty", async () => {
    render(<DiffView path="new.txt" before={null} after={"hello\n"} mode="unified" />);
    const view = await screen.findByTestId("diff-view");
    expect(view.querySelector(".cm-mergeView")).toBeNull();
    expect(view.querySelectorAll(".cm-editor")).toHaveLength(1);
    await waitFor(() => expect(view.querySelector(".cm-changedLine, .cm-inlineChangedLine, .cm-insertedLine")).not.toBeNull());
    expect(view.querySelector(".cm-content")).toHaveTextContent("hello");
  });
});
