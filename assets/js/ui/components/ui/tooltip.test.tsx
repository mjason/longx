import { render } from "@testing-library/react";
import { describe, expect, test } from "vitest";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "./tooltip";

function Tip({ arrow }: { arrow?: boolean }) {
  return (
    <TooltipProvider>
      <Tooltip open>
        <TooltipTrigger>t</TooltipTrigger>
        <TooltipContent {...(arrow === undefined ? {} : { arrow })}>hello</TooltipContent>
      </Tooltip>
    </TooltipProvider>
  );
}

describe("TooltipContent", () => {
  test("a plain tooltip points at its trigger; a card-style one (arrow={false}) has no arrow — Radix inlines display on it, so a class cannot hide it", () => {
    const plain = render(<Tip />);
    expect(document.querySelector("[data-slot=tooltip-arrow]")).not.toBeNull();
    plain.unmount();
    render(<Tip arrow={false} />);
    expect(document.querySelector("[data-slot=tooltip-arrow]")).toBeNull();
  });
});
