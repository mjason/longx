import { render, screen, waitFor } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { CodeEditor } from "./CodeEditor";
import { languageFor } from "./languages";

describe("CodeEditor (CodeMirror 6)", () => {
  test("shows the document, reports edits, and takes a new value from outside", async () => {
    const onChange = vi.fn();
    const { rerender } = render(<CodeEditor path="lib/a.ex" value={"defmodule A do\nend\n"} onChange={onChange} />);
    const editor = await screen.findByTestId("code-editor");
    expect(editor.querySelector(".cm-content")).toHaveTextContent("defmodule A do");
    expect(editor.querySelector(".cm-editor")).not.toBeNull();

    rerender(<CodeEditor path="lib/a.ex" value={"changed\n"} onChange={onChange} />);
    await waitFor(() => expect(editor.querySelector(".cm-content")).toHaveTextContent("changed"));
    // an outside value is not an edit
    expect(onChange).not.toHaveBeenCalled();
  });

  test("read-only documents cannot be typed into", async () => {
    render(<CodeEditor path="README.md" value="hello" readOnly />);
    const content = (await screen.findByTestId("code-editor")).querySelector(".cm-content")!;
    expect(content).toHaveAttribute("contenteditable", "false");
  });

  test("languageFor picks a mode by file name and stays quiet for unknown ones", () => {
    expect(languageFor("lib/a.ex")?.name).toBe("Elixir");
    expect(languageFor("app.tsx")?.name).toBe("TSX");
    expect(languageFor("README.md")?.name).toBe("Markdown");
    expect(languageFor("Dockerfile")?.name).toBe("Dockerfile");
    expect(languageFor("weird.zzz")).toBeUndefined();
  });
});
