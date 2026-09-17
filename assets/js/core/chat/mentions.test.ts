import { describe, expect, test } from "vitest";
import { fileFormatter, fileMentionItems, mentionFormatter } from "./mentions";

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
  test("is the file formatter: @files become chips, a lone $ or a price stays text", () => {
    expect(mentionFormatter.serialize({ id: "lib/a.ex", type: "file", label: "lib/a.ex" })).toBe("@lib/a.ex");
    expect(mentionFormatter.parse("look at @lib/a.ex please; costs $5")).toEqual([
      { kind: "text", text: "look at " },
      { kind: "mention", type: "file", label: "lib/a.ex", id: "lib/a.ex" },
      { kind: "text", text: " please; costs $5" },
    ]);
  });
});
