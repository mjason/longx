import { describe, expect, test } from "vitest";
import { resolveTheme } from "./theme";

describe("resolveTheme", () => {
  test("system follows the OS, explicit choices win", () => {
    expect(resolveTheme("system", true)).toBe("dark");
    expect(resolveTheme("system", false)).toBe("light");
    expect(resolveTheme("light", true)).toBe("light");
    expect(resolveTheme("dark", false)).toBe("dark");
  });
});
