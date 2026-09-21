// A rehype plugin over MathJax 4: remark-math's `code.math-inline` and
// `pre > code.math-display` become the SVG `mjx-container` MathJax draws
// (the shape rehype-katex takes, with KaTeX's HTML swapped for MathJax's).
import type { Element, ElementContent, Parent, Root } from "hast";
import { fromHtmlIsomorphic } from "hast-util-from-html-isomorphic";
import { toText } from "hast-util-to-text";
import { SKIP, visit } from "unist-util-visit";
import { render } from "./mathjax";

export function rehypeMathjax() {
  return (tree: Root) => {
    visit(tree, "element", (node: Element, index, parent) => {
      const classes = (node.properties?.className as string[] | undefined) ?? [];
      const inline = classes.includes("math-inline");
      const display = classes.includes("math-display");
      if (!(inline || display) || index === undefined || !parent) return;

      const tex = toText(node, { whitespace: "pre" });
      const html = render(tex, display);
      const fragment = fromHtmlIsomorphic(html, { fragment: true });
      const replacement = fragment.children as ElementContent[];

      // a display formula's `<pre>` goes with it
      const target = display && (parent as Element).tagName === "pre" ? parent : node;
      const holder = (display && (parent as Element).tagName === "pre" ? findParent(tree, parent as Element) : parent) as Parent | undefined;
      if (!holder) return;
      const at = holder.children.indexOf(target as ElementContent);
      if (at === -1) return;
      holder.children.splice(at, 1, ...replacement);
      return SKIP;
    });
  };
}

function findParent(tree: Root, child: Element): Parent | undefined {
  let found: Parent | undefined;
  visit(tree, (node) => {
    if ("children" in node && (node as Parent).children.includes(child as ElementContent)) {
      found = node as Parent;
      return false;
    }
    return undefined;
  });
  return found;
}
