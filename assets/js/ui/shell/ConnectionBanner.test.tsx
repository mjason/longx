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

  test("the page drawn from this device's cache (the server was out of reach) says so, whatever the socket", () => {
    render(<ConnectionBanner status="open" offline />);
    const banner = screen.getByTestId("connection-banner");
    expect(banner).toHaveAttribute("data-status", "offline");
    expect(banner).toHaveTextContent("服务器暂时连不上");
  });
});
