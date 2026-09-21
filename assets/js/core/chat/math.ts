// What a model's LaTeX goes through before remark-math reads it — DOM-free,
// shared by the chat's MarkdownText and the file preview.
import { escapeCurrencyDollars, normalizeMathDelimiters } from "@assistant-ui/react-markdown";

/**
 * assistant-ui's LaTeX guide plus two rules of ours: `\(…\)` / `\[…\]` → `$…$` /
 * `$$…$$` (models emit those), a one-line `$$…$$` spread onto its own lines
 * (remark-math reads the one-line form as inline math), a bare multi-letter
 * name inside math wrapped in `\mathrm{}`, and a price kept out of math.
 */
export function preprocessMath(text: string): string {
  return holdOpenBlockMath(
    escapeCurrencyDollars(mapMath(blockMathOnItsOwnLines(normalizeMathDelimiters(text)), wrapIdentifiers)),
  );
}

/**
 * A display block whose closing `$$` has not arrived yet — the text is the
 * streamed prefix (assistant-ui's `preprocess` runs on what `useSmooth` has
 * revealed) — is held back whole: remark-math reads an unclosed fence to the
 * end of the text, and KaTeX drew each half-written line as an error, then
 * again as the formula, a flicker a character at a time. The block shows
 * once it is closed. A `$$` line inside a code fence is code.
 */
export function holdOpenBlockMath(text: string): string {
  const lines = text.split("\n");
  let inCode = false;
  let open: number | null = null;
  // a line with an odd number of `$$` opens or closes a block (`$$` alone,
  // `$$ x = …` opening with content, `… $$` closing at a line's end);
  // an even count (`$$x$$` inline) leaves the state alone
  lines.forEach((line, i) => {
    const t = line.trim();
    if (/^(```|~~~)/.test(t)) inCode = !inCode;
    else if (!inCode && (t.match(/\$\$/g)?.length ?? 0) % 2 === 1) open = open === null ? i : null;
  });
  return open === null ? text : lines.slice(0, open).join("\n");
}

// a line that is nothing but `$$…$$`: its fences on lines of their own
const blockMathOnItsOwnLines = (text: string) => text.replace(/^[ \t]*\$\$(?!\$)([^\n]+?)\$\$[ \t]*$/gm, "$$$$\n$1\n$$$$");

/**
 * TeX reads `TotalVolume` as ten variables multiplied — every letter italic
 * with math spacing between them, "T otalV olume" on the page — where a
 * quant's note means one name. A run of three letters or more, or two
 * capitals (an acronym: IC, IR, BR), not preceded by a backslash, becomes
 * `\mathrm{…}`; single letters and lowercase pairs (`xy`, `dx`) stay what
 * they are. A macro keeps its name and, for the text-like ones (`\text`,
 * `\mathrm`, `\operatorname`, `\begin`, `\label`, …), its braced argument.
 */
export function wrapIdentifiers(tex: string): string {
  let out = "";
  let i = 0;
  while (i < tex.length) {
    const ch = tex[i]!;
    if (ch === "\\") {
      const m = /^\\([A-Za-z]+|.)/.exec(tex.slice(i));
      const macro = m ? m[0] : "\\";
      out += macro;
      i += macro.length;
      if (VERBATIM.has(macro)) {
        // the braced arguments, copied as they are (`\begin{aligned}`, `\text{Corr}`)
        let n = 0;
        while (n < 2) {
          const rest = tex.slice(i);
          const ws = /^\s*/.exec(rest)![0];
          if (rest[ws.length] !== "{") break;
          const end = closingBrace(tex, i + ws.length);
          out += tex.slice(i, end + 1);
          i = end + 1;
          n++;
          if (macro !== "\\begin" && macro !== "\\end") break;
        }
      }
      continue;
    }
    const word = /^[A-Za-z]+/.exec(tex.slice(i));
    if (word) {
      const w = word[0];
      out += w.length >= 3 || (w.length === 2 && w === w.toUpperCase()) ? `\\mathrm{${w}}` : w;
      i += w.length;
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

const VERBATIM = new Set([
  "\\text", "\\textrm", "\\textit", "\\textbf", "\\textsf", "\\texttt", "\\mbox",
  "\\mathrm", "\\mathit", "\\mathbf", "\\mathsf", "\\mathtt", "\\mathcal", "\\mathfrak", "\\mathscr", "\\boldsymbol",
  "\\operatorname", "\\operatorname*", "\\DeclareMathOperator",
  "\\begin", "\\end", "\\label", "\\ref", "\\eqref", "\\tag", "\\color", "\\textcolor", "\\href", "\\url", "\\verb",
]);

function closingBrace(tex: string, open: number): number {
  let depth = 0;
  for (let j = open; j < tex.length; j++) {
    const c = tex[j];
    if (c === "\\") {
      j++;
      continue;
    }
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return j;
    }
  }
  return tex.length - 1;
}

/**
 * Applies `f` to the inside of every math span — `$…$` and `$$…$$` — outside
 * fenced code and code spans; everything else is copied as it is.
 */
export function mapMath(text: string, f: (tex: string) => string): string {
  let out = "";
  let i = 0;
  let fence: string | null = null;
  const atLineStart = () => i === 0 || text[i - 1] === "\n";
  while (i < text.length) {
    if (atLineStart()) {
      const m = /^[ \t]{0,3}(`{3,}|~{3,})/.exec(text.slice(i));
      if (m) {
        const marker = m[1]!;
        const eol = text.indexOf("\n", i);
        const line = eol === -1 ? text.slice(i) : text.slice(i, eol + 1);
        if (fence === null) fence = marker;
        else if (marker[0] === fence[0] && marker.length >= fence.length) fence = null;
        out += line;
        i += line.length;
        continue;
      }
    }
    if (fence !== null) {
      const eol = text.indexOf("\n", i);
      const line = eol === -1 ? text.slice(i) : text.slice(i, eol + 1);
      out += line;
      i += line.length;
      continue;
    }
    const ch = text[i]!;
    if (ch === "`") {
      const run = /^`+/.exec(text.slice(i))![0];
      const close = text.indexOf(run, i + run.length);
      const span = close === -1 ? run : text.slice(i, close + run.length);
      out += span;
      i += span.length;
      continue;
    }
    if (ch === "\\" && text[i + 1] === "$") {
      out += "\\$";
      i += 2;
      continue;
    }
    if (ch === "$") {
      const display = text[i + 1] === "$";
      const open = display ? "$$" : "$";
      const close = text.indexOf(open, i + open.length);
      if (close === -1) {
        out += ch;
        i++;
        continue;
      }
      out += open + f(text.slice(i + open.length, close)) + open;
      i = close + open.length;
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}
