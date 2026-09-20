// The e2e suite's toolbox: a browser, the RPC the page uses (with its CSRF
// token), a scratch project on the server's disk, waiting for a turn, and
// the checks every page gets (console errors, horizontal overflow). Nothing
// here is mocked: it drives a running Longx (LONGX_E2E_URL, the dev server
// by default) with whatever model it is configured for (LONGX_E2E_MODEL).
import { chromium, devices } from "playwright";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const BASE = (process.env.LONGX_E2E_URL || "http://127.0.0.1:7798").replace(/\/$/, "");
export const MODEL = process.env.LONGX_E2E_MODEL || null;
export const OUT = path.join(path.dirname(new URL(import.meta.url).pathname), "out");
fs.mkdirSync(OUT, { recursive: true });

export class Harness {
  constructor(name) {
    this.name = name;
    this.problems = [];
  }

  async start() {
    this.browser = await chromium.launch();
    this.context = await this.browser.newContext({ viewport: { width: 1280, height: 900 } });
    this.page = await this.watch(await this.context.newPage());
    await this.page.goto(BASE + "/");
    this.csrf = await this.page.getAttribute('meta[name="csrf-token"]', "content");
    return this;
  }

  async stop() {
    await this.browser?.close();
  }

  // console errors and page errors on every page this harness opens
  async watch(page) {
    page.on("console", (m) => {
      if (m.type() === "error") this.problems.push(`console: ${m.text()}`);
    });
    page.on("pageerror", (e) => this.problems.push(`pageerror: ${e.message}`));
    return page;
  }

  async phone() {
    const context = await this.browser.newContext({ ...devices["iPhone 13"], colorScheme: "dark" });
    return this.watch(await context.newPage());
  }

  async rpc(action, input, fields, extra = {}) {
    const r = await this.page.request.post(BASE + "/rpc/run", {
      headers: { "x-csrf-token": this.csrf, "content-type": "application/json" },
      data: { action, input, ...(fields ? { fields } : {}), ...extra },
    });
    const text = await r.text();
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      throw new Error(`${action}: HTTP ${r.status()} ${text.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").slice(0, 300)}`);
    }
    if (!json.success) throw new Error(`${action}: ${JSON.stringify(json.errors).slice(0, 400)}`);
    return json.data;
  }

  // a project of its own on the server's disk (the same machine as this script)
  async project() {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "longx-e2e-"));
    const p = await this.rpc("create_project", { name: `e2e ${this.name}`, rootPath: root, initGit: false }, ["id", "slug", "rootPath"]);
    this.projectId = p.id;
    this.slug = p.slug;
    this.root = root;
    return p;
  }

  async cleanup() {
    if (this.projectId && !process.env.LONGX_E2E_KEEP) {
      await this.rpc("delete_project", { confirm: true }, undefined, { identity: this.projectId }).catch((e) => this.problems.push(`cleanup: ${e.message}`));
      fs.rmSync(this.root, { recursive: true, force: true });
    }
  }

  async thread(opts = {}) {
    return this.rpc("start_thread", { projectId: this.projectId, ...(MODEL ? { model: MODEL } : {}), ...opts }, ["id", "kernelThreadId"]);
  }

  async send(threadId, text) {
    return this.rpc("send_message", { threadId, text }, ["id", "kernelTurnId", "status"]);
  }

  // the thread idle again — no turn in progress and the row not active —
  // within `ms`; the turns as they ended. `atLeast` turns must exist first
  // (a message sent from the composer lands a moment after the keypress)
  async idle(threadId, ms = 180_000, atLeast = 1) {
    const until = Date.now() + ms;
    while (Date.now() < until) {
      const turns = await this.rpc("list_turns", { threadId }, ["id", "kernelTurnId", "status", "error", "userText"]);
      const t = await this.rpc("get_thread", { id: threadId }, ["id", "status"]);
      if (turns.length >= atLeast && t.status !== "active" && !turns.some((x) => x.status === "in_progress")) return turns;
      await sleep(1500);
    }
    throw new Error(`thread ${threadId} still active after ${ms} ms`);
  }

  async open(page, pathname) {
    await page.goto(BASE + pathname, { waitUntil: "networkidle" });
    await page.waitForTimeout(1500);
  }

  // nothing wider than the viewport: the page never scrolls sideways
  async noOverflow(page, label) {
    const wide = await page.evaluate(() =>
      [...document.querySelectorAll("*")]
        .filter((el) => el.getBoundingClientRect().right > document.documentElement.clientWidth + 1)
        .slice(0, 5)
        .map((el) => `${el.tagName.toLowerCase()}.${[...el.classList].slice(0, 3).join(".")} right=${Math.round(el.getBoundingClientRect().right)}`),
    );
    if (wide.length) this.problems.push(`${label}: wider than the viewport: ${wide.join(", ")}`);
  }

  async shot(page, name) {
    await page.screenshot({ path: path.join(OUT, `${this.name}-${name}.png`), fullPage: true });
  }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function expect(cond, message) {
  if (!cond) throw new Error(message);
}
