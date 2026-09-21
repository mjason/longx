import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { describe, expect, test } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { createElement } from "react";
import ReactMarkdown from "react-markdown";
import remarkMath from "remark-math";
import { loadMath } from "./useMath";

const require = createRequire(import.meta.url);

describe("the KaTeX the page renders with and the stylesheet it loads", () => {
  test("are one version: every sizing class the HTML carries has a rule in the CSS (two copies once left subscripts full-size at the baseline)", async () => {
    const plugins = await loadMath();
    const html = renderToStaticMarkup(createElement(ReactMarkdown, { remarkPlugins: [remarkMath], rehypePlugins: plugins, children: "$r_{5,t}$" }));
    const css = readFileSync(require.resolve("katex/dist/katex.min.css"), "utf8");
    const sizing = html.match(/class="([^"]*size\d[^"]*)"/)?.[1]?.split(" ");
    expect(sizing).toBeDefined();
    // the sizing classes proper (`sizing` / `katex-sizing`, `reset-size6`, `size3`); `mtight` is a marker without a rule
    for (const cls of sizing!.filter((c) => /size/.test(c))) expect(css, `no rule for .${cls}`).toContain(`.${cls}`);
    // and one copy: rehype-katex must not carry a nested katex of its own
    const nested = JSON.parse(readFileSync("package-lock.json", "utf8")).packages["node_modules/rehype-katex/node_modules/katex"];
    expect(nested).toBeUndefined();
  });
});
