import { describe, expect, test } from "vitest";
import { gitPollInterval } from "./workspace";

describe("gitPollInterval", () => {
  test("the git window polls only while nothing watches the files", () => {
    expect(gitPollInterval(false, null)).toBe(false);
    // not known yet, or the watcher down: poll
    expect(gitPollInterval(true, null)).toBe(10_000);
    expect(gitPollInterval(true, { watching: false, error: "stopped" })).toBe(10_000);
    // a watcher that could not watch everything: poll as well
    expect(gitPollInterval(true, { watching: true, error: "could not watch a: too many" })).toBe(10_000);
    // watching: HEAD, the index and the files arrive as events
    expect(gitPollInterval(true, { watching: true, error: null })).toBe(false);
  });
});
