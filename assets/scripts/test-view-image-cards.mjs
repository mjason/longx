// Namespaced calls rendered through the actual toolkit and Thread; image bytes
// are a local fixture, not read from arbitrary paths by a new HTTP endpoint.
import assert from "node:assert/strict";
import { build } from "esbuild";
import { chromium } from "playwright";
import { mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const image = await readFile(path.join(root, "../docs/media/file-preview.png"));
const bundle = await build({
  absWorkingDir: root,
  stdin: { resolveDir: root, loader: "tsx", contents: `
    import React from "react";
    import {createRoot} from "react-dom/client";
    import {AssistantRuntimeProvider,useLocalRuntime} from "@assistant-ui/react";
    import {Thread} from "./js/ui/components/assistant-ui/elements/thread.aui";
    import {chatConfig,SurfaceContext} from "./js/ui/chat/toolkit";
    import i18n from "./js/core/i18n";
    void i18n.changeLanguage("zh-CN");
    window.language=language=>i18n.changeLanguage(language);
    const tool=(id,result)=>({type:"tool-call",toolCallId:id,toolName:"view_image.view_image",args:{path:"/tmp/修改卡片.png"},result});
    function App(){
      const runtime=useLocalRuntime({async *run(){}},{initialMessages:[
        {role:"assistant",content:[
          {type:"text",text:"图片查看工具 · 预览、错误和旧记录"},
          tool("preview",{success:true,details:{name:"修改卡片.png",path:"preview.png",mime:"image/png",attachment:true,bytes:${image.byteLength}}}),
          tool("failed",{success:false,details:{name:"missing.png",error:"not_found"}}),
          tool("historical",{success:true,contentItems:[{type:"inputText",text:"attached /tmp/修改卡片.png"}]})
        ]}
      ]});
      return <AssistantRuntimeProvider runtime={runtime} config={chatConfig}>
        <SurfaceContext.Provider value={{projectId:"project-1",open:()=>{}}}>
          <div style={{height:"100dvh",maxWidth:780,margin:"auto"}}><Thread autoFocus={false}/></div>
        </SurfaceContext.Provider>
      </AssistantRuntimeProvider>;
    }
    createRoot(document.getElementById("root")).render(<App/>);
  ` },
  bundle: true, write: false, format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false", "import.meta.env.MODE": '"browser-test"' },
  plugins: [{ name: "css", setup(builder) { builder.onLoad({ filter: /\.css$/ }, () => ({ contents: "", loader: "js" })); } }],
});
const manifest = JSON.parse(await readFile(path.join(root, "../priv/static/assets/.vite/manifest.json"), "utf8"));
const css = await readFile(path.join(root, "../priv/static/assets", manifest["js/index.tsx"].css[0]), "utf8");
const artifacts = path.join(root, "../.longx/local/artifacts/view-image-cards");
await mkdir(artifacts, { recursive: true });
const browser = await chromium.launch();
try {
  for (const width of [1280, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.route("http://view-images.test/**", route => route.fulfill({ contentType: "text/html", body: '<div id="root"></div>' }));
    await page.route("http://view-images.test/files/**", route => route.fulfill({ contentType: "image/png", body: image }));
    await page.goto("http://view-images.test/");
    await page.addStyleTag({ content: css });
    await page.addScriptTag({ content: bundle.outputFiles[0].text });
    const card = page.getByTestId("tool-view-image").first();
    await card.getByText("查看了图片").waitFor();
    const thumbnail = card.getByRole("img");
    await thumbnail.waitFor();
    await page.waitForFunction(() => document.querySelector('[data-testid="tool-view-image"] img')?.naturalWidth > 0);
    assert.equal(await page.getByTestId("tool-view-image").count(), 3);
    assert.equal(await page.getByText("图片文件不存在", { exact: true }).count(), 1);
    assert.equal(await page.getByText("这条记录没有可用的图片预览", { exact: true }).count(), 1);
    assert.equal(await page.getByText(/Used tool:|contentItems/).count(), 0);
    await card.scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(artifacts, `preview-${width}.png`) });
    await card.getByRole("button", { name: "点击查看大图" }).click();
    await page.getByRole("dialog", { name: "图片大图" }).waitFor();
    await page.screenshot({ path: path.join(artifacts, `zoom-${width}.png`) });
    await page.evaluate(() => window.language("en"));
    await page.getByRole("dialog", { name: "Zoomed image" }).waitFor();
    await page.getByRole("button", { name: "Close zoomed image" }).click();
    await card.getByText("Viewed image").waitFor();
    assert.equal(await page.getByText("Image file not found", { exact: true }).count(), 1);
    assert.equal(await page.getByText("No image preview is available for this record", { exact: true }).count(), 1);
    await card.scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(artifacts, `english-${width}.png`) });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
    assert.deepEqual(errors, []);
    console.log(`View image ${width}px: actual toolkit routing, preview bytes, zoom, bilingual live switch, errors and legacy records passed`);
    await page.close();
  }
} finally { await browser.close(); }
