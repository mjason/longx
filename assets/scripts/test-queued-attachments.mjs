// Actual runtime + assistant-ui in Chromium, with only the server boundary
// stubbed. No projects, turns or files are written to a running Longx.
import assert from "node:assert/strict";
import { build } from "esbuild";
import { chromium } from "playwright";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const exports = [...(await readFile(path.join(root, "js/core/api.ts"), "utf8")).matchAll(/export const (\w+):/g)].map(m => m[1]);
const bundle = await build({
  absWorkingDir: root,
  stdin: {
    resolveDir: root, loader: "tsx",
    contents: `
      import React from "react";
      import { createRoot } from "react-dom/client";
      import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
      import { AssistantRuntimeProvider, ComposerPrimitive, ThreadPrimitive } from "@assistant-ui/react";
      import { useLongxRuntime } from "./js/core/chat/runtime";
      import { MessageQueue } from "./js/ui/components/assistant-ui/elements/message-queue";
      const row = {id:"t1", kernelThreadId:"thr_1", title:"working", status:"active"};
      window.calls = [];
      window.failSend = false;
      window.notRunning = false;
      window.api = async (name, args) => {
        if (name === "steerTurn" || name === "sendMessage") {
          window.calls.push({ name, input: args.input });
          if ((name === "steerTurn" && window.notRunning) || (name === "sendMessage" && window.failSend))
            return {success:false,errors:[{message:name==="steerTurn"?"not_running":"unavailable",fields:[]}]};
          if (window.hold) await new Promise(resolve => { window.finish = resolve; });
        }
        const data = name === "listThreads" ? [row] : name === "getThread" ? row :
          name === "listRunningThreads" ? {threads:[],finished:[]} :
          name === "agentDefinition" ? {model:null,effort:null} : [];
        return {success:true,data};
      };
      window.fetch = async () => new Response(JSON.stringify({path:"/server/data.zip",name:"data.zip",bytes:4}),{status:200});
      function App() {
        const chat = useLongxRuntime({projectId:"p1",threadId:"t1",onOpenThread:()=>{}});
        window.chat = chat;
        return <AssistantRuntimeProvider runtime={chat.runtime}>
          <ThreadPrimitive.Root>
            <div data-testid="ready">{chat.thread && chat.ready ? "ready" : "loading"}</div>
            <MessageQueue onInsert={id => void chat.insertQueued(id)} insertLabel="插入" removeLabel="取消" hint="队列"/>
            <div data-testid="echoes">{chat.echoes.map(e => <div key={e.id}>
              <span>{e.text}</span>{e.images.map((src,i)=><img key={i} src={src} width="60"/>)}<span>{e.error}</span>
            </div>)}</div>
            <ComposerPrimitive.Root>
              <ComposerPrimitive.Input aria-label="draft"/>
              <ComposerPrimitive.Send>加入队列</ComposerPrimitive.Send>
            </ComposerPrimitive.Root>
          </ThreadPrimitive.Root>
        </AssistantRuntimeProvider>;
      }
      createRoot(document.getElementById("root")).render(
        <QueryClientProvider client={new QueryClient({defaultOptions:{queries:{retry:false}}})}><App/></QueryClientProvider>
      );
    `,
  },
  bundle: true, write: false, format: "iife",
  define: { "process.env.NODE_ENV": '"production"', "import.meta.env.PROD": "false", "import.meta.env.DEV": "false", "import.meta.env.MODE": '"production"' },
  plugins: [{
    name: "server-boundary",
    setup(builder) {
      builder.onLoad({ filter: /\/js\/core\/api\.ts$/ }, () => ({
        contents: exports.map(name => `export const ${name} = args => window.api("${name}", args);`).join("\n"), loader: "js",
      }));
      builder.onLoad({ filter: /\/js\/core\/chat\/useThreadView\.ts$/ }, () => ({
        contents: `
          import { fromSnapshot } from "./thread";
          const view=fromSnapshot({thread_id:"thr_1",seq:1,thread:{id:"thr_1"},turn:{id:"turn_1",status:"inProgress"},
            items:[{id:"u1",type:"userMessage",turnId:"turn_1",content:[{type:"text",text:"working"}]}],pending_requests:[]});
          export const useThreadView=()=>({view,ready:true,error:null,refetch:async()=>{},loadEarlier:async()=>{}});
        `, loader: "js",
      }));
    },
  }],
});
const browser = await chromium.launch();
try {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.setContent('<div id="root"></div>');
  await page.addScriptTag({ content: bundle.outputFiles[0].text });
  await page.getByTestId("ready").filter({ hasText: "ready" }).waitFor({ timeout: 5000 }).catch(error => {
    throw new Error(`${error.message}\nPage errors: ${errors.join("\n")}`);
  });
  async function attach(kind) {
    await page.evaluate(async kind => {
      const file = kind === "image"
        ? new File([Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1ioAAAAASUVORK5CYII="), c => c.charCodeAt(0))], "shot.png", {type:"image/png"})
        : kind === "inline"
          ? new File(["inline notes"], "notes.txt", {type:"text/plain"})
          : new File([new Uint8Array([80,75,3,4])], "data.zip", {type:"application/zip"});
      await window.chat.runtime.thread.composer.addAttachment(file);
    }, kind);
  }
  await attach("image");
  await page.getByRole("button", { name: "加入队列" }).click();
  await page.evaluate(() => { window.hold = true; });
  await page.getByRole("button", { name: "插入" }).click();
  await page.waitForFunction(() => window.calls.length === 1);
  const first = await page.evaluate(() => window.calls[0]);
  assert.equal(first.input.text, "");
  assert.ok(Array.isArray(first.input.images), "image-only insertion must include images in the RPC payload");
  assert.match(first.input.images[0], /^data:image\/png;base64,/);
  await page.getByTestId("message-queue").waitFor();
  await page.getByTestId("echoes").locator("img").waitFor();
  await page.evaluate(() => { window.hold = false; window.finish(); });
  await page.getByTestId("message-queue").waitFor({ state: "hidden" });

  await attach("inline");
  await attach("file");
  await page.getByRole("textbox", { name: "draft" }).fill('look @session("other:main")');
  await page.getByRole("button", { name: "加入队列" }).click();
  await page.evaluate(() => { window.notRunning = true; window.failSend = true; });
  await page.getByRole("button", { name: "插入" }).click();
  await page.getByText("unavailable", { exact: true }).waitFor();
  await page.getByTestId("message-queue").waitFor();
  const fallback = await page.evaluate(() => window.calls.at(-1));
  assert.equal(fallback.name, "sendMessage");
  assert.match(fallback.input.text, /inline notes/);
  assert.match(fallback.input.text, /path="\/server\/data.zip"/);
  assert.match(fallback.input.text, /成果接收会话/);
  await page.evaluate(() => { window.failSend = false; });
  await page.getByRole("button", { name: "插入" }).click();
  await page.getByTestId("message-queue").waitFor({ state: "hidden" });
  assert.equal(await page.evaluate(() => window.calls.at(-1).input.text), fallback.input.text);
  assert.deepEqual(errors, []);
  console.log("queued attachments browser: image-only steer/echo, inline+uploaded file, session instructions, fallback failure and retry passed");
} finally {
  await browser.close();
}
