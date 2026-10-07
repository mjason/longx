// Real router, ChatProvider and assistant-ui runtimes; only the RPC/socket
// boundary is replaced. No real projects, uploads or model calls are created.
import assert from "node:assert/strict";
import { build } from "esbuild";
import { chromium } from "playwright";
import { readFile } from "node:fs/promises";
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
      import { createMemoryRouter, RouterProvider } from "react-router";
      import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
      import { I18nextProvider } from "react-i18next";
      import i18n from "./js/core/i18n";
      import { routes } from "./js/ui/routes";
      import { rpcMock, socketMock, channel, ok, failed, project, thread } from "./js/ui/test-mocks";
      void i18n.changeLanguage("zh-CN");
      window.channel=channel;
      window.fixtureSocket=socketMock();
      const api=window.fixtureApi=rpcMock();
      api.listProjects=async()=>ok([project(1),{...project(2),pinned:true}]);
      api.getProject=async args=>ok(project(args.input.slug==="app-2"?2:1));
      api.listThreads=async args=>ok([thread(args.input.projectId==="id-2"?2:1)]);
      window.sent=[]; window.steered=[]; window.batches=[]; window.releases=[];
      api.sendMessage=async args=>{window.sent.push(args.input);return ok({id:"turn-row"});};
      api.sendMessageBatch=async args=>{window.batches.push(args.input);return ok({id:"turn-row"});};
      api.releaseWaitingBatch=async args=>{window.releases.push(args.input);return ok(true);};
      api.steerTurn=async args=>{window.steered.push(args.input);return window.scenario==="paused"?failed("not_running",["threadId"]):ok({kernelTurnId:"turn-1"});};
      window.uploads=0;
      window.fetch=async(url,options)=>{
        if(!String(url).startsWith("/attachments/")) throw new Error("Unexpected fixture fetch: "+url);
        window.uploads++;
        const file=options.body.get("file");
        if(window.scenario==="upload") await new Promise(resolve=>{window.finishUpload=resolve;});
        return new Response(JSON.stringify({name:file.name,path:"/data/attachments/id-1/"+file.name,bytes:file.size}),{status:200});
      };
      const client=new QueryClient({defaultOptions:{queries:{retry:false}}});
      window.router=createMemoryRouter(routes,{initialEntries:["/p/app-1/t/t1"]});
      createRoot(document.getElementById("root")).render(
        <React.StrictMode><I18nextProvider i18n={i18n}><QueryClientProvider client={client}>
          <RouterProvider router={window.router}/>
        </QueryClientProvider></I18nextProvider></React.StrictMode>
      );
    `,
  },
  bundle: true, write: false, format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false", "import.meta.env.MODE": '"browser-test"' },
  plugins: [{
    name: "fixture-boundaries",
    setup(builder) {
      builder.onResolve({ filter: /^vitest$/ }, () => ({ path: "fixture-spies", namespace: "fixture" }));
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

async function switchProject(page, n, width) {
  const bar = page.getByTestId("project-switcher");
  const link = bar.getByRole("link", { name: new RegExp("App " + n) });
  if (width === 1280 && await link.count()) await link.click();
  else {
    await bar.getByRole("button", { name: "全部项目" }).click();
    await page.getByRole("dialog", { name: "全部项目" }).getByRole("option", { name: new RegExp("App " + n) }).click();
  }
  await page.waitForFunction(n => window.router.state.location.pathname.startsWith("/p/app-" + n), n);
  await page.waitForFunction(({ n, width }) => {
    const bar = document.querySelector('[data-testid="project-switcher"]');
    const current = width === 1280 ? bar?.querySelector('a[aria-current="page"]') : bar?.querySelector("button");
    return current?.textContent?.includes("App " + n);
  }, { n, width });
  await page.getByRole("textbox", { name: "随心输入" }).waitFor();
}

async function dropFiles(page, kinds) {
  await page.evaluate(kinds => {
    const transfer = new DataTransfer();
    for (const kind of kinds) {
      if (kind === "image") {
        const png = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aC1sAAAAASUVORK5CYII="), char => char.charCodeAt(0));
        transfer.items.add(new File([png], "shot.png", { type: "image/png" }));
      } else transfer.items.add(new File(["pdf"], "report.pdf", { type: "application/pdf" }));
    }
    document.querySelector("[data-slot=aui_composer-shell]").dispatchEvent(new DragEvent("drop", { bubbles: true, dataTransfer: transfer }));
  }, kinds);
}

const browser = await chromium.launch();
try {
  for (const width of [1280, 390]) {
    for (const scenario of ["image", "upload", "queue", "paused", "batch", "callbacks"]) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      page.setDefaultTimeout(10000);
      const errors = [];
      page.on("pageerror", error => errors.push(error.message));
      await page.route("http://chat-projects.test/**", route => route.fulfill({ contentType: "text/html", body: '<div id="root"></div>' }));
      await page.goto("http://chat-projects.test/");
      await page.evaluate(scenario => { window.scenario = scenario; }, scenario);
      await page.addStyleTag({ content: css });
      await page.addScriptTag({ content: bundle.outputFiles[0].text });
      await page.waitForFunction(() => !!window.channel?.byTopic["thread:thr_1"]);
      await page.evaluate(scenario => window.channel.replyTo("thread:thr_1", "ok", {
        thread_id: "thr_1", seq: 1, thread: null,
        turn: ["queue", "paused", "batch", "callbacks"].includes(scenario) ? {id:"turn-1",status:"inProgress"} : null,
        status: null, token_usage: null, pending_requests: [],
        items: scenario==="paused" ? [{id:"command",type:"commandExecution",turnId:"turn-1",command:"sleep 30",cwd:"/p",status:"inProgress"}] : [],
      }), scenario);
      await page.getByRole("textbox", { name: "随心输入" }).waitFor();
      if (scenario === "callbacks") {
        await page.evaluate(() => window.channel.deliverTo("thread:thr_1", "event", {
          seq: 2, method: "thread/waiting/updated", params: {
            waiting: Array.from({length: 12}, (_, index) => ({
              id: "w"+index, text: "report "+index+"\nfull details", from: index===11 ? "reviewer" : "coder",
              at: "2026-10-05T00:00:00Z",
            })), paused: false,
          },
        }));
        const toggle = page.getByRole("button", { name: "待处理消息 · 12 条" });
        await toggle.waitFor();
        assert.equal(await toggle.getAttribute("aria-expanded"), "false");
        assert.equal(await page.getByTestId("waiting-message").count(), 0);
        await toggle.click();
        assert.equal(await page.getByTestId("waiting-group").count(), 2);
        assert.equal(await page.getByTestId("waiting-message").count(), 12);
        const list = page.locator('[id]').filter({ has: page.getByTestId("waiting-group") }).last();
        assert.ok(await list.evaluate(el => el.clientHeight <= 256 && el.scrollHeight > el.clientHeight), "expanded list is bounded and scrollable");
        await toggle.click();
        await page.getByRole("button", { name: "全部插入" }).click();
        await page.waitForFunction(() => window.releases.length===1);
        assert.deepEqual(await page.evaluate(() => window.releases), [{threadId:"t1"}]);
        assert.deepEqual(errors, []);
        console.log(`chat projects ${width}px callbacks: folded, grouped, bounded and one batch RPC passed`);
        await page.close();
        continue;
      }
      await dropFiles(page, scenario === "upload" ? ["file"] : scenario === "image" ? ["image"] : ["image", "file"]);

      if (scenario === "upload") await page.waitForFunction(() => window.uploads === 1);
      else await page.getByRole("button", { name: /image attachment/i }).waitFor();
      if (scenario === "queue" || scenario === "paused" || scenario === "batch") {
        await page.getByRole("button", { name: /file attachment/i }).waitFor();
        await page.getByRole("textbox", { name: "随心输入" }).fill("queued payload");
        await page.getByRole("button", { name: "加入队列" }).click();
        await page.getByTestId("message-queue").waitFor();
        if (scenario === "batch") {
          await page.getByRole("textbox", { name: "随心输入" }).fill("second instruction");
          await page.getByRole("button", { name: "加入队列" }).click();
        }
        if (scenario === "paused") {
          await page.getByRole("button", { name: /停止/ }).click();
          await page.evaluate(() => window.channel.deliverTo("thread:thr_1", "event", {
            seq: 2, method:"turn/completed", params:{turn:{id:"turn-1",status:"interrupted"}},
          }));
        }
      }
      await switchProject(page, 2, width);
      assert.equal(await page.getByRole("button", { name: /image attachment|file attachment/i }).count(), 0, "no draft attachments leak into another project");
      assert.equal(await page.getByTestId("message-queue").count(), 0, "no queued message leaks into another project");

      if (scenario === "queue" || scenario === "batch") {
        await page.evaluate(() => window.channel.deliverTo("thread:thr_1", "event", {
          seq: 2, method:"turn/completed", params:{turn:{id:"turn-1",status:"completed"}},
        }));
        await page.waitForFunction(scenario => scenario==="batch" ? window.batches.length===1 : window.sent.length===1, scenario);
        assert.equal(await page.evaluate(() => window.router.state.location.pathname), "/p/app-2", "background dispatch cannot hijack the visible project");
      } else {
        if (scenario === "upload") await page.evaluate(() => window.finishUpload());
        await switchProject(page, 1, width);
        if (scenario === "paused") {
          await page.getByTestId("message-queue").waitFor();
          assert.equal(await page.evaluate(() => window.sent.length), 0, "paused queue remains paused across project switches");
          await page.getByTestId("message-queue").getByRole("button", { name: "插入" }).click();
        } else {
          await page.getByRole("button", { name: scenario === "image" ? /image attachment/i : /file attachment/i }).waitFor();
          await page.getByRole("button", { name: "发送" }).click();
        }
        await page.waitForFunction(() => window.sent.length === 1);
      }
      const sent = await page.evaluate(scenario => scenario==="batch"
        ? {...window.batches[0].messages[0], threadId: window.batches[0].threadId}
        : window.sent[0], scenario);
      assert.equal(sent.threadId, "t1");
      if (scenario === "batch") {
        assert.equal(await page.evaluate(() => window.batches[0].messages.length), 2);
        assert.equal(await page.evaluate(() => window.batches[0].messages[1].text), "second instruction");
        assert.equal(await page.evaluate(() => window.sent.length), 0);
      }
      if (scenario !== "upload") assert.ok(sent.images?.[0]?.startsWith("data:image/png;base64,"), "image reaches the RPC as a data URL");
      if (scenario !== "image") {
        assert.ok(sent.text.includes("/data/attachments/id-1/report.pdf"), "uploaded file path reaches the RPC");
        assert.equal(await page.evaluate(() => window.uploads), 1, "switching never uploads the same file twice");
      }
      assert.deepEqual(errors, []);
      console.log(`chat projects ${width}px ${scenario}: attachments, owner, dispatch and navigation passed`);
      await page.close();
    }
  }
} finally { await browser.close(); }
