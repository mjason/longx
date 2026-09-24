import { diff, type Change } from "@codemirror/merge";
import { describe, expect, test } from "vitest";
import { lineDiff } from "./lineDiff";

// what the changes say, as text: every unchanged stretch must be equal on
// both sides, and the changes rebuild b from a
function apply(a: string, b: string, changes: readonly Change[]) {
  let out = "";
  let pos = 0;
  for (const c of changes) {
    expect(a.slice(pos, c.fromA)).toBe(b.slice(out.length, out.length + (c.fromA - pos)));
    out += a.slice(pos, c.fromA) + b.slice(c.fromB, c.toB);
    pos = c.toA;
  }
  return out + a.slice(pos);
}

const pkg = (i: number, hash = "aaaa") =>
  `[[package]]\nname = "pkg-${i}"\nversion = "1.${i}.0"\nsdist = { url = "https://files.example/${hash}${i}.tar.gz" }\n`;

describe("lineDiff — lines first, characters only inside what changed (as VS Code does)", () => {
  test("a lock file with a block added at the top and versions changed all through it: those lines, not the whole file", () => {
    const pkgs = (bump: boolean) =>
      Array.from({ length: 3000 }, (_, i) => pkg(i).replace(`"1.${i}.0"`, bump && i % 10 === 0 ? `"1.${i}.1"` : `"1.${i}.0"`)).join("\n");
    const a = `version = 1\nrevision = 3\n\n${pkgs(false)}`;
    const inserted = `resolution-markers = [\n    "sys_platform == 'win32'",\n]\n`;
    const b = `version = 1\nrevision = 3\n${inserted}\n${pkgs(true)}`;

    // the merge view's own default gives up on changes spread this wide: most of the file marked
    const marked = (cs: readonly Change[]) => cs.reduce((n, c) => n + (c.toA - c.fromA) + (c.toB - c.fromB), 0);
    expect(marked(diff(a, b, { scanLimit: 500 }))).toBeGreaterThan(a.length / 2);

    const changes = lineDiff(a, b);
    expect(apply(a, b, changes)).toBe(b);
    expect(changes).toHaveLength(1 + 300);
    const [added, ...bumped] = changes;
    expect(a.slice(added!.fromA, added!.toA)).toBe("");
    expect(b.slice(added!.fromB, added!.toB)).toBe(inserted);
    // only the characters that differ inside each changed line
    for (const c of bumped) {
      expect(a.slice(c.fromA, c.toA)).toBe("0");
      expect(b.slice(c.fromB, c.toB)).toBe("1");
    }
  });

  test("the same text has no change; the last line with or without a newline", () => {
    expect(lineDiff("a\nb", "a\nb")).toEqual([]);
    const cases: [string, string][] = [
      ["x", "x\ny"],
      ["x\ny", "x"],
      ["x\n", "x"],
      ["x", "x\n"],
      ["", "one\ntwo\n"],
      ["one\ntwo\n", ""],
      ["a\nb\nc", "a\nB\nc"],
    ];
    for (const [a, b] of cases) expect(apply(a, b, lineDiff(a, b))).toBe(b);
  });

  test("a long block where every line changed a little: each line compared with its counterpart, only what differs marked", () => {
    const wheel = (host: string, i: number) =>
      `    { url = "https://${host}/packages/f4/${String(i).padStart(4, "0")}/numpy-2.0.${i}-cp314-cp314-manylinux_2_28_x86_64.whl", hash = "sha256:${"ab".repeat(32)}", size = 1${i} },\n`;
    const block = (host: string) => Array.from({ length: 120 }, (_, i) => wheel(host, i)).join("");
    const a = `wheels = [\n${block("mirrors.volces.com/pypi")}]\n`;
    const b = `wheels = [\n${block("pypi.tuna.tsinghua.edu.cn")}]\n`;
    const changes = lineDiff(a, b);
    expect(apply(a, b, changes)).toBe(b);
    // one small change per line: the host, never the whole block
    expect(changes.length).toBeGreaterThanOrEqual(120);
    for (const c of changes) expect(c.toA - c.fromA + (c.toB - c.fromB)).toBeLessThan(60);
  });

  test("lines that have nothing in common are one change, not a scatter of matching letters", () => {
    const a = "alpha beta gamma\ndelta epsilon\n";
    const b = "zeta eta theta\niota kappa lambda\n";
    const changes = lineDiff(a, b);
    expect(apply(a, b, changes)).toBe(b);
    expect(changes).toHaveLength(1);
  });
});
