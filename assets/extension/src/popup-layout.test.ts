import { expect, test } from "vitest";
import html from "./popup.html?raw";

test("name controls share a row and each field has its own layout group", () => {
  const popup = new DOMParser().parseFromString(html, "text/html");
  const input = popup.querySelector("#device-name")!;
  const save = popup.querySelector("#save-name")!;
  expect(input.parentElement).toBe(save.parentElement);
  expect(input.parentElement?.className).toBe("name-row");
  expect(input.closest(".field")).not.toBe(popup.querySelector("#server")?.closest(".field"));
  expect(popup.getElementById(input.getAttribute("aria-describedby")!)?.textContent).toContain("不是项目使用的别名");
});
