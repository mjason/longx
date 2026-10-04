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
      // wheel() returns before scrolling finishes. WebKit can apply its delta
      // over multiple frames; crossing the gap threshold isn't a settled reading
      // position. Keep sampling geometry instead of racing that input with growth.
      await page.evaluate(() => new Promise((resolve, reject) => {
        const el = document.querySelector('[data-testid="viewport"]');
        let previous = el.scrollTop;
        let stableFrames = 0;
        const started = performance.now();
        function sample() {
          const current = el.scrollTop;
          stableFrames = current === previous ? stableFrames + 1 : 0;
          previous = current;
          if (stableFrames >= 12) return resolve();
          if (performance.now() - started > 5000) return reject(new Error("wheel scroll did not settle"));
          requestAnimationFrame(sample);
        }
        requestAnimationFrame(sample);
      }));
      const readingAt = await page.locator('[data-testid="viewport"]').evaluate((el) => el.scrollTop);
      await grow(1000);
      const afterGrowth = await page.locator('[data-testid="viewport"]').evaluate((el) => el.scrollTop);
      assert.ok(Math.abs(afterGrowth - readingAt) <= 1,
        `growth must preserve reading position: before=${readingAt}, after=${afterGrowth}, gap=${await gap()}`);
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

  // The actual Thread element, reopening an old reading position. Its
  // restored-read mode must still hand tail-follow back to assistant-ui.
  const restoredBundle = await build({
    absWorkingDir: root,
    stdin: {
      resolveDir: root,
      loader: "tsx",
      contents: `
        import React from "react";
        import { createRoot } from "react-dom/client";
        import { AssistantRuntimeProvider, MessagePrimitive, useLocalRuntime } from "@assistant-ui/react";
        import { Thread } from "./js/ui/components/assistant-ui/elements/thread.aui";
        import { rememberScroll } from "./js/core/workspaceMemory";
        import i18n from "./js/core/i18n";
        void i18n.changeLanguage("zh-CN");
        rememberScroll("read", {scrollTop:200,scrollHeight:2000,clientHeight:400});
        const components = { AssistantMessage: () => <MessagePrimitive.Root>
          <div data-testid="thinking" style={{height:"var(--thinking-height, 900px)"}}>Thought</div>
        </MessagePrimitive.Root> };
        function App() {
          const runtime=useLocalRuntime({async *run(){}}, {initialMessages:[
            {role:"assistant",content:[{type:"text",text:"Thought"}]}
          ]});
          return <AssistantRuntimeProvider runtime={runtime}>
            <Thread components={components} memoryKey="read" autoFocus={false}/>
          </AssistantRuntimeProvider>;
        }
        createRoot(document.getElementById("root")).render(<App/>);
      `,
    },
    bundle: true,
    write: false,
    format: "iife",
    define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false" },
    plugins: [{
      name: "geometry-only-css",
      setup(builder) {
        builder.onLoad({ filter: /\.css$/ }, () => ({ contents: "", loader: "js" }));
      },
    }],
  });
  const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.setContent(`<style>
    #root {height:400px;width:800px}
    .aui-thread-root {height:100%;display:flex;flex-direction:column}
    [data-slot="aui_thread-viewport"] {flex:1;min-height:0;overflow-y:auto}
  </style><div id="root"></div>`);
  await page.addScriptTag({ content: restoredBundle.outputFiles[0].text });
  const viewport = page.locator('[data-slot="aui_thread-viewport"]');
  await page.waitForFunction(() => document.querySelector('[data-slot="aui_thread-viewport"]')?.scrollTop === 200);
  // Wait past the opening layout settlement before growing the content.
  await page.evaluate(() => new Promise(resolve => {
    let frames = 0;
    const tick = () => ++frames >= 16 ? resolve() : requestAnimationFrame(tick);
    requestAnimationFrame(tick);
  }));
  const grow = async height => {
    await page.getByTestId("thinking").evaluate((el, value) => el.style.setProperty("--thinking-height", `${value}px`), height);
    await page.waitForFunction(value => document.querySelector('[data-testid="thinking"]').clientHeight === value, height);
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  };
  await grow(1400);
  assert.equal(await viewport.evaluate(el => el.scrollTop), 200, "restored reading must not follow new content");
  await page.locator(".aui-thread-scroll-to-bottom").evaluate(el => el.click());
  await page.waitForFunction(() => {
    const el = document.querySelector('[data-slot="aui_thread-viewport"]');
    return el.scrollHeight - el.clientHeight - el.scrollTop <= 1;
  });
  await grow(2100);
  assert.ok(await viewport.evaluate(el => el.scrollHeight - el.clientHeight - el.scrollTop <= 1), "the bottom button must resume following after a restored read");
  assert.deepEqual(errors, []);
  console.log("restored conversation: reading position and resume-follow passed");
  await page.close();
} finally {
  await browser.close();
}
