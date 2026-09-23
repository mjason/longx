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
    const onWatches = vi.fn();
    const onDefinition = vi.fn();

    const onGit = vi.fn();
    const onWatch = vi.fn();

    const leave = joinProjectChannel(socket as never, "abc", { onChanged, onFiles, onWatches, onDefinition, onGit, onWatch });

    expect(socket.channel).toHaveBeenCalledWith("project:abc", {});
    expect(channel.join).toHaveBeenCalled();

    handlers["changed"]!({});
    expect(onChanged).toHaveBeenCalledTimes(1);
    // a change under the root
    handlers["files"]!({ paths: ["/p/a.txt"] });
    expect(onFiles).toHaveBeenCalledWith(["/p/a.txt"]);
    // the watches changed (a run began or ended): refetch
    handlers["watches"]!({});
    expect(onWatches).toHaveBeenCalledTimes(1);
    // the agent description changed on disk: the page rereads it
    handlers["definition"]!({});
    expect(onDefinition).toHaveBeenCalledTimes(1);
    // HEAD, the index or a ref moved: the git window refetches
    handlers["git"]!({});
    expect(onGit).toHaveBeenCalledTimes(1);
    // the file watcher's state: whether the tree follows the disk by itself
    handlers["watch"]!({ watching: false, error: "the file watcher stopped (exit 137)" });
    expect(onWatch).toHaveBeenCalledWith({ watching: false, error: "the file watcher stopped (exit 137)" });
    expect(Object.keys(handlers).sort()).toEqual(["changed", "definition", "files", "git", "watch", "watches"]);

    leave();
    expect(channel.leave).toHaveBeenCalled();
  });
});
