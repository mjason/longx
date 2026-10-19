// Real code-block copy in our Thread, on an insecure HTTP origin.
// Assert actual clipboard contents and nested scroll positions together.
import assert from "node:assert/strict";
import http from "node:http";
import { build } from "esbuild";
import { chromium } from "playwright";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const copied = "printf 'copy-scroll-regression\\n'\n";
const bundle = await build({
  absWorkingDir: root,
  stdin: { resolveDir: root, loader: "tsx", contents: `
    import React from "react";
    import {createRoot} from "react-dom/client";
    import {AssistantRuntimeProvider,useLocalRuntime} from "@assistant-ui/react";
    import {Thread} from "./js/ui/components/assistant-ui/elements/thread.aui";
    import {installClipboardFallback} from "./js/ui/lib/clipboard";
    import i18n from "./js/core/i18n";
    void i18n.changeLanguage("zh-CN");
    installClipboardFallback();
    const code=${JSON.stringify(copied)};
    const paragraphs=Array.from({length:30},(_,i)=>"Paragraph "+i+" — long conversation content.").join("\\n\\n");
    const text=paragraphs+"\\n\\n"+String.fromCharCode(96).repeat(3)+"sh\\n"+code+String.fromCharCode(96).repeat(3)+"\\n\\n"+paragraphs;
    function App(){
      const runtime=useLocalRuntime({async *run(){}},{initialMessages:[
        {role:"assistant",content:[{type:"text",text}]}
      ]});
      return <AssistantRuntimeProvider runtime={runtime}>
        <div style={{height:350}}>Page before chat</div>
        <div data-testid="outer" style={{height:650,overflow:"auto",transform:window.location.search.includes("transform")?"translateZ(0)":undefined}}>
          <div style={{height:300}}>Outer before chat</div>
          <div style={{height:480}}><Thread autoFocus={false}/></div>
          <div style={{height:500}}>Outer after chat</div>
        </div>
        <div style={{height:1000}}>Page after chat</div>
      </AssistantRuntimeProvider>;
    }
    createRoot(document.getElementById("root")).render(<App/>);
  ` },
  bundle: true, write: false, format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false", "import.meta.env.MODE": '"browser-test"' },
  plugins: [{ name: "css", setup(builder) {
    builder.onLoad({filter:/\.css$/},()=>({contents:"",loader:"js"}));
  }}],
});
const manifest = JSON.parse(await readFile(path.join(root, "../priv/static/assets/.vite/manifest.json"), "utf8"));
const css = await readFile(path.join(root, "../priv/static/assets", manifest["js/index.tsx"].css[0]), "utf8");
const server = http.createServer((req, res) => {
  res.setHeader("content-type", "text/html");
  res.end(req.url.startsWith("/reader") ? "<p>Clipboard reader</p>" :
    `<style>${css}</style><div id="root"></div><script>${bundle.outputFiles[0].text}</script>`);
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await chromium.launch({ args: ["--host-resolver-rules=MAP copy-scroll.test 127.0.0.1", "--no-proxy-server"] });
try {
  for (const width of [1280, 390]) for (const transformed of [false, true]) for (const retainedInputFocus of [false, true]) {
    const context = await browser.newContext({viewport:{width,height:900}});
    const origin = `http://localhost:${server.address().port}`;
    await context.grantPermissions(["clipboard-read"], {origin});
    const reader = await context.newPage();
    await reader.goto(origin + "/reader");
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`http://copy-scroll.test:${server.address().port}/${transformed ? "?transform" : ""}`);
    assert.equal(await page.evaluate(() => isSecureContext), false);
    const copy = page.locator(".aui-code-header-root").getByRole("button", {name:"Copy",exact:true});
    await copy.waitFor();
    // Let the thread's initialization and lazy highlighting settle first.
    await page.waitForTimeout(350);
    if (retainedInputFocus) await page.evaluate(() => {
      // WebKit-style mouse activation, or a caller retaining composer focus:
      // clicking a button need not make that button the active element.
      document.querySelector("textarea")?.focus({preventScroll:true});
      document.addEventListener("mousedown", event => {
        if (event.target.closest?.(".aui-code-header-root button")) event.preventDefault();
      }, true);
    });
    await page.evaluate(() => {
      window.scrollTo(0, 250);
      document.querySelector('[data-testid="outer"]').scrollTop=300;
      document.querySelector(".aui-code-header-root").scrollIntoView({block:"center",inline:"nearest"});
    });
    await page.waitForTimeout(100);
    const positions = () => page.evaluate(() => ({
      page: [scrollX,scrollY],
      outer: [...document.querySelectorAll('[data-testid="outer"],[data-slot="aui_thread-viewport"]')].map(el=>[el.scrollLeft,el.scrollTop])
    }));
    const before = await positions();
    await copy.click();
    await page.waitForTimeout(150);
    assert.equal(await reader.evaluate(() => navigator.clipboard.readText()), copied);
    const after = await positions();
    console.log(JSON.stringify({width,transformed,retainedInputFocus,before,after}));
    assert.deepEqual(after, before, `copy must not scroll ${width}px transformed=${transformed} retainedInputFocus=${retainedInputFocus}`);
    assert.equal(await page.locator("textarea[readonly]").count(), 0);
    assert.deepEqual(errors, []);
    await context.close();
  }
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
