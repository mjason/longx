// The e2e suite's toolbox: a browser, the RPC the page uses (with its CSRF
// token), a scratch project on the server's disk, waiting for a turn, and
// the checks every page gets (console errors, horizontal overflow). Nothing
// here is mocked: it drives a running Longx (LONGX_E2E_URL, the dev server
// by default) with whatever model it is configured for (LONGX_E2E_MODEL).
import { chromium, devices } from "playwright";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { buildSchema, getNamedType, isEnumType, isListType, isNonNullType, isObjectType, isScalarType } from "graphql";

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

  /**
   * A call into the GraphQL API in the old RPC shape: `action` (snake_case),
   * `input` (the arguments), `fields` (the selection: names, or `{ parent:
   * [...] }` for a nested object — an object-typed field named bare, or no
   * list at all, reads every scalar of it), `extra.identity` (a record's id).
   * The document is built from this checkout's priv/schema.graphql; the
   * answer is the root field's value, a mutation's record unwrapped.
   */
  async rpc(action, input, fields, extra = {}) {
    const { document, field, wrapped } = gqlDocument(action, input ?? {}, fields, extra.identity);
    const r = await this.page.request.post(BASE + "/gql", {
      headers: { "x-csrf-token": this.csrf, "content-type": "application/json" },
      data: { query: document },
    });
    const text = await r.text();
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      throw new Error(`${action}: HTTP ${r.status()} ${text.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").slice(0, 300)}`);
    }
    if (json.errors?.length) throw new Error(`${action}: ${JSON.stringify(json.errors.map((e) => ({ message: e.message, fields: e.fields }))).slice(0, 400)}`);
    const value = json.data?.[field];
    // the keys inside a Json value come as the server keeps them: camelCase, like every typed field
    return deepCamel(wrapped && value && typeof value === "object" && "result" in value ? value.result : value);
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

// --- the GraphQL document of an RPC-shaped call (the schema of this checkout) ---
const SCHEMA = buildSchema(fs.readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), "../../../priv/schema.graphql"), "utf8"));
const RESOURCE_TYPES = new Set(["Project", "Thread", "Turn", "Provider", "Model", "SearchProvider", "Credential", "Watch"]);
const camel = (s) => s.replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase());
const snake = (s) => s.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
function deepKeys(value, rename) {
  if (Array.isArray(value)) return value.map((v) => deepKeys(v, rename));
  if (value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [rename(k), deepKeys(v, rename)]));
  }
  return value;
}
const deepCamel = (v) => deepKeys(v, camel);

export function gqlDocument(action, input, fields, identity) {
  const name = camel(action);
  let kind = "query";
  let field = SCHEMA.getQueryType()?.getFields()[name];
  if (!field) {
    kind = "mutation";
    field = SCHEMA.getMutationType()?.getFields()[name];
  }
  if (!field) throw new Error(`no GraphQL query or mutation named ${name}`);
  const argNames = field.args.map((a) => a.name);
  const rest = { ...input };
  const args = [];
  if (kind === "query") {
    for (const [k, v] of Object.entries(rest)) args.push([camel(k), literal(v)]);
  } else {
    if (argNames.includes("id")) {
      args.push(["id", literal(identity ?? rest.id)]);
      delete rest.id;
    }
    for (const a of argNames) if (a !== "id" && a !== "input" && a in rest) { args.push([a, literal(rest[a])]); delete rest[a]; }
    if (argNames.includes("input") && (Object.keys(rest).length > 0 || !argNames.includes("id"))) args.push(["input", object(rest)]);
  }
  const named = getNamedType(field.type);
  const wrapped = kind === "mutation" && isObjectType(named) && /Result$/.test(named.name) && "result" in named.getFields();
  const sel = wrapped ? ` { result${selection(fields, named.getFields().result.type, 0)} }` : selection(fields, field.type, 0);
  const argText = args.length ? `(${args.map(([k, v]) => `${k}: ${v}`).join(", ")})` : "";
  return { document: `${kind} { ${name}${argText}${sel} }`, field: name, wrapped };
}

function object(map) {
  return `{${Object.entries(map).map(([k, v]) => `${camel(k)}: ${literal(v)}`).join(", ")}}`;
}

// a nested map is a Json scalar, which reads a JSON string
function literal(v) {
  if (v === null || v === undefined) return "null";
  if (typeof v === "boolean" || typeof v === "number") return String(v);
  if (typeof v === "string") return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(literal).join(", ")}]`;
  return JSON.stringify(JSON.stringify(deepKeys(v, snake)));
}

function selection(fields, type, depth) {
  const named = getNamedType(type);
  if (!isObjectType(named) || depth > 5) return "";
  const all = Object.values(named.getFields());
  const wanted = fields && fields.length ? fields : all.filter((f) => !RESOURCE_TYPES.has(getNamedType(f.type).name)).map((f) => f.name);
  const parts = [];
  for (const w of wanted) {
    if (typeof w === "object") {
      for (const [k, sub] of Object.entries(w)) parts.push(camel(k) + selection(sub, fieldOf(named, k).type, depth + 1));
    } else {
      const f = fieldOf(named, w);
      const inner = getNamedType(f.type);
      parts.push(camel(w) + (isScalarType(inner) || isEnumType(inner) ? "" : selection(null, f.type, depth + 1)));
    }
  }
  return ` { ${parts.join(" ")} }`;
}

function fieldOf(objType, name) {
  const wanted = camel(name);
  const f = Object.values(objType.getFields()).find((x) => x.name === wanted);
  if (!f) throw new Error(`no field ${name} on ${objType.name}`);
  return f;
}

// unused imports kept for a reader of the schema helpers
void isListType;
void isNonNullType;

