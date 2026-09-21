import "../css/app.css";
// KaTeX's stylesheet: formulas in chat replies and markdown files
import "katex/dist/katex.min.css";
import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./ui/App";
import { installClipboardFallback } from "./ui/lib/clipboard";

// over plain http on the LAN the browser gives no Clipboard API: the copy buttons need this
installClipboardFallback();

createRoot(document.getElementById("app")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
