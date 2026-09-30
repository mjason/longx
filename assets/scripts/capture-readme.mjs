// Capture sanitized, reproducible README media from a local Longx server.
// Uses an isolated temp project and removes it when done; no model/provider is needed.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, devices } from "playwright";
import { gqlDocument, sleep } from "./e2e/lib.mjs";

const base = (process.env.LONGX_README_URL || "http://127.0.0.1:7798").replace(/\/$/, "");
const media = fileURLToPath(new URL("../../docs/media/", import.meta.url));
fs.mkdirSync(media, { recursive: true });
const projectRoot = fs.mkdtempSync("/tmp/longx-readme-demo-");
const recordingRoot = fs.mkdtempSync(path.join(os.tmpdir(), "longx-readme-video-"));
fs.mkdirSync(path.join(projectRoot, "src"));
fs.writeFileSync(
  path.join(projectRoot, "README.md"),
  "# Notes App\n\nA tiny demo project used for the Longx README.\n\n- Browse files\n- Ask an agent to make a change\n",
);
fs.writeFileSync(
  path.join(projectRoot, "src", "app.js"),
  'export function greet(name = "world") {\n  return `Hello, ${name}!`;\n}\n',
);

let projectId;
let browser;
let context;
let mobileContext;
let page;

async function rpc(action, input, fields, csrf, identity) {
  const { document, field, wrapped } = gqlDocument(action, input, fields, identity);
  const response = await page.request.post(`${base}/gql`, {
    headers: { "x-csrf-token": csrf, "content-type": "application/json" },
    data: { query: document },
  });
  const json = await response.json();
  if (!response.ok() || json.errors?.length) {
    throw new Error(`${action}: ${JSON.stringify(json.errors ?? json)}`);
  }
  const value = json.data[field];
  return wrapped && value && "result" in value ? value.result : value;
}

try {
  browser = await chromium.launch();
  context = await browser.newContext({
    viewport: { width: 1440, height: 960 },
    colorScheme: "light",
    recordVideo: { dir: recordingRoot, size: { width: 1440, height: 960 } },
  });
  page = await context.newPage();
  await page.goto(`${base}/`, { waitUntil: "networkidle" });
  await page.waitForTimeout(1200);
  const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content");
  const project = await rpc(
    "create_project",
    { name: "Longx Demo", rootPath: projectRoot, initGit: false },
    ["id", "slug"],
    csrf,
  );
  projectId = project.id;
  await page.reload({ waitUntil: "networkidle" });
  await page.waitForTimeout(1200);
  await page.screenshot({ path: path.join(media, "welcome.png") });

  const video = page.video();
  await page.getByRole("link", { name: /Longx Demo/ }).click();
  await page.waitForTimeout(1800);
  await page.goto(`${base}/p/${project.slug}`, { waitUntil: "networkidle" });
  await page.waitForTimeout(1800);
  await page.screenshot({ path: path.join(media, "session.png") });

  await page.keyboard.press("ControlOrMeta+4");
  await page.getByRole("treeitem", { name: "README.md", exact: true }).waitFor({ timeout: 10000 });
  await page.waitForTimeout(900);
  await page.screenshot({ path: path.join(media, "files.png") });
  await page.getByRole("treeitem", { name: "README.md", exact: true }).click();
  await page.waitForTimeout(1100);
  await page.screenshot({ path: path.join(media, "file-preview.png") });
  await sleep(500);

  const mobile = await browser.newContext({
    ...devices["iPhone 13"],
    colorScheme: "light",
    recordVideo: { dir: recordingRoot, size: { width: 390, height: 844 } },
  });
  mobileContext = mobile;
  const mobilePage = await mobile.newPage();
  await mobilePage.goto(`${base}/`, { waitUntil: "networkidle" });
  await mobilePage.waitForTimeout(900);
  await mobilePage.screenshot({ path: path.join(media, "welcome-mobile.png") });
  const mobileVideo = mobilePage.video();
  await mobilePage.getByRole("link", { name: /Longx Demo/ }).click();
  await mobilePage.waitForTimeout(1600);
  await mobilePage.screenshot({ path: path.join(media, "session-mobile.png") });
  await mobile.close();
  mobileContext = undefined;
  await mobileVideo.saveAs(path.join(media, "tour-mobile.webm"));

  await rpc("delete_project", { confirm: true }, undefined, csrf, projectId);
  projectId = undefined;
  fs.rmSync(projectRoot, { recursive: true, force: true });
  await context.close();
  context = undefined;
  await video.saveAs(path.join(media, "tour.webm"));
  fs.rmSync(recordingRoot, { recursive: true, force: true });
  console.log(`README media saved under ${media}`);
} finally {
  if (projectId && page) {
    const csrf = await page.locator('meta[name="csrf-token"]').getAttribute("content").catch(() => null);
    if (csrf) await rpc("delete_project", { confirm: true }, undefined, csrf, projectId).catch(() => {});
  }
  fs.rmSync(projectRoot, { recursive: true, force: true });
  fs.rmSync(recordingRoot, { recursive: true, force: true });
  await mobileContext?.close().catch(() => {});
  await context?.close().catch(() => {});
  await browser?.close().catch(() => {});
}
