// Real thread/composer components and generated Tailwind CSS in Chromium.
// Only the API/socket boundary is a fixture; no live conversations are changed.
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
      import { createMemoryRouter, RouterProvider } from "react-router";
      import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
      import { I18nextProvider } from "react-i18next";
      import i18n from "./js/core/i18n";
      import { routes } from "./js/ui/routes";
      import { rpcMock, socketMock, ok, channel, model, thread } from "./js/ui/test-mocks";
      void i18n.changeLanguage("zh-CN");
      window.fixtureSocket=socketMock();
      const api=window.fixtureApi=rpcMock();
      window.channel=channel;
      window.jobs=[];
      window.seq=1;
      api.projectJobs=async()=>ok({jobs:window.jobs});
      const slug=window.fixtureModelSlug;
      api.getThread=async()=>ok({...thread(1),modelSlug:slug});
      api.listThreads=async()=>ok([{...thread(1),modelSlug:slug}]);
      api.listModels=async()=>ok([model(1,{slug,default:true})]);
      window.client=new QueryClient({defaultOptions:{queries:{retry:false}}});
      const router=createMemoryRouter(routes,{initialEntries:["/p/app-1/t/t1"]});
      createRoot(document.getElementById("root")).render(
        <I18nextProvider i18n={i18n}><QueryClientProvider client={window.client}>
          <RouterProvider router={router}/>
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
const artifacts = path.join(root, "../.longx/local/artifacts/composer-layout");
await mkdir(artifacts, { recursive: true });
const browser = await chromium.launch();
try {
  for (const { width, slug } of [320, 375, 390, 640, 1280].flatMap(width =>
    ["gpt-6.1-sol", "gpt-6.1-sol-a-very-long-compatible-model-name"].map(slug => ({ width, slug })))) {
    const page = await browser.newPage({ viewport: { width, height: 850 } });
    page.setDefaultTimeout(10_000);
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.route("http://composer-layout.test/**", route => route.fulfill({ contentType: "text/html", body: '<div id="root"></div>' }));
    await page.goto("http://composer-layout.test/");
    await page.evaluate(slug => { window.fixtureModelSlug = slug; }, slug);
    await page.addStyleTag({ content: css });
    await page.addScriptTag({ content: bundle.outputFiles[0].text });
    await page.waitForFunction(() => window.channel.topics.includes("thread:thr_1"));
    await page.evaluate(() => window.channel.replyTo("thread:thr_1", "ok", {
      thread_id: "thr_1", seq: 1, thread: { id: "thr_1" },
      turn: { id: "turn_1", status: "completed" }, items: [], pending_requests: [],
      token_usage: { modelContextWindow: 128000, last: { inputTokens: 42000, outputTokens: 1000 } },
    }));
    const rail = page.locator(".aui-composer-action-wrapper");
    await rail.waitFor();
      await page.getByTestId("model-picker").getByText(slug, { exact: true }).waitFor();
    for (const state of ["idle", "running", "long", "waiting"]) {
      await page.evaluate(async state => {
        window.jobs = state === "idle" ? [] : [{
          name: "build", run: "build-1", cmd: "example", status: "exited", activity: "pending",
          purpose: "wait", threadId: "t1", rootThreadId: "t1", exitCode: 0,
        }];
        await window.client.invalidateQueries({ queryKey: ["project", "id-1", "jobs"] });
        window.channel.deliver("event", {
          seq: ++window.seq, method: state === "idle" ? "turn/completed" : "turn/started",
          params: { turn: { id: "turn_2", status: state === "idle" ? "completed" : "inProgress" } },
        });
        window.channel.deliver("event", {
          seq: ++window.seq, method: "turn/progress",
          params: { turnId: "turn_2", progress: state === "long" ? {
            kind: "toolCall", name: "a_very_long_tool_name_that_does_not_fit", bytes: 12800, quiet: 45,
          } : null },
        });
        if (state === "waiting") window.channel.deliver("event", {
          seq: ++window.seq, method: "longx/action/request",
          params: { requestId: "ask_1", itemId: "call_1", threadId: "thr_1", title: "等待确认", text: "", url: null },
        });
      }, state);
      if (state !== "idle") await page.getByTestId("job-work-status").waitFor();
      if (state === "waiting") await page.getByTestId("turn-bar").getByText("等待你操作").waitFor();
      if (state === "long") await page.getByTestId("turn-bar").getByText(/a_very_long_tool_name/).waitFor();
      await page.locator('[data-slot="context-display-trigger"]').waitFor();
      const geometry = await rail.evaluate(el => {
        const rect = node => {
          const r = node.getBoundingClientRect();
          return { x: r.x, y: r.y, right: r.right, bottom: r.bottom, width: r.width, height: r.height };
        };
        const bar = el.querySelector('[data-testid="turn-bar"]');
        const attachment = el.querySelector(".aui-composer-add-attachment");
        const model = el.querySelector('[data-testid="model-picker"]');
        const context = el.querySelector('[data-slot="context-display-trigger"]');
        const action = el.querySelector(".aui-composer-cancel, .aui-composer-send");
        const job = el.querySelector('[data-testid="job-work-status"]');
        return {
          rail: rect(el), bar: rect(bar), attachment: rect(attachment), context: rect(context), model: rect(model), action: rect(action),
          job: job ? rect(job) : null, overflow: el.scrollWidth > el.clientWidth,
          statusHeight: bar.firstElementChild ? rect(bar.firstElementChild).height : 0,
        };
      });
      await rail.screenshot({ path: path.join(artifacts, `${width}-${slug.length > 20 ? "long-model" : "model"}-${state}.png`) });
      assert.equal(geometry.overflow, false, `${width}/${state}: rail overflow ${JSON.stringify(geometry)}`);
      assert.ok(geometry.attachment.right <= geometry.context.x, `${width}/${state}: attachment overlaps context`);
      assert.ok(geometry.context.right <= geometry.model.x, `${width}/${state}: context overlaps model`);
      assert.ok(geometry.model.right <= geometry.action.x, `${width}/${state}: model overlaps action`);
      assert.ok(geometry.attachment.right <= geometry.model.x, `${width}/${state}: attachment overlaps model`);
      if (state !== "idle") {
        if (width < 640) assert.ok(geometry.bar.bottom <= geometry.attachment.y, `${width}/${state}: status overlaps controls`);
        else {
          assert.ok(Math.abs(geometry.bar.y + geometry.bar.height / 2 - geometry.attachment.y - geometry.attachment.height / 2) < 1, `${width}/${state}: desktop status not on control row`);
          assert.ok(geometry.bar.right <= geometry.context.x + 1, `${width}/${state}: desktop status overlaps context`);
        }
        assert.ok(geometry.statusHeight <= 20, `${width}/${state}: status wraps vertically`);
        assert.ok(geometry.job.right <= geometry.rail.right + 1, `${width}/${state}: job escapes rail`);
      } else {
        assert.equal(geometry.bar.height, 0, `${width}: empty status takes space`);
        assert.ok(geometry.rail.height <= 32, `${width}: idle rail gained a row`);
      }
      if (state === "running") {
        const trigger = page.getByTestId("job-work-status").getByRole("button");
        await trigger.focus();
        await page.keyboard.press("Enter");
        await page.getByTestId("job-work-popover").waitFor();
        await page.keyboard.press("Escape");
        await page.getByTestId("job-work-popover").waitFor({ state: "hidden" });
        // Radix restores focus after its exit animation unmounts the content.
        await page.waitForFunction(() => document.querySelector('[data-testid="job-work-status"] button') === document.activeElement);
        assert.equal(await trigger.evaluate(el => el === document.activeElement), true, "focus returns to task trigger");
      }
    }
    await page.locator(".aui-composer-input").fill("手机输入内容");
    assert.deepEqual(errors, []);
    await page.close();
    console.log(`composer layout ${width}px/${slug}: passed`);
  }
} finally {
  await browser.close();
}
