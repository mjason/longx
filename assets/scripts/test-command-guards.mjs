// Real settings routes, forms and status card in Chromium. Only the API/socket
// boundary is a fixture: no cgroups, services or real settings are changed.
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
  stdin: {
    resolveDir: root, loader: "tsx",
    contents: `
      import React from "react";
      import { createRoot } from "react-dom/client";
      import { createMemoryRouter, RouterProvider, useLocation } from "react-router";
      import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
      import { I18nextProvider } from "react-i18next";
      import i18n from "./js/core/i18n";
      import { routes } from "./js/ui/routes";
      import { CommandGuardStatus } from "./js/ui/components/CommandGuardStatus";
      import { rpcMock, socketMock, ok, project, agentSettingsData, agentDefinitionData } from "./js/ui/test-mocks";
      void i18n.changeLanguage("zh-CN");
      window.fixtureSocket=socketMock();
      const api=window.fixtureApi=rpcMock();
      let global=agentSettingsData();
      let row=project(1);
      window.saves=[];
      window.guard={capability:"eligible",reason:"startup still verifies",activeTasks:0,cleanupPendingTasks:0,
        lastTaskStatus:null,lastTaskReason:null,lastTaskPath:null,lastOomKill:null,lastPopulated:null,
        lastCleanupError:null,lastObservedAt:null,path:"/delegated",platform:"linux",checkedAt:"2026-10-07T00:00:00Z"};
      api.agentSettings=async()=>ok({...global});
      api.setAgentSettings=async args=>{window.saves.push(args.input);global={...global,...args.input};return ok({...global});};
      api.getProject=async()=>ok({...row});
      api.updateProject=async args=>{
        window.saves.push(args.input);
        row={...row,...args.input,updatedAt:new Date().toISOString()};
        return ok({...row});
      };
      const effective=()=>Object.fromEntries(Object.entries({...global,...row.agentSettings})
        .map(([key,value])=>[key,value??global[key]]));
      api.agentDefinition=async()=>ok(agentDefinitionData({settings:effective(),overrides:row.agentSettings??{}}));
      api.commandGuardStatus=async args=>{
        const mode=(args?.input?.projectId?effective():global).commandCgroupMode;
        return ok({...window.guard,mode,...(mode==="off"?{capability:"off",reason:null,path:null}:{})});
      };
      window.client=new QueryClient({defaultOptions:{queries:{retry:false}}});
      // Diagnostics now has its own category. Keep the same real status card
      // beside the forms in this fixture so mode/status integration stays covered.
      function FixtureStatus(){
        const location=useLocation();
        return <CommandGuardStatus projectId={location.pathname.startsWith("/p/")?row.id:undefined}/>;
      }
      const fixtureRoutes=routes.map((route,index)=>index===0?{...route,element:<>{route.element}<FixtureStatus/></>}:route);
      window.router=createMemoryRouter(fixtureRoutes,{initialEntries:["/settings/resources"]});
      createRoot(document.getElementById("root")).render(
        <I18nextProvider i18n={i18n}><QueryClientProvider client={window.client}>
          <RouterProvider router={window.router}/>
        </QueryClientProvider></I18nextProvider>
      );
    `,
  },
  bundle: true, write: false, format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false", "import.meta.env.MODE": '"browser-test"' },
  plugins: [{
    name: "fixture-boundaries",
    setup(builder) {
      builder.onResolve({ filter: /^vitest$/ }, () => ({ path: "spies", namespace: "fixture" }));
      builder.onLoad({ filter: /.*/, namespace: "fixture" }, () => ({
        contents: `export const vi={fn:(implementation=()=>undefined)=>{
          const fn=(...args)=>{fn.mock.calls.push(args);return implementation(...args);};
          fn.mock={calls:[]};fn.mockClear=()=>{fn.mock.calls=[];};return fn;
        }};`, loader: "js",
      }));
      builder.onLoad({ filter: /\/js\/core\/api\.ts$/ }, () => ({
        contents: operations.map(name => `export const ${name}=args=>window.fixtureApi.${name}(args);`).join("\n"), loader: "js",
      }));
      builder.onLoad({ filter: /\/js\/core\/socket\.ts$/ }, () => ({
        contents: ["getSocket", "joinBreaker", "reconnectSocket", "socketStatus", "onSocketStatus"]
          .map(name => `export const ${name}=(...args)=>window.fixtureSocket.${name}(...args);`).join("\n"), loader: "js",
      }));
      builder.onLoad({ filter: /\.css$/ }, () => ({ contents: "", loader: "js" }));
    },
  }],
});
const manifest = JSON.parse(await readFile(path.join(root, "../priv/static/assets/.vite/manifest.json"), "utf8"));
const css = await readFile(path.join(root, "../priv/static/assets", manifest["js/index.tsx"].css[0]), "utf8");
const artifacts = path.join(root, "../.longx/local/artifacts/cgroup-settings");
await mkdir(artifacts, { recursive: true });
const browser = await chromium.launch();
try {
  for (const width of [1280, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    page.setDefaultTimeout(10_000);
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.route("http://command-guards.test/**", route => route.fulfill({ contentType: "text/html", body: '<div id="root"></div>' }));
    await page.goto("http://command-guards.test/");
    await page.addStyleTag({ content: css });
    await page.addScriptTag({ content: bundle.outputFiles[0].text });
    const status = page.getByTestId("command-guard-status");
    await status.getByText("具备启动保护的条件").waitFor();
    assert.equal(await status.getByText("启动时已启用", { exact: true }).count(), 0);
    await status.getByText("当前已确认启用保护的任务：0").waitFor();
    await status.screenshot({ path: path.join(artifacts, `diagnostic-idle-${width}.png`) });
    await status.getByText("技术详情", { exact: true }).click();

    const form = page.getByTestId("agent-settings");
    await form.getByLabel("任务 cgroup 保护").click();
    await page.getByRole("option", { name: "关闭", exact: true }).click();
    await form.getByRole("button", { name: "保存全局默认", exact: true }).click();
    await status.getByText("已关闭；未执行检测").waitFor();
    assert.equal(await page.evaluate(() => window.saves.at(-1).commandCgroupMode), "off");

    await form.getByLabel("任务 cgroup 保护").click();
    await page.getByRole("option", { name: "必须启用", exact: true }).click();
    await page.evaluate(() => Object.assign(window.guard, {capability:"unavailable",reason:"no delegated supervisor"}));
    await form.getByRole("button", { name: "保存全局默认", exact: true }).click();
    await status.getByText("当前不可用").waitFor();
    await status.getByText("no delegated supervisor").waitFor();
    assert.equal(await page.evaluate(() => window.saves.at(-1).commandCgroupMode), "required");

    await page.evaluate(async () => {
      Object.assign(window.guard, {capability:"eligible",reason:"startup still verifies",activeTasks:1,lastTaskStatus:"active"});
      await window.client.invalidateQueries({queryKey:["agent-kernel"]});
    });
    await status.getByText("当前已确认启用保护的任务：1").waitFor();
    await status.getByText("技术详情", { exact: true }).click();
    await status.screenshot({ path: path.join(artifacts, `diagnostic-active-${width}.png`) });
    await status.getByText("技术详情", { exact: true }).click();
    await page.evaluate(async () => {
      Object.assign(window.guard, {activeTasks:0,cleanupPendingTasks:1,lastPopulated:true,lastCleanupError:"blocked task"});
      await window.client.invalidateQueries({queryKey:["agent-kernel"]});
    });
    await status.getByRole("alert").waitFor();
    await status.getByText("blocked task").waitFor();
    await page.screenshot({ path: path.join(artifacts, `global-${width}.png`), fullPage: true });

    // No invalidation or navigation: the real five-second polling hook must refresh.
    await page.evaluate(() => Object.assign(window.guard, {
      capability:"unsupported", platform:"darwin", reason:"Task cgroup protection is Linux-only.",
      cleanupPendingTasks:0,lastPopulated:null,lastCleanupError:null,lastTaskStatus:null,
    }));
    await status.getByText("当前平台不支持 Linux cgroup").waitFor();
    await status.getByText("Task cgroup protection is Linux-only.").waitFor();
    await page.screenshot({ path: path.join(artifacts, `unsupported-${width}.png`), fullPage: true });

    await form.getByLabel("任务 cgroup 保护").click();
    await page.getByRole("option", { name: "自动", exact: true }).click();
    await page.evaluate(() => Object.assign(window.guard, {
      capability:"eligible",platform:"linux",reason:"startup still verifies",
    }));
    await form.getByRole("button", { name: "保存全局默认", exact: true }).click();
    await status.getByText("具备启动保护的条件").waitFor();
    assert.equal(await page.evaluate(() => window.saves.at(-1).commandCgroupMode), "auto");

    await page.evaluate(async () => {
      await window.fixtureApi.setAgentSettings({input:{commandCgroupMode:"off"}});
      Object.assign(window.guard, {cleanupPendingTasks:0,lastPopulated:null,lastCleanupError:null,lastTaskStatus:null});
      await window.client.invalidateQueries({queryKey:["agent-kernel"]});
      await window.router.navigate("/p/app-1/settings?section=resources");
    });
    const projectForm = page.getByTestId("project-agent-overrides");
    await projectForm.getByLabel("任务 cgroup 保护").waitFor();
    assert.match(await projectForm.getByLabel("任务 cgroup 保护").textContent(), /沿用 off/);
    await projectForm.getByLabel("任务 cgroup 保护").click();
    await page.getByRole("option", { name: "自动", exact: true }).click();
    await page.getByRole("button", { name: "保存本项目", exact: true }).click();
    await status.getByText("具备启动保护的条件").waitFor();
    assert.equal(await page.evaluate(() => window.saves.at(-1).agentSettings.commandCgroupMode), "auto");
    await projectForm.getByLabel("任务 cgroup 保护").click();
    await page.getByRole("option", { name: "必须启用", exact: true }).click();
    await page.getByRole("button", { name: "保存本项目", exact: true }).click();
    await status.getByText("已保存模式: 必须启用 · linux").waitFor();
    assert.equal(await page.evaluate(() => window.saves.at(-1).agentSettings.commandCgroupMode), "required");
    await projectForm.getByLabel("任务 cgroup 保护").click();
    await page.getByRole("option", { name: "关闭", exact: true }).click();
    await page.getByRole("button", { name: "保存本项目", exact: true }).click();
    await status.getByText("已关闭；未执行检测").waitFor();
    assert.equal(await page.evaluate(() => window.saves.at(-1).agentSettings.commandCgroupMode), "off");
    await projectForm.getByLabel("任务 cgroup 保护").click();
    await page.getByRole("option", { name: "沿用 off", exact: true }).click();
    await page.getByRole("button", { name: "保存本项目", exact: true }).click();
    await status.getByText("已关闭；未执行检测").waitFor();
    assert.equal(await page.evaluate(() => window.saves.at(-1).agentSettings.commandCgroupMode), null);
    await page.screenshot({ path: path.join(artifacts, `project-${width}.png`), fullPage: true });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), "settings must wrap without horizontal scrolling");
    assert.deepEqual(errors, []);
    console.log(`cgroup settings ${width}px: global/project modes, polling, unsupported, honest task status, cleanup, inheritance passed`);
    await page.close();
  }
} finally {
  await browser.close();
}
