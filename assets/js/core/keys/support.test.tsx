import { act, render } from "@testing-library/react";
import { afterEach, describe, expect, test, vi } from "vitest";
import { _resetIntentsForTests, requestIntent, useIntent } from "./intents";
import { getPreference, setPreference } from "./preference";

function Consumer({ onIntent }: { onIntent: (p: unknown) => void }) {
  useIntent("git.branches", onIntent);
  return null;
}

describe("intents and preferences", () => {
  afterEach(() => {
    _resetIntentsForTests();
    localStorage.clear();
  });

  test("an intent asked for before its part is on screen is handled when it mounts; after that, at once", () => {
    const handled = vi.fn();
    requestIntent("git.branches", { from: "SPC g b" });
    render(<Consumer onIntent={handled} />);
    expect(handled).toHaveBeenCalledWith({ from: "SPC g b" });
    act(() => requestIntent("git.branches"));
    expect(handled).toHaveBeenCalledTimes(2);
  });

  test("the space menu and the offline cache are on unless turned off; notifications off until asked for", () => {
    expect(getPreference("spaceMenu")).toBe(true);
    expect(getPreference("offlineCache")).toBe(true);
    expect(getPreference("notifications")).toBe(false);
    setPreference("spaceMenu", false);
    setPreference("notifications", true);
    expect(getPreference("spaceMenu")).toBe(false);
    expect(getPreference("notifications")).toBe(true);
  });
});
