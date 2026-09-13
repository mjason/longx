import { describe, expect, test, vi } from "vitest";
import { joinProjectChannel } from "./projectChannel";

function fakeSocket() {
  const handlers: Record<string, (payload: unknown) => void> = {};
  const channel = {
    on: vi.fn((event: string, cb: (payload: unknown) => void) => {
      handlers[event] = cb;
      return 0;
    }),
    join: vi.fn(),
    leave: vi.fn(),
  };
  const socket = { channel: vi.fn(() => channel) };
  return { socket, channel, handlers };
}

describe("joinProjectChannel", () => {
  test("joins project:<id> and dispatches the three events", () => {
    const { socket, channel, handlers } = fakeSocket();
    const onChanged = vi.fn();
    const onCodex = vi.fn();
    const onSample = vi.fn();

    const leave = joinProjectChannel(socket as never, "abc", { onChanged, onCodex, onSample });

    expect(socket.channel).toHaveBeenCalledWith("project:abc", {});
    expect(channel.join).toHaveBeenCalled();

    handlers["changed"]!({});
    handlers["codex"]!({ status: "down" });
    handlers["sample"]!({ rss_bytes: 1, processes: 1, cpu_ms: 0, uptime_ms: 5, turns: 0, active_turns: 0 });

    expect(onChanged).toHaveBeenCalledTimes(1);
    expect(onCodex).toHaveBeenCalledWith("down");
    expect(onSample).toHaveBeenCalledWith(expect.objectContaining({ rss_bytes: 1 }));

    leave();
    expect(channel.leave).toHaveBeenCalled();
  });
});
