import { describe, expect, test } from "vitest";
import { daysLeft, envInput, parseDomains, providerLabel, tlsBusy } from "./https";

describe("https", () => {
  test("the variables sent: what was typed, and null for a stored one cleared; an empty field keeps the stored value", () => {
    expect(envInput({ TENCENTCLOUD_SECRET_ID: " AKID ", TENCENTCLOUD_SECRET_KEY: "" }, [])).toEqual([
      { name: "TENCENTCLOUD_SECRET_ID", value: "AKID" },
    ]);
    expect(envInput({ TENCENTCLOUD_TTL: "" }, ["TENCENTCLOUD_TTL"])).toEqual([{ name: "TENCENTCLOUD_TTL", value: null }]);
    // typed after clearing: the new value wins
    expect(envInput({ TENCENTCLOUD_TTL: "120" }, ["TENCENTCLOUD_TTL"])).toEqual([{ name: "TENCENTCLOUD_TTL", value: "120" }]);
  });

  test("names separated by commas, spaces or lines", () => {
    expect(parseDomains("lx.example.com, *.lx.example.com\nother.example.com，x.example.com")).toEqual([
      "lx.example.com",
      "*.lx.example.com",
      "other.example.com",
      "x.example.com",
    ]);
    expect(parseDomains("  ")).toEqual([]);
  });

  test("the busy stages, a provider's label, the days left", () => {
    expect(tlsBusy("issuing")).toBe(true);
    expect(tlsBusy("downloading")).toBe(true);
    expect(tlsBusy("idle")).toBe(false);
    expect(tlsBusy("failed")).toBe(false);
    expect(providerLabel({ code: "tencentcloud", name: "Tencent Cloud DNS" })).toBe("腾讯云 DNSPod");
    expect(providerLabel({ code: "gandi", name: "Gandi" })).toBe("Gandi");
    expect(daysLeft("2026-12-26T00:00:00Z", new Date("2026-09-27T00:00:00Z"))).toBe(90);
    expect(daysLeft(null)).toBe(null);
  });
});
