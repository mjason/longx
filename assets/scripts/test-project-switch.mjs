// Actual project-navigation components with a tiny in-memory API fixture.
// No server projects are created and no real workspace is modified.
import assert from "node:assert/strict";
import { build } from "esbuild";
import { chromium } from "playwright";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const apiPath = path.join(root, "js/core/api.ts");
const exports = [...(await readFile(apiPath, "utf8")).matchAll(/export const (\w+):/g)].map(m => m[1]);
const bundle = await build({
  absWorkingDir: root,
  stdin: {
    resolveDir: root,
    loader: "tsx",
    contents: `
      import React from "react";
      import { createRoot } from "react-dom/client";
      import { createMemoryRouter, RouterProvider, Outlet, useParams } from "react-router";
      import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
      import { I18nextProvider } from "react-i18next";
      import i18n from "./js/core/i18n";
      import { WelcomePage } from "./js/ui/pages/WelcomePage";
      import { ProjectSwitcher, ProjectPicker } from "./js/ui/frame/ProjectSwitcher";
      import { TooltipProvider } from "./js/ui/components/ui/tooltip";
      void i18n.changeLanguage("zh-CN");
      window.projects = [1,2,3,4].map(n => ({
        id: "id-"+n, slug: "app-"+n, name: "项目 "+n,
        pinned: n===2, rootPath: "/workspace/app-"+n,
        updatedAt: "2026-10-04T00:00:00Z"
      }));
      window.activity = [{id:"t3", projectId:"id-3", waiting:true}];
      window.api = async (name, args) => {
        let data;
        if(name==="listProjects") data=window.projects;
        else if(name==="listRunningThreads") data={threads:window.activity, finished:[]};
        else if(name==="updateProject") {
          const row=window.projects.find(p=>p.id===args.identity);
          Object.assign(row,args.input);
          data={...row};
        } else data=[];
        return {success:true,data:structuredClone(data)};
      };
      function Workspace() {
        const {slug}=useParams();
        const current=window.projects.find(p=>p.slug===slug);
        return <div className="flex h-dvh flex-col">
          <ProjectSwitcher current={current}/>
          <main className="flex-1 p-8">工作区测试夹具：{current.name}</main>
        </div>;
      }
      const client=window.client=new QueryClient({defaultOptions:{queries:{retry:false}}});
      const router=window.router=createMemoryRouter([{
        element:<TooltipProvider><Outlet/><ProjectPicker/></TooltipProvider>,
        children:[{path:"/",element:<WelcomePage/>},{path:"/p/:slug",element:<Workspace/>}]
      }],{initialEntries:["/p/app-1"]});
      createRoot(document.getElementById("root")).render(
        <I18nextProvider i18n={i18n}><QueryClientProvider client={client}>
          <RouterProvider router={router}/>
        </QueryClientProvider></I18nextProvider>
      );
    `,
  },
  bundle: true,
  write: false,
  format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false" },
  plugins: [{
    name: "in-memory-api",
    setup(builder) {
      builder.onLoad({ filter: /\/js\/core\/api\.ts$/ }, () => ({
        contents: exports.map(name => `export const ${name} = args => window.api("${name}", args);`).join("\n"),
        loader: "js",
      }));
    },
  }],
});
const manifest = JSON.parse(await readFile(path.join(root, "../priv/static/assets/.vite/manifest.json"), "utf8"));
const cssFile = manifest["js/index.tsx"]?.css?.[0];
assert.ok(cssFile, "build the frontend first so the real Tailwind styles are tested");
const css = await readFile(path.join(root, "../priv/static/assets", cssFile), "utf8");
const browser = await chromium.launch();
try {
  for (const width of [1280, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 800 } });
    page.setDefaultTimeout(5000);
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.setContent('<div id="root"></div>');
    await page.addStyleTag({ content: css });
    await page.addScriptTag({ content: bundle.outputFiles[0].text });
    const bar = page.getByTestId("project-switcher");
    await bar.waitFor();
    if (width === 1280) {
      await page.waitForFunction(() => document.querySelectorAll('[data-testid="project-switcher"] a').length === 3);
      assert.deepEqual(await bar.getByRole("link").allTextContents(), ["项目 1", "项目 2", "项目 3● 1"]);
      await page.evaluate(async () => { window.activity=[]; await window.client.invalidateQueries({queryKey:["running-threads"]}); });
      await page.waitForFunction(() => document.querySelectorAll('[data-testid="project-switcher"] a').length === 2);
    } else {
      assert.equal(await bar.getByRole("link").count(), 0);
    }
    await bar.getByRole("button", { name: "全部项目" }).click();
    const picker = page.getByRole("dialog", { name: "全部项目" });
    await picker.waitFor();
    if (width === 390) await page.getByTestId("project-picker-sheet").waitFor();
    await picker.getByRole("combobox").fill("/workspace/app-4");
    await page.waitForFunction(() => document.querySelectorAll('[cmdk-item]:not([hidden])').length === 1);
    await picker.getByRole("option").click();
    await page.waitForFunction(() => window.router.state.location.pathname === "/p/app-4");
    await page.evaluate(() => window.router.navigate("/"));
    const pin = page.getByRole("button", { name: "固定项目 项目 1" });
    await pin.waitFor();
    const card = pin.locator("..");
    const bounds = await card.evaluate(el => {
      const card = el.getBoundingClientRect();
      const link = el.querySelector("a").getBoundingClientRect();
      return { cardRight: card.right, linkRight: link.right };
    });
    assert.ok(Math.abs(bounds.cardRight - bounds.linkRight) <= 2, "link covers the full card, including beneath the pin");
    if (width === 1280) {
      await card.getByRole("link").hover();
      await card.evaluate(async el => {
        await Promise.all(el.getAnimations({ subtree: true }).map(animation => animation.finished.catch(() => {})));
      });
      const background = await card.evaluate(el => getComputedStyle(el).backgroundColor);
      await pin.hover();
      await card.evaluate(async el => {
        await Promise.all(el.getAnimations({ subtree: true }).map(animation => animation.finished.catch(() => {})));
      });
      const styles = await card.evaluate(el => ({
        card: getComputedStyle(el).backgroundColor,
        link: getComputedStyle(el.querySelector("a")).backgroundColor,
        pin: getComputedStyle(el.querySelector("button")).backgroundColor,
      }));
      assert.equal(styles.card, background, "same card hover background over link and pin");
      assert.equal(styles.link, "rgba(0, 0, 0, 0)", "link has no separate background");
      assert.equal(styles.pin, "rgba(0, 0, 0, 0)", "pin is an icon without a button surface");
    }
    await page.getByRole("button", { name: "固定项目 项目 1" }).click();
    await page.getByRole("button", { name: "取消固定 项目 1" }).waitFor();
    assert.equal(await page.evaluate(() => window.router.state.location.pathname), "/");
    await page.getByRole("button", { name: "取消固定 项目 1" }).click();
    await page.getByRole("button", { name: "固定项目 项目 1" }).waitFor();
    assert.equal(await page.evaluate(() => window.projects.find(p => p.id==="id-1").pinned), false);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), `no horizontal page overflow at ${width}`);
    assert.deepEqual(errors, []);
    console.log(`project switching ${width}px: ordering, activity cleanup, path search, home pin/unpin passed`);
    await page.close();
  }
} finally { await browser.close(); }
