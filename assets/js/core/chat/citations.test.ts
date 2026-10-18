import { describe, expect, test } from "vitest";
import { unified } from "unified";
import remarkParse from "remark-parse";
import type { Root } from "mdast";
import { citationsOf, citationSources, sourceUrl } from "./citations";
import { remarkCitations } from "./remark-citations";
import { toMessages } from "./messages";
import { emptyView } from "./thread";

const marker = "citeturn0search2";
const url = "https://example.com/evidence";
function render(text: string, raw: unknown = [], pending = false) {
  const processor = unified().use(remarkParse).use(remarkCitations, {
    citations: citationsOf(raw), pending, missing: "〔来源未提供〕", loading: "〔引用解析中〕",
  });
  return processor.runSync(processor.parse(text)) as Root;
}
const citation = (start: number, end: number) => [{ url, title: "Evidence", start_index: start, end_index: end }];

describe("message citations", () => {
  test("uses assistant-ui source parts, scoped to each message item, and preserves original text", () => {
    const text = `证据${marker}`;
    const messages = toMessages({ ...emptyView("thread"), items: [{
      id: "a", type: "agentMessage", turnId: "turn", text,
      citations: citation(2, text.length),
    }, { id: "b", type: "agentMessage", turnId: "turn", text: marker }] });
    expect(messages[0]?.content).toMatchObject([
      { type: "text", text, providerMetadata: { longx: { citations: [{ number: 1, start: 2 }] } } },
      { type: "source", id: "a:source:1", url },
      { type: "text", text: marker },
    ]);
  });
  test("resolves exact ranges, not the number/order of search results", () => {
    const text = `证据${marker}`;
    expect(render(text, citation(2, text.length)).children[0]).toMatchObject({
      children: [{ type: "text", value: "证据" }, { type: "link", url, children: [{ value: "[1]" }] }],
    });
    expect(JSON.stringify(render(text, citation(0, 1)))).toContain("来源未提供");
    expect(JSON.stringify(render(text))).not.toContain("turn0search2");
  });
  test("standard prose annotations become inline links; missing positions still have a source chip", () => {
    expect(render("证据。后文", citation(0, 3)).children[0]).toMatchObject({
      children: [{ value: "证据。" }, { type: "link", url }, { value: "后文" }],
    });
    const sources = citationsOf([{ url }, { url }, { url: "javascript:alert(1)" }]);
    expect(citationSources("a", sources)).toHaveLength(1);
    expect(citationSources("a", sources)[0]).toMatchObject({ type: "source", url });
    expect(render("证据", [...citation(0, 2), ...citation(0, 2)]).children[0]).toMatchObject({
      children: [{ value: "证据" }, { type: "link", url }],
    });
  });
  test("streamed partial markers do not leak, code and existing links remain literal", () => {
    for (const partial of ["", "c", "ci", "cit", "cite", "citeturn"]) {
      expect(JSON.stringify(render(`正文${partial}`, [], true))).toContain("引用解析中");
    }
    expect(JSON.stringify(render("正文citeturn", [], true))).not.toContain("turn");
    expect(JSON.stringify(render(marker, [], true))).toContain("引用解析中");
    for (const text of [`\`${marker}\``, `\`\`\`text\n${marker}\n\`\`\``, `[${marker}](${url})`]) {
      expect(JSON.stringify(render(text))).toContain(marker);
    }
  });
  test("unsafe and credential-bearing URLs are not rendered", () => {
    for (const value of ["javascript:alert(1)", "data:text/html,x", "//evil.test", "https://user:pass@example.org", null]) {
      expect(sourceUrl(value)).toBeNull();
    }
    expect(citationsOf([null, {}, { url: 7 }, { url: "file:///etc/passwd" }])).toEqual([]);
  });
});
