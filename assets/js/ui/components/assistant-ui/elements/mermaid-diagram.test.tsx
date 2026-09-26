import { render, screen } from "@testing-library/react";
import { describe, expect, test } from "vitest";
import { MermaidDiagram } from "./mermaid-diagram";

// the renderer (beautiful-mermaid + elkjs, 1.9 MB) is fetched the first time a
// diagram shows, not with the page: the skeleton until then, the drawing after
describe("MermaidDiagram", () => {
  test("draws the diagram once its renderer has loaded", async () => {
    render(<MermaidDiagram code={"graph TD\n  A-->B"} />);
    expect(screen.getByLabelText("Rendering diagram")).toBeInTheDocument();
    const drawn = await screen.findByTestId("mermaid-drawn", undefined, { timeout: 10_000 });
    expect(drawn.querySelector("svg")).not.toBeNull();
  });
});
