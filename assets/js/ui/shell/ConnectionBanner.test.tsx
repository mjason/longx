import { render, screen } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import { ConnectionBanner } from "./ConnectionBanner";

vi.mock("@/core/socket", async () => (await import("@/ui/test-mocks")).socketMock());

describe("ConnectionBanner", () => {
  test("nothing while open; the reconnecting line while closed; a red line naming the server while unstable", () => {
    const { rerender } = render(<ConnectionBanner status="open" />);
    expect(screen.queryByTestId("connection-banner")).toBeNull();
    rerender(<ConnectionBanner status="closed" />);
    expect(screen.getByTestId("connection-banner")).toHaveTextContent("正在重连");
    rerender(<ConnectionBanner status="unstable" />);
    const banner = screen.getByTestId("connection-banner");
    expect(banner).toHaveAttribute("data-status", "unstable");
    expect(banner).toHaveTextContent("反复断开");
    expect(banner).toHaveTextContent("日志");
  });
});
