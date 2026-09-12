import { describe, expect, test } from "vitest";
import { formatBytes, formatDuration, relativeTime, shortSha } from "./format";

describe("formatBytes", () => {
  test("picks a unit and keeps one decimal only below 10", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(15 * 1024)).toBe("15 KB");
    expect(formatBytes(2.5 * 1024 * 1024 * 1024)).toBe("2.5 GB");
  });

  test("nonsense is a dash", () => {
    expect(formatBytes(-1)).toBe("—");
    expect(formatBytes(NaN)).toBe("—");
  });
});

describe("relativeTime", () => {
  const now = new Date("2026-09-12T12:00:00Z");
  test("buckets", () => {
    expect(relativeTime(null, now)).toBe("从未");
    expect(relativeTime("2026-09-12T11:59:50Z", now)).toBe("刚刚");
    expect(relativeTime("2026-09-12T11:57:00Z", now)).toBe("3 分钟前");
    expect(relativeTime("2026-09-12T09:00:00Z", now)).toBe("3 小时前");
    expect(relativeTime("2026-09-10T12:00:00Z", now)).toBe("2 天前");
  });
});

test("shortSha and formatDuration", () => {
  expect(shortSha("372bb0366a5ae41b7b764badb63c5d765b72b550")).toBe("372bb036");
  expect(shortSha(null)).toBe("—");
  expect(formatDuration(250)).toBe("250 ms");
  expect(formatDuration(65_000)).toBe("1 min 5 s");
});
