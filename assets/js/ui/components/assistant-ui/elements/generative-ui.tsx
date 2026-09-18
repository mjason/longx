"use client";

// assistant-ui's registry element `generative-ui` (r.assistant-ui.com/base/
// generative-ui.json), adapted: the vocabulary the model draws with
// (`present` / `prompt_user` — Longx.Agent.Plugs.Present) is the package's
// default library; only `Markdown` is replaced so a fenced block tokenises
// with shiki like the transcript's own markdown. The stylesheet is
// `css/generative-ui.css` on our tokens.
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import type { ComponentPropsWithoutRef } from "react";
import {
  defaultGenerativeUILibrary,
  renderGenerativeUI,
  type GenerativeUIDispatch,
  type GenerativeUILibrary,
  type GenerativeUIStatus,
} from "@assistant-ui/react-generative-ui";

import { SyntaxHighlighter } from "@/ui/components/assistant-ui/elements/shiki-highlighter.aui";

const markdownBase = defaultGenerativeUILibrary.Markdown!;

// a fenced block goes through shiki; inline code stays a <code>
export const markdownComponents: Components = {
  code: ({ className, children, ...rest }: ComponentPropsWithoutRef<"code">) => {
    const language = /language-(\w+)/.exec(className ?? "")?.[1];
    const code = String(children ?? "").replace(/\n$/, "");
    if (!language && !code.includes("\n")) {
      return (
        <code className={className} {...rest}>
          {children}
        </code>
      );
    }
    return (
      <SyntaxHighlighter
        language={language ?? "text"}
        code={code}
        className="aui-generative-code"
      />
    );
  },
  pre: ({ children }) => <>{children}</>,
};

/** `MarkdownTextPrimitive` cannot be reused here: it reads from message-part context, not a prop string. */
export const styledGenerativeUILibrary: GenerativeUILibrary = {
  ...defaultGenerativeUILibrary,
  Markdown: {
    properties: markdownBase.properties,
    streamProperties: markdownBase.streamProperties,
    description: "A markdown string, rendered with GitHub-flavored markdown.",
    render: ({ value, children }) => (
      <div data-aui="markdown" className="aui-md">
        <ReactMarkdown remarkPlugins={[remarkGfm]} components={markdownComponents}>
          {value ?? ""}
        </ReactMarkdown>
        {children}
      </div>
    ),
  },
};

export type GenerativeTreeProps = {
  /** the model's `{ $type, ...props, children }` tree (a `present` call's arguments) */
  tree: unknown;
  status?: GenerativeUIStatus;
  /** what an interactive node fires (`$action` + `$input`); read-only without it */
  dispatch?: GenerativeUIDispatch;
  className?: string;
};

/** The surface a tree paints into — the package's own `data-aui="root"` rhythm. */
export function GenerativeTree({ tree, status = "done", dispatch, className }: GenerativeTreeProps) {
  return (
    <div data-aui="root" className={className}>
      {renderGenerativeUI(tree, styledGenerativeUILibrary, {
        status,
        ...(dispatch ? { dispatch } : {}),
      })}
    </div>
  );
}
