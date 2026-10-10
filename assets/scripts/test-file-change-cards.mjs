// Actual file-change cards inside assistant-ui's real scrolling/follow viewport.
// The model and file edits are fixtures; no server data is changed.
import assert from "node:assert/strict";
import { build } from "esbuild";
import { chromium, webkit } from "playwright";
import { mkdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const bundle = await build({
  absWorkingDir: root,
  stdin: {
    resolveDir: root, loader: "tsx", contents: `
      import React from "react";
      import {createRoot} from "react-dom/client";
      import {AssistantRuntimeProvider, MessagePrimitive, useLocalRuntime} from "@assistant-ui/react";
      import {Thread} from "./js/ui/components/assistant-ui/elements/thread.aui";
      import {FileChangeTool, CommandExecutionTool} from "./js/ui/chat/toolkit";
      import {ToolGroupRoot, ToolGroupContent} from "./js/ui/components/assistant-ui/elements/tool-group.aui";
      import i18n from "./js/core/i18n";
      void i18n.changeLanguage("zh-CN");
      const part={type:"tool-call",argsText:"",status:{type:"complete"},
        addResult:()=>{},resume:()=>{},respondToApproval:async()=>{}};
      const lines=Array.from({length:110},(_,i)=>"+const change"+i+" = "+i+";");
      const changes=[{path:"lib/longx/agent/history.ex",kind:{type:"update"},
        diff:"@@ -1 +1,110 @@\\n-old\\n"+lines.join("\\n")},
        {path:"README.md",kind:{type:"update"},diff:"@@ -1 +1 @@\\n-before\\n+after"}];
      const components={AssistantMessage:()=> <MessagePrimitive.Root>
        <div style={{height:500}}>Earlier conversation</div>
        <ToolGroupRoot defaultOpen variant="ghost"><ToolGroupContent>
        <FileChangeTool {...part} toolCallId="files" toolName="fileChange"
          args={{changes}} result={{status:"completed",output:""}} />
        <div style={{height:100}}>Following conversation</div>
        <FileChangeTool {...part} toolCallId="next" toolName="fileChange"
          args={{changes:changes.slice(1)}} result={{status:"completed",output:""}} />
        <CommandExecutionTool {...part} toolCallId="command" toolName="commandExecution"
          args={{command:"mix test"}} result={{status:"completed",exitCode:0,output:"passed"}} />
        </ToolGroupContent></ToolGroupRoot>
        <div style={{height:700}}>More conversation</div>
      </MessagePrimitive.Root>};
      function App(){
        const runtime=useLocalRuntime({async *run(){}},{initialMessages:[
          {role:"assistant",content:[{type:"text",text:"Changes ready"}]}
        ]});
        return <AssistantRuntimeProvider runtime={runtime}>
          <div style={{height:"100dvh",maxWidth:780,margin:"auto"}}>
            <Thread components={components} autoFocus={false}/>
          </div>
        </AssistantRuntimeProvider>;
      }
      createRoot(document.getElementById("root")).render(<App/>);
    `,
  },
  bundle: true, write: false, format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false", "import.meta.env.MODE": '"browser-test"' },
  plugins: [{ name: "css", setup(builder) {
    builder.onLoad({ filter: /\.css$/ }, () => ({ contents: "", loader: "js" }));
  } }],
});
const manifest = JSON.parse(await readFile(path.join(root, "../priv/static/assets/.vite/manifest.json"), "utf8"));
const css = await readFile(path.join(root, "../priv/static/assets", manifest["js/index.tsx"].css[0]), "utf8");
const artifacts = path.join(root, "../.longx/local/artifacts/file-change-cards");
await mkdir(artifacts, { recursive: true });
const browser = await (process.argv.includes("--webkit") ? webkit : chromium).launch();
const settle = page => page.evaluate(() => new Promise(resolve => {
  let frames = 0;
  function next() { if (++frames >= 16) resolve(); else requestAnimationFrame(next); }
  requestAnimationFrame(next);
}));
try {
  for (const width of [1280, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 800 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.route("http://file-changes.test/**", route => route.fulfill({
      contentType: "text/html", body: '<div id="root"></div>',
    }));
    await page.goto("http://file-changes.test/");
    await page.addStyleTag({ content: css });
    // Remove decorative reveal delays, not disclosure or scroll behaviour.
    await page.addStyleTag({ content: '[data-slot="code-diff"] .animate-in {animation:none!important}' });
    await page.addScriptTag({ content: bundle.outputFiles[0].text });
    const card = page.getByTestId("tool-file-change").first();
    const header = card.locator('[data-slot="collapsible-trigger"]').first();
    await header.waitFor();
    await settle(page);
    await header.click();
    await card.getByText("const change109 = 109;", { exact: true }).waitFor();
    const scrollTo = async delta => {
      await header.evaluate((element, distance) => {
        const viewport = element.closest('[data-slot="aui_thread-viewport"]');
        const root = element.closest('[data-slot="tool-call"]');
        viewport.scrollTop += root.getBoundingClientRect().top - viewport.getBoundingClientRect().top + distance;
      }, delta);
      await settle(page);
    };
    const geometry = () => header.evaluate(element => {
      const viewport = element.closest('[data-slot="aui_thread-viewport"]');
      const rect = element.getBoundingClientRect();
      return { top: rect.top - viewport.getBoundingClientRect().top,
        bottom: rect.bottom - viewport.getBoundingClientRect().top,
        viewportHeight: viewport.clientHeight, scrollTop: viewport.scrollTop };
    });
    await scrollTo(600);
    assert.ok(Math.abs((await geometry()).top) <= 2, "only the active file header sticks to the viewport top");
    assert.equal(await header.getAttribute("aria-expanded"), "true");
    assert.deepEqual(await header.evaluate(element => {
      const style = getComputedStyle(element);
      return [style.borderTopLeftRadius, style.borderTopRightRadius, style.borderBottomLeftRadius, style.borderBottomRightRadius];
    }), ["0px", "0px", "0px", "0px"], "expanded sticky headers have square corners");
    await page.screenshot({ path: path.join(artifacts, `middle-${width}.png`) });
    await header.click();
    await settle(page);
    assert.equal(await header.getAttribute("aria-expanded"), "false");
    assert.ok(Math.abs((await geometry()).top) <= 2, "top collapse preserves the title anchor after assistant-ui reflow");
    await page.screenshot({ path: path.join(artifacts, `collapsed-${width}.png`) });

    await header.click();
    const footer = card.getByRole("button", { name: "收起修改", exact: true });
    await footer.scrollIntoViewIfNeeded();
    await settle(page);
    const beforeFooter = await geometry();
    assert.ok(beforeFooter.top >= -2 && beforeFooter.bottom < beforeFooter.viewportHeight);
    await page.screenshot({ path: path.join(artifacts, `footer-${width}.png`) });
    await footer.click();
    await settle(page);
    assert.equal(await header.getAttribute("aria-expanded"), "false");
    assert.ok(Math.abs((await geometry()).top - beforeFooter.top) <= 2, "footer collapse preserves the title anchor");
    assert.equal(await header.evaluate(element => document.activeElement === element), true, "footer focus returns to the title");

    await header.click();
    await scrollTo(600);
    await page.evaluate(() => document.documentElement.dataset.theme = "dark");
    await page.screenshot({ path: path.join(artifacts, `dark-${width}.png`) });
    const nextHeader = page.getByTestId("tool-file-change").nth(1).locator('[data-slot="collapsible-trigger"]').first();
    await nextHeader.evaluate(element => {
      const viewport = element.closest('[data-slot="aui_thread-viewport"]');
      viewport.scrollTop += element.getBoundingClientRect().top - viewport.getBoundingClientRect().top;
    });
    await settle(page);
    assert.ok((await geometry()).top < 0, "an earlier card's header leaves with its own content");
    assert.equal(await nextHeader.getAttribute("aria-expanded"), "false", "another card's state is independent");
    assert.notEqual(await page.getByRole("button", { name: /运行了.*mix test/ }).evaluate(element => getComputedStyle(element).position), "sticky", "Shell disclosures remain unchanged");
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), "no page-level horizontal overflow");
    assert.ok(await card.evaluate(element => [...element.querySelectorAll('[data-slot="code-diff"] *')].every(node =>
      !["auto", "scroll"].includes(getComputedStyle(node).overflowY) || node.scrollHeight <= node.clientHeight + 1
    )), "diffs do not introduce another vertical scroll area");
    assert.deepEqual(errors, []);
    console.log(`File changes ${width}px: sticky scope, top/footer collapse, title anchor, focus, independent cards and dark mode passed`);
    await page.close();
  }
} finally { await browser.close(); }
