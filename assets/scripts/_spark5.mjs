import { chromium } from "playwright";
const base = "http://192.168.2.70:7788";
const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: 1280, height: 900 } });
const wait = async (max = 400) => { for (let i = 0; i < max; i++) { await p.waitForTimeout(1000); const t = await p.locator("body").innerText(); if (!/turn 进行中|正在运行|思考中/.test(t) && i > 3) return; } };
// project default: network on (new threads); this thread: the mode picker for the next turn
await p.goto(base + "/p/jbt-lab/settings"); await p.waitForTimeout(2500);
const sw = p.getByRole("switch", { name: /允许联网/ }); if (!(await sw.isChecked())) await sw.click();
await p.getByRole("button", { name: "保存" }).click(); await p.waitForTimeout(1500); console.log("project network:", await sw.isChecked());
await p.goto(base + "/p/jbt-lab/t/01a0a2e9-d00e-77a7-b425-e0ff0a07bbfb"); await p.waitForTimeout(3000);
await p.getByTestId("turn-bar").getByRole("button").first().click(); await p.waitForTimeout(500);
const net = p.getByRole("switch", { name: /联网|网络/ }).first(); if (!(await net.isChecked())) await net.click(); console.log("thread network:", await net.isChecked());
await p.keyboard.press("Escape"); await p.waitForTimeout(300);
await p.getByRole("textbox").first().fill("在沙箱里只运行 uv run jbt run 小市值 --backend cuda 2>&1 | grep -v '^  ' | head -20，原样贴出，不要分析"); await p.keyboard.press("Enter"); await wait();
for (const el of await p.locator("button[aria-expanded=false]").all()) { try { await el.click({ timeout: 300 }); } catch {} }
const t = await p.locator("[data-testid=chat-area]").innerText(); const i = t.lastIndexOf("在沙箱里只运行 uv run jbt run 小市值 --backend cuda 2>&1 | grep"); console.log(t.slice(i, i + 1500));
console.log("mode:", (await p.getByTestId("turn-bar").innerText()).replace(/\n/g, " | "));
await b.close();
