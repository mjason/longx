import { describe, expect, test } from "vitest";
import { nextTheme, resolveTheme } from "./theme";

describe("resolveTheme", () => {
  test("system follows the OS, explicit choices win", () => {
    expect(resolveTheme("system", true)).toBe("dark");
    expect(resolveTheme("system", false)).toBe("light");
    expect(resolveTheme("light", true)).toBe("light");
    expect(resolveTheme("dark", false)).toBe("dark");
  });

  test("the toggle cycles dark → light → system", () => {
    expect(nextTheme("dark")).toBe("light");
    expect(nextTheme("light")).toBe("system");
    expect(nextTheme("system")).toBe("dark");
  });
});
