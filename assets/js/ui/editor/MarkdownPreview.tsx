// A markdown file as the reader sees it — the workbench opens .md files
// rendered (a README, a report the agent wrote) and only switches to the
// editor on request. The same look as the chat's markdown: the element's
// classes, fenced code through shiki (the generative-ui renderer's `code`).
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import { useMath } from "@/ui/math/useMath";
import { preprocessMath } from "@/core/chat/math";
import { markdownComponents } from "@/ui/components/assistant-ui/elements/generative-ui";

const components: Components = {
  ...markdownComponents,
  h1: (p) => <h1 className="aui-md-h1 mt-5 mb-2 scroll-m-20 text-xl font-semibold first:mt-0 last:mb-0" {...p} />,
  h2: (p) => <h2 className="aui-md-h2 mt-5 mb-2 scroll-m-20 text-lg font-semibold first:mt-0 last:mb-0" {...p} />,
  h3: (p) => <h3 className="aui-md-h3 mt-4 mb-1.5 scroll-m-20 text-base font-semibold first:mt-0 last:mb-0" {...p} />,
  h4: (p) => <h4 className="aui-md-h4 mt-3.5 mb-1 scroll-m-20 text-base font-medium first:mt-0 last:mb-0" {...p} />,
  h5: (p) => <h5 className="aui-md-h5 mt-3 mb-1 text-sm font-semibold first:mt-0 last:mb-0" {...p} />,
  h6: (p) => <h6 className="aui-md-h6 mt-3 mb-1 text-sm font-medium first:mt-0 last:mb-0" {...p} />,
  p: (p) => <p className="aui-md-p my-3 leading-relaxed first:mt-0 last:mb-0" {...p} />,
  a: (p) => <a className="aui-md-a text-primary hover:text-primary/80 underline underline-offset-2" target="_blank" rel="noopener noreferrer" {...p} />,
  blockquote: (p) => <blockquote className="aui-md-blockquote border-muted-foreground/30 text-muted-foreground my-3 border-s-2 ps-4" {...p} />,
  ul: (p) => <ul className="aui-md-ul marker:text-muted-foreground my-3 ms-5 list-disc [&>li]:mt-1" {...p} />,
  ol: (p) => <ol className="aui-md-ol marker:text-muted-foreground my-3 ms-5 list-decimal [&>li]:mt-1" {...p} />,
  li: (p) => <li className="aui-md-li leading-relaxed" {...p} />,
  hr: (p) => <hr className="aui-md-hr border-muted-foreground/20 my-3" {...p} />,
  strong: (p) => <strong className="aui-md-strong font-semibold" {...p} />,
  table: (p) => (
    <div className="aui-md-table-wrapper my-3 overflow-x-auto">
      <table className="aui-md-table w-full border-separate border-spacing-0" {...p} />
    </div>
  ),
  th: (p) => <th className="aui-md-th bg-muted px-3 py-1.5 text-start font-medium first:rounded-ss-lg last:rounded-se-lg" {...p} />,
  td: (p) => <td className="aui-md-td border-muted-foreground/20 border-s border-b px-3 py-1.5 text-start last:border-e" {...p} />,
  tr: (p) => <tr className="aui-md-tr m-0 border-b p-0 first:border-t" {...p} />,
  img: (p) => <img className="aui-md-img my-3 max-w-full rounded-lg" loading="lazy" {...p} />,
};

export function MarkdownPreview({ source, className }: { source: string; className?: string }) {
  const mathPlugins = useMath();
  return (
    <div className={`text-foreground mx-auto w-full max-w-3xl px-6 py-5 text-[15px] leading-relaxed wrap-break-word ${className ?? ""}`} data-testid="markdown-preview">
      <ReactMarkdown remarkPlugins={[remarkGfm, remarkMath]} rehypePlugins={mathPlugins} components={components}>
        {preprocessMath(source)}
      </ReactMarkdown>
    </div>
  );
}

export const isMarkdownPath = (path: string) => /\.(md|markdown|mdx)$/i.test(path);
