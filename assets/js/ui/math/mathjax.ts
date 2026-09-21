// MathJax 4 as the formula renderer, in the browser, with the Fira Math font
// (sans-serif: the one that sits with the UI's type; STIX Two and Latin
// Modern are the same packages' siblings — `@mathjax/mathjax-stix2-font`,
// `@mathjax/mathjax-modern-font` — swap MATH_FONT and the imports). The
// TeX goes in as a string and SVG comes out as HTML through MathJax's own
// DOM-less adaptor, so the same module renders in vitest. KaTeX rendered
// Computer Modern only, whose italic serif fought the page.
//
// The font's glyphs beyond the core set (double-struck, fraktur, script,
// cyrillic…) are files MathJax asks for on demand; every one is loaded once
// at init through Vite's glob import, so rendering itself stays synchronous
// — react-markdown runs its rehype plugins synchronously.
import { mathjax } from "@mathjax/src/js/mathjax.js";
import { TeX } from "@mathjax/src/js/input/tex.js";
import { SVG } from "@mathjax/src/js/output/svg.js";
import { liteAdaptor } from "@mathjax/src/js/adaptors/liteAdaptor.js";
import { RegisterHTMLHandler } from "@mathjax/src/js/handlers/html.js";
import "@mathjax/src/js/input/tex/base/BaseConfiguration.js";
import "@mathjax/src/js/input/tex/ams/AmsConfiguration.js";
import "@mathjax/src/js/input/tex/newcommand/NewcommandConfiguration.js";
import "@mathjax/src/js/input/tex/noundefined/NoUndefinedConfiguration.js";
import "@mathjax/src/js/input/tex/boldsymbol/BoldsymbolConfiguration.js";
import "@mathjax/src/js/input/tex/textmacros/TextMacrosConfiguration.js";
import "@mathjax/src/js/input/tex/color/ColorConfiguration.js";
import "@mathjax/src/js/input/tex/cancel/CancelConfiguration.js";
import "@mathjax/src/js/input/tex/mathtools/MathtoolsConfiguration.js";
import { MathJaxFiraFont as MATH_FONT } from "@mathjax/mathjax-fira-font/js/svg.js";

const dynamicRanges = import.meta.glob("/node_modules/@mathjax/mathjax-fira-font/mjs/svg/dynamic/*.js");

// MathJax names a range by the font package's path; the glob is keyed by file
mathjax.asyncLoad = (file: string) => {
  const name = file.split("/").pop()!;
  const load = Object.entries(dynamicRanges).find(([path]) => path.endsWith("/" + name))?.[1];
  return load ? load() : Promise.reject(new Error(`no such font range: ${file}`));
};

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);

const packages = ["base", "ams", "newcommand", "noundefined", "boldsymbol", "textmacros", "color", "cancel", "mathtools"];
// no automatic line-breaking: the adaptor knows no column width, and a
// broken inline formula came back as two SVGs; a wide display formula
// scrolls inside its container (css: mjx-container[display])
const output = new SVG({ fontData: MATH_FONT, fontCache: "none", linebreaks: { inline: false }, displayOverflow: "scroll" });
const document = mathjax.document("", { InputJax: new TeX({ packages }), OutputJax: output });

/** every glyph range in memory: after this, `render` never needs to wait */
export const ready: Promise<void> = (output.font as unknown as { loadDynamicFiles(): Promise<unknown> })
  .loadDynamicFiles()
  .then(() => undefined);

/** the formula as an `<mjx-container>` with its SVG inside; a TeX error as MathJax draws it */
export function render(tex: string, display: boolean): string {
  return adaptor.outerHTML(document.convert(tex, { display }));
}
