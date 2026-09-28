import { describe, expect, test, vi } from "vitest";
import { joinNotify, notificationFor, shouldNotify, waitingCount, type NotifyEvent } from "./notify";

const event = (over: Partial<NotifyEvent> = {}): NotifyEvent => ({
  kind: "approval",
  title: "数学精灵 · 等你确认",
  body: "登录 COROS",
  url: "/p/math/t/th1",
  project_id: "p1",
  thread_id: "th1",
  at: "2026-09-28T01:00:00Z",
  ...over,
});

function fakeSocket() {
  const handlers: Record<string, (payload: unknown) => void> = {};
  const receives: Record<string, (payload: unknown) => void> = {};
  const push = {
    receive: vi.fn((status: string, cb: (payload: unknown) => void) => {
      receives[status] = cb;
      return push;
    }),
  };
  const channel = {
    on: vi.fn((name: string, cb: (payload: unknown) => void) => {
      handlers[name] = cb;
      return 0;
    }),
    join: vi.fn(() => push),
    leave: vi.fn(),
  };
  return { socket: { channel: vi.fn(() => channel) }, channel, handlers, receives };
}

describe("the notify feed on a page", () => {
  test("joins `notify`: what waits now from the join reply, then one event per push", () => {
    const { socket, channel, handlers, receives } = fakeSocket();
    const onRunning = vi.fn();
    const onEvent = vi.fn();
    const leave = joinNotify(socket as never, { onRunning, onEvent });

    expect(socket.channel).toHaveBeenCalledWith("notify", {});
    receives["ok"]!({ running: [{ id: "a", waiting: true }, { id: "b", waiting: false }] });
    expect(onRunning).toHaveBeenCalledWith([{ id: "a", waiting: true }, { id: "b", waiting: false }]);
    handlers["event"]!(event());
    expect(onEvent).toHaveBeenCalledWith(event());

    leave();
    expect(channel.leave).toHaveBeenCalled();
  });

  test("a system notification only while the page is out of sight or out of focus", () => {
    expect(shouldNotify({ visible: true, focused: true })).toBe(false);
    expect(shouldNotify({ visible: false, focused: false })).toBe(true);
    expect(shouldNotify({ visible: true, focused: false })).toBe(true);
  });

  test("one notification per thread and kind (a second replaces the first); the click opens its page", () => {
    expect(notificationFor(event())).toEqual({
      title: "数学精灵 · 等你确认",
      options: {
        body: "登录 COROS",
        tag: "th1:approval",
        icon: "/icons/icon-192.png",
        data: { url: "/p/math/t/th1" },
        requireInteraction: true,
      },
    });
    const done = notificationFor(event({ kind: "turn_completed", thread_id: null }));
    expect(done.options.tag).toBe("/p/math/t/th1:turn_completed");
    expect(done.options.requireInteraction).toBe(false);
  });

  test("the badge counts the threads waiting on the person", () => {
    expect(waitingCount([{ waiting: true }, { waiting: false }, { waiting: true }])).toBe(2);
    expect(waitingCount(undefined)).toBe(0);
  });
});
