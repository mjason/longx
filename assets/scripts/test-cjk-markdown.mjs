// Actual chat, file-preview and generative-card renderers, including a streamed
// assistant answer. No server, model requests or stored messages are changed.
import assert from "node:assert/strict";
import { build } from "esbuild";
import { chromium } from "playwright";
import { mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const source = [
  "**测试。**后续文字",
  "",
  "前文**（重要）**后文",
  "",
  "~~旧方案。~~新方案",
  "",
  "- **标题。**正文",
  "",
  "| 项目 | 说明 |",
  "| --- | --- |",
  "| 中文 | **重点。**后文 |",
  "",
  "[**链接。**后文](https://example.com/)",
  "",
  "`**代码。**后文`",
  "",
  "```text",
  "**围栏代码。**后文",
  "```",
].join("\n");
const bundle = await build({
  absWorkingDir: root,
  stdin: { resolveDir: root, loader: "tsx", contents: `
    import React from "react";
    import {createRoot} from "react-dom/client";
    import {AssistantRuntimeProvider,useLocalRuntime} from "@assistant-ui/react";
    import {Thread} from "./js/ui/components/assistant-ui/elements/thread.aui";
    import {MarkdownPreview} from "./js/ui/editor/MarkdownPreview";
    import {GenerativeTree} from "./js/ui/components/assistant-ui/elements/generative-ui";
    import i18n from "./js/core/i18n";
    void i18n.changeLanguage("zh-CN");
    const source=${JSON.stringify(source)};
    function App(){
      const runtime=useLocalRuntime({async *run(){
        yield {content:[{type:"text",text:"前文**（流式"}]};
        await new Promise(resolve=>window.finishStream=resolve);
        yield {content:[{type:"text",text:"前文**（流式完成）**后文"}]};
      }},{initialMessages:[{role:"assistant",content:[{type:"text",text:source}]}]});
      window.startStream=()=>runtime.thread.append({role:"user",content:[{type:"text",text:"stream"}]});
      window.original=()=>runtime.thread.getState().messages[0].content[0].text;
      return <div style={{maxWidth:780,margin:"auto"}}>
        <section data-testid="chat" style={{height:700}}>
          <AssistantRuntimeProvider runtime={runtime}><Thread autoFocus={false}/></AssistantRuntimeProvider>
        </section>
        <MarkdownPreview source={source}/>
        <GenerativeTree tree={{$type:"Markdown",value:source}}/>
      </div>;
    }
    createRoot(document.getElementById("root")).render(<App/>);
  ` },
  bundle: true, write: false, format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false", "import.meta.env.MODE": '"browser-test"' },
  plugins: [{ name: "css", setup(builder) { builder.onLoad({ filter: /\.css$/ }, () => ({ contents: "", loader: "js" })); } }],
});
const manifest = JSON.parse(await readFile(path.join(root, "../priv/static/assets/.vite/manifest.json"), "utf8"));
const css = await readFile(path.join(root, "../priv/static/assets", manifest["js/index.tsx"].css[0]), "utf8");
const artifacts = path.join(root, "../.longx/local/artifacts/cjk-markdown");
await mkdir(artifacts, { recursive: true });
const browser = await chromium.launch();
try {
  for (const width of [1280, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.route("http://cjk-markdown.test/**", route => route.fulfill({ contentType: "text/html", body: '<div id="root"></div>' }));
    await page.goto("http://cjk-markdown.test/");
    await page.addStyleTag({ content: css });
    await page.addScriptTag({ content: bundle.outputFiles[0].text });
    for (const selector of ['[data-testid="chat"] .aui-md', '[data-testid="markdown-preview"]', '[data-aui="markdown"]']) {
      const surface = page.locator(selector).first();
      await surface.locator("strong").filter({ hasText: "测试。" }).waitFor();
      assert.equal(await surface.locator("strong").filter({ hasText: "（重要）" }).count(), 1);
      assert.equal(await surface.locator("del").innerText(), "旧方案。");
      assert.equal(await surface.locator("li strong").innerText(), "标题。");
      assert.equal(await surface.locator("td strong").innerText(), "重点。");
      assert.equal(await surface.locator("a strong").innerText(), "链接。");
      await surface.getByText("**围栏代码。**后文", { exact: true }).waitFor();
      assert.ok((await surface.locator("code").allTextContents()).some(text => text.includes("**代码。**后文")));
    }
    assert.equal(await page.evaluate(() => window.original()), source, "display does not rewrite stored Markdown");
    await page.screenshot({ path: path.join(artifacts, `chat-${width}.png`) });
    await page.evaluate(() => window.startStream());
    await page.waitForFunction(() => typeof window.finishStream === "function");
    await page.evaluate(() => window.finishStream());
    await page.locator('[data-testid="chat"] strong').filter({ hasText: "（流式完成）" }).waitFor();
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
    assert.deepEqual(errors, []);
    console.log(`CJK Markdown ${width}px: actual chat, preview, card, code safety, source preservation and streamed completion passed`);
    await page.close();
  }
} finally { await browser.close(); }
