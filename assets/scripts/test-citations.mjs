// Real assistant-ui, our message adapter and Markdown renderer in Chromium.
// No running server, model request or stored conversation is changed.
import assert from "node:assert/strict";
import { build } from "esbuild";
import { chromium } from "playwright";
import { mkdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const bundle = await build({
  absWorkingDir: root,
  stdin: { resolveDir: root, loader: "tsx", contents: `
    import React from "react";
    import {createRoot} from "react-dom/client";
    import {AssistantRuntimeProvider,useLocalRuntime} from "@assistant-ui/react";
    import {Thread} from "./js/ui/components/assistant-ui/elements/thread.aui";
    import {toMessages} from "./js/core/chat/messages";
    import {emptyView} from "./js/core/chat/thread";
    import i18n from "./js/core/i18n";
    void i18n.changeLanguage("zh-CN");
    const marker="citeturn0search2";
    const url="https://example.com/polars";
    const resolved="官方文档支持这个结论。"+marker;
    const missing="查询侧可以复用 Polars，但仍需验证。"+marker;
    const code="代码示例：\\\`"+marker+"\\\`";
    const plain="普通的来源注释。";
    const item=(id,text,citations)=>({id,type:"agentMessage",turnId:id,text,citations});
    const annotation=(text)=>[{url,title:"Polars 官方文档",start_index:text.indexOf(marker),end_index:text.length}];
    const items=[
      item("resolved",resolved,annotation(resolved)),
      item("missing",missing,[]),
      item("code",code,[]),
      item("plain",plain,[{url,title:"Polars 官方文档",start_index:0,end_index:plain.length}]),
      item("unsafe",marker,[{url:"javascript:alert(1)",start_index:0,end_index:marker.length}]),
    ];
    const messages=toMessages({...emptyView("fixture"),items});
    function App(){
      const runtime=useLocalRuntime({async *run(){
        yield {content:[{type:"text",text:"流式引用ci"}]};
        await new Promise(resolve=>window.finishStream=resolve);
        const text="流式引用"+marker;
        const [answer]=toMessages({...emptyView("stream"),items:[item("answer",text,annotation(text))]});
        yield {content:answer.content};
      }},{initialMessages:messages});
      window.startStream=()=>runtime.thread.append({role:"user",content:[{type:"text",text:"stream"}]});
      window.original=()=>runtime.thread.getState().messages[0].content[0].text;
      return <AssistantRuntimeProvider runtime={runtime}><Thread autoFocus={false}/></AssistantRuntimeProvider>;
    }
    createRoot(document.getElementById("root")).render(<App/>);
  ` },
  bundle: true, write: false, format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false", "import.meta.env.MODE": '"browser-test"' },
  plugins: [{ name: "css", setup(builder) {
    builder.onLoad({ filter: /\.css$/ }, () => ({ contents: "", loader: "js" }));
  } }],
});
const manifest = JSON.parse(await readFile(path.join(root, "../priv/static/assets/.vite/manifest.json"), "utf8"));
const css = await readFile(path.join(root, "../priv/static/assets", manifest["js/index.tsx"].css[0]), "utf8");
const artifacts = path.join(root, "../.longx/local/artifacts/citations");
await mkdir(artifacts, { recursive: true });
const browser = await chromium.launch();
try {
  for (const width of [390, 1280]) {
    const page = await browser.newPage({ viewport: { width, height: 950 } });
    page.setDefaultTimeout(10_000);
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.route("http://citations.test/**", route => route.fulfill({ contentType: "text/html", body: '<div id="root"></div>' }));
    await page.goto("http://citations.test/");
    await page.addStyleTag({ content: css });
    await page.addScriptTag({ content: bundle.outputFiles[0].text });
    const markdown = page.locator(".aui-md");
    await page.getByTestId("message-source").first().waitFor();
    const links = page.locator('.aui-md a[href="https://example.com/polars"]');
    await page.waitForFunction(() => document.querySelectorAll('.aui-md a[href="https://example.com/polars"]').length === 2);
    assert.equal(await links.count(), 2, "private-marker and normal prose annotations both link");
    assert.equal(await page.getByTestId("message-source").count(), 2);
    assert.equal(await page.locator("[data-citation-unavailable]").count(), 2);
    assert.equal(await markdown.locator("code").innerText(), "citeturn0search2", "literal example stays intact");
    assert.equal(await page.locator('a[href^="javascript:"]').count(), 0);
    assert.equal(await page.evaluate(() => window.original()), "官方文档支持这个结论。citeturn0search2", "stored/runtime text not rewritten");
    await page.evaluate(() => window.startStream());
    await page.getByText("〔引用解析中〕").waitFor();
    const last = markdown.filter({ hasText: "流式引用" }).last();
    await last.scrollIntoViewIfNeeded();
    assert.equal(await last.textContent(), "流式引用〔引用解析中〕");
    await page.evaluate(() => window.finishStream());
    await last.getByRole("link", { name: "[1]" }).waitFor();
    assert.equal(await page.getByText("〔引用解析中〕").count(), 0);
    assert.equal(await page.getByTestId("message-source").count(), 3);
    await last.scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(artifacts, `citations-${width}.png`), fullPage: true });
    assert.deepEqual(errors, []);
    await page.close();
    console.log(`citations render/stream/source ${width}px: passed`);
  }
} finally {
  await browser.close();
}
