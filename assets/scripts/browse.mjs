// Dev helper: load a page as a phone (or desktop), report console errors,
// page errors, horizontal overflow, and save a screenshot.
//   node scripts/browse.mjs http://127.0.0.1:7798/ [phone|desktop] [out.png]
import { chromium, devices } from "playwright";

const [url = "http://127.0.0.1:7798/", mode = "phone", out = "shot.png"] = process.argv.slice(2);
const browser = await chromium.launch();
const context = await browser.newContext(
  mode === "phone" ? { ...devices["iPhone 13"], colorScheme: "dark" } : { viewport: { width: 1280, height: 800 } },
);
const page = await context.newPage();
const problems = [];
page.on("console", (m) => { if (["error", "warning"].includes(m.type())) problems.push(`${m.type()}: ${m.text()}`); });
page.on("pageerror", (e) => problems.push(`pageerror: ${e.message}`));
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForTimeout(3000);
const overflow = await page.evaluate(() => ({
  scrollWidth: document.documentElement.scrollWidth,
  clientWidth: document.documentElement.clientWidth,
  wide: [...document.querySelectorAll("*")]
    .filter((el) => el.getBoundingClientRect().right > document.documentElement.clientWidth + 1)
    .slice(0, 5)
    .map((el) => `${el.tagName.toLowerCase()}.${[...el.classList].slice(0, 3).join(".")} right=${Math.round(el.getBoundingClientRect().right)}`),
}));
await page.screenshot({ path: out, fullPage: false });
console.log(JSON.stringify({ url, mode, title: await page.title(), overflow, problems }, null, 2));
await browser.close();
