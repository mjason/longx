import { expect, test } from "vitest";
import { generatedDeviceName, normalizeDeviceName } from "./device-name";

test("generated names identify platform and installation without pretending to know a hostname", () => {
  expect(generatedDeviceName("uuid-123abc", "mac", "Chrome/154.0")).toBe("Chrome 154 · macOS · 123abc");
  expect(generatedDeviceName("uuid-456def", "mac", "Chrome/154.0")).not.toBe(
    generatedDeviceName("uuid-123abc", "mac", "Chrome/154.0"),
  );
});

test("custom names are trimmed, bounded and single-line", () => {
  expect(normalizeDeviceName("  桌面 Mac  ")).toBe("桌面 Mac");
  for (const name of [" ", "x".repeat(81), "a\nb", "a\0b"]) {
    expect(() => normalizeDeviceName(name)).toThrow("设备名称");
  }
});
