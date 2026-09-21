import { describe, expect, test } from "vitest";
import { preprocessMath, wrapIdentifiers } from "./math";

describe("wrapIdentifiers", () => {
  test("a bare multi-letter name in math is a name, not a product: \\mathrm around it; single letters stay variables", () => {
    expect(wrapIdentifiers("AucRatioOpen_{T-1} = \\frac{OpenAuctionVolume_{T-1}}{TotalVolume_{T-1}}")).toBe(
      "\\mathrm{AucRatioOpen}_{T-1} = \\frac{\\mathrm{OpenAuctionVolume}_{T-1}}{\\mathrm{TotalVolume}_{T-1}}",
    );
    expect(wrapIdentifiers("S = \\frac{R_p - R_f}{\\sigma_p}")).toBe("S = \\frac{R_p - R_f}{\\sigma_p}");
    // two capitals are an acronym (IC, IR, BR); two lowercase letters a product (xy, dx)
    expect(wrapIdentifiers("IR \\approx IC \\cdot \\sqrt{BR}, xy + dx")).toBe("\\mathrm{IR} \\approx \\mathrm{IC} \\cdot \\sqrt{\\mathrm{BR}}, xy + dx");
  });

  test("macros and their text arguments are left alone: \\text, \\mathrm, \\operatorname, \\begin{aligned}, \\label", () => {
    const src = "\\text{Corr}(f_t) = \\mathrm{Cov} \\operatorname{argmax}_x \\begin{aligned} a &= \\alpha \\\\ b &= \\beta \\end{aligned} \\label{eq:sharpe}";
    expect(wrapIdentifiers(src)).toBe(src);
    // \mathbb{E}, \hat{Var}: the argument of a font macro is a name too when it is a word
    expect(wrapIdentifiers("\\mathbb{E}[R] + \\hat{Var}")).toBe("\\mathbb{E}[R] + \\hat{\\mathrm{Var}}");
  });
});

describe("preprocessMath", () => {
  test("only math is touched: prose, code spans and fences keep their words; the delimiters models emit are normalised first", () => {
    const src = "Volume 很大。`$abc$` 和\n\n```\n$TotalVolume$\n```\n\n行内 \\(TotalVolume_t\\) 与 $x$；\n\n\\[ IC = \\rho(f, r) \\]";
    expect(preprocessMath(src)).toBe(
      "Volume 很大。`$abc$` 和\n\n```\n$TotalVolume$\n```\n\n行内 $\\mathrm{TotalVolume}_t$ 与 $x$；\n\n$$\n\\mathrm{IC} = \\rho(f, r)\n$$",
    );
  });

  test("a price is not math, a one-line $$…$$ becomes a block", () => {
    expect(preprocessMath("费用 $5 到 $7。\n\n$$E = mc^2$$")).toBe("费用 \\$5 到 \\$7。\n\n$$\nE = mc^2\n$$");
  });
});
