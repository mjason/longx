// Real Shell cards in Chromium; commands are fixtures, nothing is executed.
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
    import React,{useState} from "react";
    import {createRoot} from "react-dom/client";
    import {CommandExecutionTool} from "./js/ui/chat/toolkit";
    import i18n from "./js/core/i18n";
    void i18n.changeLanguage("zh-CN");
    function App(){
      const [done,setDone]=useState(false);
      window.finish=()=>setDone(true);
      const card=(id,command,result,status={type:"complete"})=><div id={id}>
        <CommandExecutionTool type="tool-call" toolCallId={id} toolName="commandExecution"
          args={{command,cwd:"/workspace/longx"}} argsText="" result={result} status={status}
          artifact={result?undefined:"Running tests…\\n"} isError={!!result&&result.exitCode!==0}
          addResult={()=>{}} resume={()=>{}} respondToApproval={async()=>{}} />
      </div>;
      return <main className="mx-auto max-w-3xl space-y-4 p-4">
        <h1 className="text-lg font-medium">Shell 执行</h1>
        {card("stream","npm test",done?{status:"completed",exitCode:2,output:"AssertionError: expected 2 to equal 3\\n"+"x".repeat(180),durationMs:1240}:undefined,done?{type:"complete"}:{type:"running"})}
        {card("success","git status --short",{status:"completed",exitCode:0,output:"Working tree clean",durationMs:80})}
        {card("launch","missing-command",{status:"failed",exitCode:null,output:"Executable not found",durationMs:12})}
      </main>;
    }
    createRoot(document.getElementById("root")).render(<App/>);
  ` },
  bundle: true, write: false, format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false", "import.meta.env.MODE": '"browser-test"' },
  plugins: [{ name: "css", setup(builder) {
    builder.onLoad({filter:/\.css$/},()=>({contents:"",loader:"js"}));
  }}],
});
const manifest=JSON.parse(await readFile(path.join(root,"../priv/static/assets/.vite/manifest.json"),"utf8"));
const css=await readFile(path.join(root,"../priv/static/assets",manifest["js/index.tsx"].css[0]),"utf8");
const artifacts=path.join(root,"../.longx/local/artifacts/shell-cards/run-browser");
await mkdir(artifacts,{recursive:true});
const browser=await chromium.launch();
const settle = page => page.evaluate(async()=>{
  void document.body.offsetHeight;
  await Promise.all(document.getAnimations()
    .filter(animation=>animation.effect?.getTiming().iterations!==Infinity)
    .map(animation=>animation.finished.catch(()=>{})));
});
try {
  for (const width of [1280,390]) {
    const page=await browser.newPage({viewport:{width,height:800}});
    const errors=[];
    page.on("pageerror",error=>errors.push(error.message));
    await page.route("http://shell-cards.test/**",route=>route.fulfill({contentType:"text/html",body:'<div id="root"></div>'}));
    await page.goto("http://shell-cards.test/");
    await page.addStyleTag({content:css});
    await page.addScriptTag({content:bundle.outputFiles[0].text});
    await page.evaluate(()=>document.documentElement.dataset.theme="light");
    const running=page.locator("#stream");
    const trigger=running.getByRole("button");
    await running.getByText("Running tests…").waitFor();
    assert.equal(await trigger.getAttribute("aria-expanded"),"true");
    await page.evaluate(()=>window.finish());
    await page.waitForFunction(()=>document.querySelector("#stream button")?.getAttribute("aria-expanded")==="false");
    assert.equal(await running.getByText("exit 2",{exact:true}).count(),1);
    assert.equal(await running.getByText(/AssertionError/).isVisible(),false);
    assert.equal(await page.locator("#launch button").getAttribute("aria-expanded"),"false");
    await settle(page);
    await page.screenshot({path:path.join(artifacts,`collapsed-${width}.png`)});
    await trigger.click();
    await running.getByText(/AssertionError/).waitFor();
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),"long output stays inside its scroll area");
    await settle(page);
    await page.screenshot({path:path.join(artifacts,`expanded-${width}.png`)});
    await page.evaluate(()=>document.documentElement.dataset.theme="dark");
    assert.notEqual(await page.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue("--background").trim()),"");
    await settle(page);
    await page.screenshot({path:path.join(artifacts,`dark-${width}.png`)});
    assert.deepEqual(errors,[]);
    console.log(`Shell cards ${width}px: running, failure collapse, exit status, manual disclosure, overflow passed`);
    await page.close();
  }
} finally {await browser.close();}
