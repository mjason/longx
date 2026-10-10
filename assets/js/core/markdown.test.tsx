import { createElement, type ComponentProps } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import { describe, expect, test } from "vitest";
import { markdownPlugins, markdownMathPlugins } from "./markdown";
import { preprocessMath } from "./chat/math";
import { loadMath } from "@/ui/math/useMath";

function html(source: string, plugins: ComponentProps<typeof ReactMarkdown>["remarkPlugins"] = markdownPlugins) {
  return renderToStaticMarkup(createElement(ReactMarkdown, { remarkPlugins: plugins, children: source }));
}

describe.each([["GFM", markdownPlugins], ["GFM with math", markdownMathPlugins]] as const)(
  "CJK Markdown: %s",
  (_name, plugins) => {
    test.each([
      ["**测试。**后续文字", "<strong>测试。</strong>后续文字"],
      ["前文**（重要）**后文", "前文<strong>（重要）</strong>后文"],
      ["前文**「重点」**后文", "前文<strong>「重点」</strong>后文"],
      ["**测试，**后续文字", "<strong>测试，</strong>后续文字"],
      ["*测试。*后续文字", "<em>测试。</em>后续文字"],
      ["~~旧方案。~~新方案", "<del>旧方案。</del>新方案"],
      ["**日本語。**続き", "<strong>日本語。</strong>続き"],
      ["**괄호(parenthesis)**가", "<strong>괄호(parenthesis)</strong>가"],
    ])("parses %s without inserting spaces or changing text", (source, expected) => {
      expect(html(source, [...plugins])).toContain(expected);
    });

    test("list, table, nested emphasis and links retain their structure", () => {
      const result = html([
        "- **标题。**正文",
        "- ~~旧标题。~~新标题",
        "",
        "| 项目 | 说明 |",
        "| --- | --- |",
        "| **重点。**后文 | 前文**（说明）**后文 |",
        "",
        "**外层*内层。*文字**",
        "",
        "[**链接。**后文](https://example.com/a?q=1)",
      ].join("\n"), [...plugins]);
      expect(result).toContain("<li><strong>标题。</strong>正文</li>");
      expect(result).toContain("<li><del>旧标题。</del>新标题</li>");
      expect(result).toContain("<table>");
      expect(result).toContain("<td><strong>重点。</strong>后文</td>");
      expect(result).toContain("<strong>外层<em>内层。</em>文字</strong>");
      expect(result).toContain('<a href="https://example.com/a?q=1"><strong>链接。</strong>后文</a>');
    });

    test("code, escaped delimiters and incomplete streamed emphasis are not repaired", () => {
      const source = "`**测试。**后文` \\*\\*测试。\\*\\*后文\n\n```text\n**测试。**后文\n~~旧。~~后文\n```";
      const result = html(source, [...plugins]);
      expect(result).toContain("<code>**测试。**后文</code>");
      expect(result).toContain("**测试。**后文\n~~旧。~~后文\n</code>");
      expect(result).not.toContain("<strong>");
      expect(html("前文**（未完成", [...plugins])).not.toContain("<strong>");
      expect(html("前文**（已完成）**后文", [...plugins])).toContain("<strong>（已完成）</strong>");
    });

    test("ordinary English/GFM behavior and raw-HTML safety remain unchanged", () => {
      for (const source of [
        "foo_bar_baz **bold** *italic* ~~gone~~",
        "a**b**c and a *b* c",
        "- [x] done\n- [ ] todo",
        "<script>alert(1)</script>\n\n[unsafe](javascript:alert(1))",
        "https://example.com/path?q=a_b",
      ]) {
        const baseline = [...plugins].includes(remarkMath) ? [remarkGfm, remarkMath] : [remarkGfm];
        expect(html(source, [...plugins])).toBe(html(source, baseline));
      }
    });
  },
);

test("CJK emphasis coexists with inline and block KaTeX and preserves formula input", async () => {
  const source = "**公式。**后文 $r_{5,t}$\n\n$$\nx^2 + y^2 = z^2\n$$";
  const output = renderToStaticMarkup(createElement(ReactMarkdown, {
    remarkPlugins: markdownMathPlugins,
    rehypePlugins: await loadMath(),
    children: preprocessMath(source),
  }));
  expect(output).toContain("<strong>公式。</strong>后文");
  expect(output).toContain('class="katex"');
  expect(output).toContain('class="katex-display"');
  expect(output).toContain("r_{5,t}");
});
