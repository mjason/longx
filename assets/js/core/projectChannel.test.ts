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
  test("joins project:<id> and dispatches the events", () => {
    const { socket, channel, handlers } = fakeSocket();
    const onChanged = vi.fn();
    const onFiles = vi.fn();

    const leave = joinProjectChannel(socket as never, "abc", { onChanged, onFiles });

    expect(socket.channel).toHaveBeenCalledWith("project:abc", {});
    expect(channel.join).toHaveBeenCalled();

    handlers["changed"]!({});
    expect(onChanged).toHaveBeenCalledTimes(1);
    // a change under the root
    handlers["files"]!({ paths: ["/p/a.txt"] });
    expect(onFiles).toHaveBeenCalledWith(["/p/a.txt"]);
    expect(Object.keys(handlers).sort()).toEqual(["changed", "files"]);

    leave();
    expect(channel.leave).toHaveBeenCalled();
  });
});
