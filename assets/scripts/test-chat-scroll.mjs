// Real assistant-ui viewport, CSS-only reasoning-panel growth. No server/model.
// node scripts/test-chat-scroll.mjs [--webkit]
import assert from "node:assert/strict";
import { build } from "esbuild";
import { chromium, webkit } from "playwright";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const bundle = await build({
  stdin: {
    resolveDir: root,
    loader: "tsx",
    contents: `
      import React, { useEffect, useRef } from "react";
      import { createRoot } from "react-dom/client";
      import { AssistantRuntimeProvider, ThreadPrimitive, useLocalRuntime } from "@assistant-ui/react";
      import { observeThreadContentSize } from "./js/ui/chat/scroll";
      const adapter = { async *run() {} };
      function App() {
        const runtime = useLocalRuntime(adapter, { initialMessages: [
          { role: "user", content: [{ type: "text", text: "Think" }] }
        ] });
        const content = useRef(null);
        useEffect(() => {
          if (window.scrollSizeBridge) return observeThreadContentSize(content.current);
        }, []);
        return <AssistantRuntimeProvider runtime={runtime}>
          <ThreadPrimitive.Root>
            <ThreadPrimitive.Viewport autoScroll data-testid="viewport"
              style={{ height: 400, overflowY: "scroll", overflowAnchor: "none" }}>
              <div ref={content}>
                <div style={{ height: 700 }}>Earlier messages</div>
                <div data-testid="thinking" style={{
                  height: "var(--thinking-height, 100px)", transition: "height 200ms linear"
                }}>Streaming thought</div>
                <ThreadPrimitive.ViewportFooter style={{ height: 60 }}>
                  <ThreadPrimitive.ScrollToBottom data-testid="bottom">Bottom</ThreadPrimitive.ScrollToBottom>
                </ThreadPrimitive.ViewportFooter>
              </div>
            </ThreadPrimitive.Viewport>
          </ThreadPrimitive.Root>
        </AssistantRuntimeProvider>;
      }
      createRoot(document.getElementById("root")).render(<App />);
    `,
  },
  bundle: true,
  write: false,
  format: "iife",
  define: { "process.env.NODE_ENV": '"production"' },
});
const browser = await (process.argv.includes("--webkit") ? webkit : chromium).launch();
try {
  for (const bridge of [false, true]) {
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.setContent('<div id="root"></div>');
    await page.evaluate((enabled) => { window.scrollSizeBridge = enabled; }, bridge);
    await page.addScriptTag({ content: bundle.outputFiles[0].text });
    const gap = () => page.evaluate(() => {
      const el = document.querySelector('[data-testid="viewport"]');
      return el.scrollHeight - el.scrollTop - el.clientHeight;
    });
    await page.waitForFunction(() => {
      const el = document.querySelector('[data-testid="viewport"]');
      return el && el.scrollHeight - el.scrollTop - el.clientHeight <= 1;
    });
    const grow = async (height) => {
      await page.locator('[data-testid="thinking"]').evaluate((el, value) =>
        el.style.setProperty("--thinking-height", `${value}px`), height);
      await page.waitForFunction((value) =>
        document.querySelector('[data-testid="thinking"]').clientHeight === value, height);
      await page.evaluate(() => new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve))));
    };
    await grow(700);
    if (!bridge) {
      assert.ok(await gap() > 100, "baseline should reproduce lost follow on CSS-only growth");
    } else {
      assert.ok(await gap() <= 1, "content resize should follow the thinking panel");
      await page.locator('[data-testid="viewport"]').hover();
      await page.mouse.wheel(0, -250);
      await page.waitForFunction(() => {
        const el = document.querySelector('[data-testid="viewport"]');
        return el.scrollHeight - el.scrollTop - el.clientHeight > 150;
      });
      const readingAt = await page.locator('[data-testid="viewport"]').evaluate((el) => el.scrollTop);
      await grow(1000);
      assert.ok(Math.abs(await page.locator('[data-testid="viewport"]').evaluate((el) => el.scrollTop) - readingAt) <= 1,
        "growth must not pull a reader who scrolled up back to the tail");
      // The scroll button lives in the footer; dispatch its click without
      // scrolling it into view (that would change the state under test).
      await page.locator('[data-testid="bottom"]').evaluate((el) => el.click());
      await page.waitForFunction(() => {
        const el = document.querySelector('[data-testid="viewport"]');
        return el.scrollHeight - el.scrollTop - el.clientHeight <= 1;
      });
      await grow(1200);
      assert.ok(await gap() <= 1, "bottom button must resume following");
    }
    assert.deepEqual(errors, []);
    console.log(bridge ? "fixed: follow, reading position, and resume passed" : "baseline: lost-follow reproduced");
    await page.close();
  }
} finally {
  await browser.close();
}
