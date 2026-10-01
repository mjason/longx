import { describe, expect, test } from "vitest";
import { fileFormatter, fileMentionItems, mentionFormatter, mentionTriggerMatch, sessionMentionItems, withSessionDelivery } from "./mentions";

describe("file mentions", () => {
  test("a picked file goes into the text as @path, quoted when it has spaces", () => {
    expect(fileFormatter.serialize({ id: "lib/a.ex", type: "file", label: "lib/a.ex" })).toBe("@lib/a.ex");
    expect(fileFormatter.serialize({ id: "docs/my notes.md", type: "file", label: "my notes.md" })).toBe('@"docs/my notes.md"');
  });

  test("parse finds the @paths in a message and keeps the rest as text", () => {
    expect(fileFormatter.parse('look at @lib/a.ex and @"docs/my notes.md" please')).toEqual([
      { kind: "text", text: "look at " },
      { kind: "mention", type: "file", label: "lib/a.ex", id: "lib/a.ex" },
      { kind: "text", text: " and " },
      { kind: "mention", type: "file", label: "docs/my notes.md", id: "docs/my notes.md" },
      { kind: "text", text: " please" },
    ]);
    // an email or a lone @ is not a mention
    expect(fileFormatter.parse("mail me@example.com or @")).toEqual([{ kind: "text", text: "mail me@example.com or @" }]);
    expect(fileFormatter.parse("")).toEqual([]);
  });

  test("the server's matches become popover items: the path is the id and label, the kind its type", () => {
    expect(fileMentionItems([{ path: "lib/a.ex", fileName: "a.ex", matchType: "file" }, { path: "lib", fileName: "lib", matchType: "directory" }])).toEqual([
      { id: "lib/a.ex", type: "file", label: "lib/a.ex", metadata: { icon: "file" } },
      { id: "lib", type: "directory", label: "lib", metadata: { icon: "directory" } },
    ]);
  });
});

describe("the message formatter", () => {
  test("Chinese text and punctuation can directly precede @ without triggering on an email", () => {
    expect(mentionTriggerMatch("发给@notes", "@", 8)).toEqual({ query: "notes", offset: 2, endOffset: 8 });
    expect(mentionTriggerMatch("接收会话：@notes", "@", 11)).toEqual({ query: "notes", offset: 5, endOffset: 11 });
    expect(mentionTriggerMatch("me@notes.com", "@", 12)).toBeNull();
    expect(mentionTriggerMatch("给 @notes 后", "@", 10)).toBeNull();
    expect(mentionTriggerMatch('@session("p:notes")', "@", 19)).toBeNull();
  });

  test("is the file formatter: @files become chips, a lone $ or a price stays text", () => {
    expect(mentionFormatter.serialize({ id: "lib/a.ex", type: "file", label: "lib/a.ex" })).toBe("@lib/a.ex");
    expect(mentionFormatter.parse("look at @lib/a.ex please; costs $5")).toEqual([
      { kind: "text", text: "look at " },
      { kind: "mention", type: "file", label: "lib/a.ex", id: "lib/a.ex" },
      { kind: "text", text: " please; costs $5" },
    ]);
  });

  test("session references are distinct from files and carry a full cross-project address", () => {
    const item = { id: "session:逛论坛:notes", type: "session", label: "notes", metadata: { address: "逛论坛:notes" } };
    expect(mentionFormatter.serialize(item)).toBe('@session("逛论坛:notes")');
    const draft = '先写完文章，再发给 @session("逛论坛:notes")';
    const sent = withSessionDelivery(draft);
    expect(sent).toContain("send_message");
    expect(sent).toContain("完整正文");
    expect(sent).toContain("先在当前会话完成");
    expect(withSessionDelivery(sent)).toBe(sent);
    expect(mentionFormatter.parse(sent)).toEqual([
      { kind: "text", text: "先写完文章，再发给 " },
      { kind: "mention", type: "session", label: "逛论坛:notes", id: "逛论坛:notes" },
    ]);
    expect(withSessionDelivery("read @lib/a.ex")).toBe("read @lib/a.ex");
  });

  test("session completion filters duty, self and unavailable sessions and searches handles, titles and addresses", () => {
    const base = { threadId: "other", handle: "notes", address: "逛论坛:notes", title: "接受报告", preview: null, state: "idle", onDuty: true };
    const rows = [
      base,
      { ...base, threadId: "self", address: "main" },
      { ...base, threadId: "off", address: "逛论坛:off", onDuty: false },
      { ...base, threadId: "old", state: "unrecoverable" },
    ];
    expect(sessionMentionItems(rows, "notes", "self", "source")).toEqual([
      expect.objectContaining({ id: "session:逛论坛:notes", type: "session", metadata: { address: "逛论坛:notes", icon: "session" } }),
    ]);
    expect(sessionMentionItems(rows, "接受", "self", "source")).toHaveLength(1);
    expect(sessionMentionItems(rows, "missing", "self", "source")).toEqual([]);
    expect(sessionMentionItems([{ ...base, address: "notes" }], "", "self", "source")[0]?.metadata?.address).toBe("source:notes");
  });
});
