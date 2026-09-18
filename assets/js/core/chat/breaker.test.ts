import { describe, expect, test, vi } from "vitest";
import { createCloseTracker, createJoinBreaker } from "./breaker";
import { joinThreadChannel } from "./threadChannel";

describe("createJoinBreaker", () => {
  test("a join that keeps taking the socket down is given up after `limit` closes; a join that succeeds resets", () => {
    const b = createJoinBreaker({ limit: 3 });
    b.joinSent("thread:a");
    expect(b.socketClosed()).toEqual([]); // first close: counted, not tripped
    b.joinSent("thread:a");
    expect(b.socketClosed()).toEqual([]);
    b.joinSent("thread:a");
    expect(b.socketClosed()).toEqual(["thread:a"]); // third: tripped
    expect(b.tripped("thread:a")).toBe(true);
    // another topic on the same socket is untouched
    b.joinSent("thread:b");
    b.joined("thread:b");
    expect(b.tripped("thread:b")).toBe(false);
    expect(b.socketClosed()).toEqual([]); // b's join was answered: a close now counts for nobody
    // a reply (ok or error) means the join did not kill the socket: the count resets
    b.reset("thread:a");
    b.joinSent("thread:a");
    b.joined("thread:a");
    expect(b.tripped("thread:a")).toBe(false);
  });
});

describe("createCloseTracker", () => {
  test("many closes in a short window mark the socket unstable; a quiet stretch clears it", () => {
    const t = createCloseTracker({ limit: 5, windowMs: 60_000, calmMs: 30_000 });
    let now = 1_000;
    for (let i = 0; i < 4; i++) expect(t.closed(now + i * 100)).toBe(false);
    expect(t.closed(now + 500)).toBe(true);
    expect(t.unstable(now + 600)).toBe(true);
    // slower reconnects while unstable, phoenix's own ladder otherwise
    expect(t.reconnectAfterMs(1, now + 600)).toBeGreaterThanOrEqual(5_000);
    expect(t.reconnectAfterMs(1, now + 600)).toBeLessThanOrEqual(10_000);
    expect(createCloseTracker().reconnectAfterMs(1, 0)).toBe(10);
    expect(createCloseTracker().reconnectAfterMs(9, 0)).toBe(2000);
    expect(createCloseTracker().reconnectAfterMs(20, 0)).toBe(5000);
    // 30 s open without a close: calm again
    t.opened(now + 1_000);
    expect(t.unstable(now + 1_000 + 29_000)).toBe(true);
    expect(t.unstable(now + 1_000 + 31_000)).toBe(false);
  });
});

describe("joinThreadChannel with a breaker", () => {
  function fakeSocket() {
    const closeCbs: (() => void)[] = [];
    const replies: Record<string, (p: unknown) => void> = {};
    const chan = {
      on: vi.fn(),
      leave: vi.fn(),
      push: vi.fn(),
      join: vi.fn(() => {
        const r = { receive(status: string, cb: (p: unknown) => void) { replies[status] = cb; return r; } };
        return r;
      }),
    };
    return {
      socket: { channel: () => chan, onClose: (cb: () => void) => { closeCbs.push(cb); return "ref"; }, off: vi.fn() },
      close: () => closeCbs.forEach((cb) => cb()),
      chan,
      replies,
    };
  }

  test("three socket closes during one thread's join leave the channel and say so; a reply resets the count", () => {
    const { socket, close, chan, replies } = fakeSocket();
    const breaker = createJoinBreaker({ limit: 3 });
    const onError = vi.fn();
    joinThreadChannel(socket as never, "t1", { onSnapshot: vi.fn(), onEvent: vi.fn(), onError }, { breaker });
    close();
    close();
    expect(chan.leave).not.toHaveBeenCalled();
    close();
    expect(chan.leave).toHaveBeenCalledTimes(1);
    expect(onError).toHaveBeenCalledWith(expect.objectContaining({ reason: "unstable" }));

    // a fresh join whose reply arrives: no count, no leave
    const s2 = fakeSocket();
    const b2 = createJoinBreaker({ limit: 3 });
    joinThreadChannel(s2.socket as never, "t2", { onSnapshot: vi.fn(), onEvent: vi.fn() }, { breaker: b2 });
    s2.replies["ok"]?.({});
    s2.close(); s2.close(); s2.close();
    expect(s2.chan.leave).not.toHaveBeenCalled();
  });
});
