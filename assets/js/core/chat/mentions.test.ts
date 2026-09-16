import { describe, expect, test } from "vitest";
import { fileFormatter, fileMentionItems, mentionFormatter, skillMentionItems, skillsIn } from "./mentions";

describe("file mentions", () => {
  test("a picked file goes into the text as codex's TUI writes it: @path, quoted when it has spaces", () => {
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

  test("codex's matches become popover items: the path is the id and label, the kind its type", () => {
    expect(fileMentionItems([{ path: "lib/a.ex", fileName: "a.ex", matchType: "file" }, { path: "lib", fileName: "lib", matchType: "directory" }])).toEqual([
      { id: "lib/a.ex", type: "file", label: "lib/a.ex", metadata: { icon: "file" } },
      { id: "lib", type: "directory", label: "lib", metadata: { icon: "directory" } },
    ]);
  });
});

describe("skill mentions ($name, codex's skills)", () => {
  const skills = [
    { name: "review-agent", description: "Review code changes", shortDescription: "review", path: "/p/.agents/skills/review-agent/SKILL.md", enabled: true },
    { name: "docs", description: "Write the docs", shortDescription: null, path: "/p/.agents/skills/docs/SKILL.md", enabled: true },
    { name: "off", description: "disabled", shortDescription: null, path: "/p/x/SKILL.md", enabled: false },
  ];

  test("the popover offers the enabled skills; a pick is written as $name", () => {
    expect(skillMentionItems(skills)).toEqual([
      { id: "review-agent", type: "skill", label: "review-agent", description: "review", metadata: { icon: "skill" } },
      { id: "docs", type: "skill", label: "docs", description: "Write the docs", metadata: { icon: "skill" } },
    ]);
    expect(mentionFormatter.serialize({ id: "docs", type: "skill", label: "docs" })).toBe("$docs");
    expect(mentionFormatter.serialize({ id: "lib/a.ex", type: "file", label: "lib/a.ex" })).toBe("@lib/a.ex");
  });

  test("the one formatter parses @files and $skills into chips; a $ inside a word or a price is text", () => {
    expect(mentionFormatter.parse("use $docs on @lib/a.ex please; costs $5")).toEqual([
      { kind: "text", text: "use " },
      { kind: "mention", type: "skill", label: "docs", id: "docs" },
      { kind: "text", text: " on " },
      { kind: "mention", type: "file", label: "lib/a.ex", id: "lib/a.ex" },
      { kind: "text", text: " please; costs $5" },
    ]);
  });

  test("skillsIn names the skills a message mentions, with their paths, once each, known ones only", () => {
    expect(skillsIn("run $docs then $docs and $review-agent, not $nope or $off", skills)).toEqual([
      { name: "docs", path: "/p/.agents/skills/docs/SKILL.md" },
      { name: "review-agent", path: "/p/.agents/skills/review-agent/SKILL.md" },
    ]);
    expect(skillsIn("plain", skills)).toEqual([]);
  });
});
