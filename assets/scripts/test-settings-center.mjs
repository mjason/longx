// Real routes and forms in Chromium; API fixtures never touch user settings.
import assert from "node:assert/strict";
import { build } from "esbuild";
import { chromium } from "playwright";
import { mkdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const operations = [...(await readFile(path.join(root, "js/core/api.ts"), "utf8")).matchAll(/export const (\w+):/g)].map(m => m[1]);
const bundle = await build({
  absWorkingDir: root,
  stdin: { resolveDir: root, loader: "tsx", contents: `
    import React from "react";
    import {createRoot} from "react-dom/client";
    import {createMemoryRouter,RouterProvider} from "react-router";
    import {QueryClient,QueryClientProvider} from "@tanstack/react-query";
    import {I18nextProvider} from "react-i18next";
    import i18n from "./js/core/i18n";
    import {routes} from "./js/ui/routes";
    import {rpcMock,socketMock,ok,project,agentDefinitionData,agentSettingsData,promotionPreviewData} from "./js/ui/test-mocks";
    void i18n.changeLanguage("zh-CN");
    window.fixtureSocket=socketMock();
    const api=window.fixtureApi=rpcMock();
    let row=project(1),global=agentSettingsData();
    window.saves=[];
    api.getProject=async()=>ok(row);
    api.agentSettings=async()=>ok(global);
    api.setAgentSettings=async args=>{window.saves.push({scope:"global",input:args.input});global={...global,...args.input};return ok(global);};
    api.updateProject=async args=>{window.saves.push({scope:"project",input:args.input});row={...row,...args.input,updatedAt:new Date().toISOString()};return ok(row);};
    api.agentDefinition=async()=>ok(agentDefinitionData({settings:global}));
    api.extensionInventory=async()=>ok([
      {kind:"agents",layer:"local",name:"reviewer",path:".longx/local/agents/reviewer",shareable:true,complete:true},
      {kind:"artifacts",layer:"local",name:"run-one",path:".longx/local/artifacts/e2e/run-one",shareable:false,complete:true}
    ]);
    api.previewLocal=async()=>ok(promotionPreviewData("agents/reviewer",{conflicts:[".longx/shared/agents/reviewer"],canShare:false}));
    window.router=createMemoryRouter(routes,{initialEntries:["/p/app-1/settings?section=resources"]});
    createRoot(document.getElementById("root")).render(
      <I18nextProvider i18n={i18n}><QueryClientProvider client={new QueryClient({defaultOptions:{queries:{retry:false}}})}>
        <RouterProvider router={window.router}/>
      </QueryClientProvider></I18nextProvider>
    );
  ` },
  bundle: true, write: false, format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false", "import.meta.env.MODE": '"browser-test"' },
  plugins: [{ name: "fixtures", setup(builder) {
    builder.onResolve({filter:/^vitest$/},()=>({path:"spies",namespace:"fixture"}));
    builder.onLoad({filter:/.*/,namespace:"fixture"},()=>({contents:`export const vi={fn:(implementation=()=>undefined)=>{const fn=(...args)=>{fn.mock.calls.push(args);return implementation(...args);};fn.mock={calls:[]};fn.mockClear=()=>{fn.mock.calls=[];};return fn;}};`,loader:"js"}));
    builder.onLoad({filter:/\/js\/core\/api\.ts$/},()=>({contents:operations.map(name=>`export const ${name}=args=>window.fixtureApi.${name}(args);`).join("\n"),loader:"js"}));
    builder.onLoad({filter:/\/js\/core\/socket\.ts$/},()=>({contents:["getSocket","joinBreaker","reconnectSocket","socketStatus","onSocketStatus"].map(name=>`export const ${name}=(...args)=>window.fixtureSocket.${name}(...args);`).join("\n"),loader:"js"}));
    builder.onLoad({filter:/\.css$/},()=>({contents:"",loader:"js"}));
  }}],
});
const manifest=JSON.parse(await readFile(path.join(root,"../priv/static/assets/.vite/manifest.json"),"utf8"));
const css=await readFile(path.join(root,"../priv/static/assets",manifest["js/index.tsx"].css[0]),"utf8");
const artifacts=path.join(root,"../.longx/local/artifacts/settings-center/run-browser");
await mkdir(artifacts,{recursive:true});
const browser=await chromium.launch();
try {
  for (const width of [1920,1280,390]) {
    const page=await browser.newPage({viewport:{width,height:900}});
    const errors=[];
    page.on("pageerror",e=>errors.push(e.message));
    await page.route("http://settings-center.test/**",route=>route.fulfill({contentType:"text/html",body:'<div id="root"></div>'}));
    await page.goto("http://settings-center.test/");
    await page.addStyleTag({content:css});
    await page.addScriptTag({content:bundle.outputFiles[0].text});
    const center=page.getByTestId("settings-center");
    const memory=center.getByLabel("单任务内存上限（%）");
    await memory.waitFor();
    const projectNavigation=width===390
      ? center.getByRole("combobox",{name:"设置中心",exact:true})
      : center.getByRole("navigation",{name:"设置中心",exact:true});
    const categories=await projectNavigation.textContent();
    for(const global of ["Provider","浏览器","电脑与命令环境","凭证","外观","快捷键","HTTPS","版本与更新","运行状态与诊断"]) {
      assert.ok(!categories.includes(global),`${global} belongs only in global settings`);
    }
    await memory.fill("40");
    await center.getByRole("button",{name:"全局默认",exact:true}).click();
    const dialog=page.getByRole("dialog");
    await dialog.getByRole("button",{name:"继续编辑",exact:true}).click();
    assert.equal(await memory.inputValue(),"40");
    await center.getByRole("button",{name:"全局默认",exact:true}).click();
    await dialog.getByRole("button",{name:"丢弃草稿并离开",exact:true}).click();
    await center.getByLabel("单任务内存上限（%）").fill("60");
    await center.getByRole("button",{name:"保存全局默认",exact:true}).click();
    await page.waitForFunction(()=>window.saves.length===1);
    assert.equal(await page.evaluate(()=>window.saves[0].scope),"global");
    if(width===390) await center.getByRole("combobox",{name:"设置中心",exact:true}).waitFor();
    await page.screenshot({path:path.join(artifacts,`resources-${width}.png`),fullPage:true});
    await page.evaluate(()=>window.router.navigate("/p/app-1/settings?section=extensions"));
    const manager=page.getByTestId("project-extensions");
    await manager.getByRole("tab",{name:"概览",exact:true}).waitFor();
    await page.waitForFunction(()=>document.querySelector('[data-testid="settings-center"] [role="group"] [aria-pressed="true"]')?.textContent.includes("当前项目"));
    await page.mouse.move(0,0);
    await page.evaluate(async()=>{
      const group=document.querySelector('[data-testid="settings-center"] [role="group"]');
      await Promise.all(group.getAnimations({subtree:true}).map(animation=>animation.finished.catch(()=>{})));
    });
    await page.screenshot({path:path.join(artifacts,`extensions-${width}.png`),fullPage:true});
    const layout=await page.evaluate(()=>{
      const rect=selector=>document.querySelector(selector).getBoundingClientRect();
      const detail=rect('[data-testid="settings-detail"]');
      const form=rect('[data-testid="project-settings"]');
      const agent=rect('[data-testid="project-agent"]');
      const objects=rect('[data-testid="project-extensions"]');
      const heading=rect('[data-testid="settings-detail"] > h2');
      return {detail:detail.x,form:form.x,agent:agent.x,objects:objects.x,heading:heading.x,
        width:detail.width,height:document.documentElement.scrollHeight,viewport:innerHeight};
    });
    assert.ok(Math.abs(layout.heading-layout.form)<=1,"form aligns with category heading");
    assert.ok(Math.abs(layout.agent-layout.objects)<=1,"trust and extension objects align");
    assert.ok(layout.width<=900,"settings content has a readable maximum width");
    assert.ok(layout.height<=layout.viewport+1,"settings stay inside workbench scroll container");
    await manager.getByRole("tab",{name:/角色/}).click();
    await manager.getByRole("button",{name:"准备共享",exact:true}).click();
    await dialog.getByText(/目标已有共享对象/).waitFor();
    assert.equal(await dialog.getByRole("button",{name:"确认移动到 shared",exact:true}).isDisabled(),true);
    await page.keyboard.press("Escape");
    await manager.getByRole("tab",{name:/本地产物/}).click();
    assert.equal(await manager.getByRole("button",{name:"准备共享",exact:true}).count(),0);
    await manager.getByText("run-one",{exact:true}).waitFor();
    await page.screenshot({path:path.join(artifacts,`artifacts-${width}.png`),fullPage:true});
    await center.getByRole("button",{name:"全局默认",exact:true}).click();
    await page.evaluate(()=>window.router.navigate("/p/app-1/settings?scope=global&section=models"));
    await page.getByTestId("search-provider").waitFor();
    assert.ok(await page.evaluate(()=>document.documentElement.scrollHeight<=innerHeight+1),"global models do not overflow the document");
    assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),"no horizontal overflow");
    assert.deepEqual(errors,[]);
    console.log(`settings center ${width}px: scope, drafts, scoped save, conflicts, outputs, layout passed`);
    await page.close();
  }
} finally {await browser.close();}
