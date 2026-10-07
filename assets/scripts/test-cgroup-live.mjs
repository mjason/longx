// Real Phoenix/GraphQL/kernel/tools/native/status-page E2E.
// The only simulated boundary is the loopback Responses model. No page/API routes
// or task reports are intercepted. The coordinator starts the isolated server.
// node scripts/test-cgroup-live.mjs <scoped run directory>/runner.json
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomBytes } from "node:crypto";

const projectRoot = fileURLToPath(new URL("../..", import.meta.url));
const artifacts = path.join(projectRoot, ".longx/local/artifacts");
const metadataPath = path.resolve(process.argv[2] || process.env.LONGX_CGROUP_E2E_METADATA || "");
const runRelative = path.relative(artifacts, path.dirname(metadataPath));
assert.ok(/^(?:cgroup-live-e2e\/[^/]+(?:\/(?:delegated|nondelegated|plain|unavailable))?|cgroup-live-e2e-[A-Za-z0-9]+\/[ABab])$/.test(runRelative),
  "explicit isolated runner metadata is required");
const meta = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
assert.equal(meta.test_only, true);
assert.equal(path.join(meta.root, "runner.json"), metadataPath);
assert.equal(meta.project.root_path, path.join(meta.root, "project"));
assert.equal(meta.evidence_dir, path.join(meta.root, "evidence"));
assert.equal(new URL(meta.url).hostname, "127.0.0.1");
assert.equal(new URL(meta.model_url).hostname, "127.0.0.1");
assert.equal(meta.model, "cgroup-e2e");
assert.ok(["eligible", "unavailable"].includes(meta.expected_capability));
const identity = await fetch(meta.model_url + "/identity").then(response => response.json());
assert.equal(identity.run_id, meta.run_id, "do not write settings before proving isolated runner identity");

process.env.LONGX_E2E_URL = meta.url;
process.env.LONGX_E2E_MODEL = meta.model;
const { Harness } = await import("./e2e/lib.mjs");
const h = new Harness("cgroup-live");
const results = [];
const suffix = randomBytes(4).toString("hex");
const fields = [
  "mode", "capability", "reason", "path", "activeTasks", "cleanupPendingTasks",
  "lastTaskStatus", "lastTaskPath", "lastPopulated", "lastCleanupError", "lastObservedAt", "checkedAt",
];

async function waitForValue(read, expected, timeout = 10_000) {
  const deadline = Date.now() + timeout;
  let actual;
  do {
    actual = await read();
    if (Object.is(actual, expected)) return;
    await new Promise(resolve => setTimeout(resolve, 250));
  } while (Date.now() < deadline);
  assert.equal(actual, expected, `value did not settle within ${timeout}ms`);
}

async function status(project = false) {
  return h.rpc("command_guard_status", project ? { projectId: meta.project.id } : {}, fields);
}

async function saveGlobal(mode) {
  await h.page.goto(meta.url + "/settings/agent");
  const form = h.page.getByTestId("agent-settings");
  await form.getByLabel("任务 cgroup 保护").waitFor();
  await form.getByLabel("任务 cgroup 保护").click();
  await h.page.getByRole("option", { name: { auto: "自动", off: "关闭", required: "必须启用" }[mode], exact: true }).click();
  const saved = h.page.waitForResponse(response => response.url() === meta.url + "/gql"
    && response.request().postData()?.includes("mutation SetAgentSettings"));
  await form.getByRole("button", { name: "保存", exact: true }).click();
  assert.equal((await saved).status(), 200);
  const settings = await h.rpc("agent_settings", {}, ["commandCgroupMode"]);
  assert.equal(settings.commandCgroupMode, mode, "actual stored global mode");
  await waitForValue(async () => (await status()).mode, mode);
}

async function saveProject(mode) {
  await h.page.goto(meta.url + `/p/${meta.project.slug}/settings`);
  const form = h.page.getByTestId("project-agent-overrides");
  await form.getByLabel("任务 cgroup 保护").waitFor();
  await form.getByLabel("任务 cgroup 保护").click();
  const name = mode === null ? "沿用 auto" : { auto: "自动", off: "关闭", required: "必须启用" }[mode];
  await h.page.getByRole("option", { name, exact: true }).click();
  const saved = h.page.waitForResponse(response => response.url() === meta.url + "/gql"
    && response.request().postData()?.includes("mutation UpdateProject"));
  await h.page.getByRole("button", { name: "保存", exact: true }).click();
  assert.equal((await saved).status(), 200);
  const project = await h.rpc("get_project", { slug: meta.project.slug }, [{ agentSettings: ["commandCgroupMode"] }]);
  assert.equal(project.agentSettings?.commandCgroupMode ?? null, mode, "actual stored project override");
  assert.equal((await status(true)).mode, mode ?? "auto");
}

async function threadItems(thread) {
  const response = await h.page.request.get(meta.url + `/api/p/${meta.project.slug}/t/${thread.id}?turns=1`);
  assert.equal(response.status(), 200);
  const report = await response.json();
  return report.turns.list.flatMap(turn => turn.items);
}

async function task({ width, phase, kind = "exec", protectedTask = false, denied = false, project = false, fallback = false }) {
  const token = `${phase}-${width}-${suffix}`;
  const evidence = path.join(meta.evidence_dir, token);
  const thread = await h.thread({ model: meta.model });
  const before = await status(project);
  await h.send(thread.id, `CGROUP_E2E ${kind} ${token}`);
  const card = h.page.getByTestId("command-guard-status");
  const record = { width, phase, kind, threadId: thread.id, before };
  try {
    if (denied) {
      await h.idle(thread.id, 30_000);
      assert.equal(fs.existsSync(evidence + ".started"), false, "required must refuse before payload starts");
      assert.equal(fs.existsSync(evidence + ".membership"), false);
      const items = await threadItems(thread);
      const refused = kind === "exec"
        ? items.find(item => item.type === "commandExecution")
        : items.find(item => item.type === "dynamicToolCall" && item.tool === "start_job");
      assert.ok(refused, "the real requested tool must have been attempted");
      assert.equal(refused.status, "failed", "tool refusal, not a model failure or a user marker");
      if (kind === "job") assert.equal(refused.success, false);
      const denial = kind === "exec" ? refused.aggregatedOutput
        : refused.contentItems.map(item => item.text ?? "").join("\n");
      assert.match(denial, /cgroup.*(unavailable|required|delegat)|(?:unavailable|required|delegat).*cgroup/is);
      await card.getByText("当前不可用").waitFor();
      assert.equal((await status(project)).activeTasks, 0);
      record.items = items;
      record.denialOutput = denial;
      record.deniedBeforePayload = true;
    } else {
      await waitForValue(() => fs.existsSync(evidence + ".started"), true, 15_000);
      const membership = fs.readFileSync(evidence + ".membership", "utf8").trim();
      record.membership = membership;
      if (protectedTask) {
        assert.notEqual(membership, meta.server_membership);
        assert.match(membership, /\/tasks\/job-/);
        // No cache invalidation or page reload after starting: actual query polling.
        await card.getByText("当前已确认启用保护的任务：1").waitFor({ timeout: 12_000 });
        const active = await status(project);
        assert.equal(active.lastTaskStatus, "active");
        assert.equal(active.activeTasks, 1);
        assert.equal(active.cleanupPendingTasks, 0);
        assert.notEqual(active.lastObservedAt, before.lastObservedAt);
        assert.ok(active.lastTaskPath.includes("/tasks/job-"));
        record.active = active;
      } else {
        assert.equal(membership, meta.server_membership, "unprotected payload stays in the server's inherited group");
        assert.equal((await status(project)).activeTasks, 0);
        if (fallback) {
          assert.equal((await status(project)).lastTaskStatus, "unavailable");
          await card.getByText("启动时已降级").waitFor({ timeout: 12_000 });
        } else {
          await card.getByText("已关闭；未执行检测").waitFor();
        }
      }
      await card.screenshot({ path: path.join(meta.root, `${phase}-${width}-active.png`) });
      fs.writeFileSync(evidence + ".release", "");
      await h.idle(thread.id, 30_000);
      if (kind === "job") {
        await waitForValue(async () => {
          const jobs = await h.rpc("project_jobs", { projectId: meta.project.id }, ["jobs"]);
          return jobs.jobs.find(job => job.name === token)?.status;
        }, "exited", 15_000);
      }
      await card.getByText("当前已确认启用保护的任务：0").waitFor({ timeout: 12_000 });
      const finished = await status(project);
      assert.equal(finished.activeTasks, 0);
      assert.equal(finished.cleanupPendingTasks, 0);
      if (protectedTask) {
        assert.equal(finished.lastTaskPath, record.active.lastTaskPath);
        assert.equal(finished.lastPopulated, false, "actual native cleanup report");
        assert.ok([null, ""].includes(finished.lastCleanupError));
      }
      record.finished = finished;
      const items = await threadItems(thread);
      if (kind === "exec") {
        const command = items.find(item => item.type === "commandExecution");
        assert.equal(command?.exitCode, 0);
        assert.ok(command.aggregatedOutput.includes(`CGROUP_E2E_PAYLOAD_DONE_${token}`));
        if (fallback) assert.ok(command.aggregatedOutput.includes("WARNING: Linux task cgroup unavailable:"));
        else assert.equal(command.aggregatedOutput.includes("WARNING:"), false);
      } else {
        assert.ok(items.some(item => item.type === "dynamicToolCall" && item.tool === "start_job"));
      }
      record.items = items;
    }
    await card.screenshot({ path: path.join(meta.root, `${phase}-${width}-finished.png`) });
    await h.noOverflow(h.page, `${phase}-${width}`);
    results.push(record);
  } finally {
    // Release only this run's explicitly scoped held payload if an assertion failed.
    fs.writeFileSync(evidence + ".release", "");
  }
}

try {
  await h.start();
  h.projectId = meta.project.id;
  h.slug = meta.project.slug;
  h.root = meta.project.root_path;
  h.page.setDefaultTimeout(15_000);
  await h.context.addInitScript(() => localStorage.setItem("longx:language", "zh-CN"));
  const providers = await h.rpc("list_providers", {}, ["slug", "baseUrl"]);
  assert.equal(providers.length, 1, "never run this against a provider-bearing normal instance");
  assert.equal(providers[0].slug, "cgroup-e2e-local");
  assert.equal(providers[0].baseUrl, meta.model_url + "/v1");

  for (const width of [1280, 390]) {
    await h.page.setViewportSize({ width, height: 900 });
    await saveGlobal("auto");
    const initial = await status();
    assert.equal(initial.capability, meta.expected_capability);
    if (meta.expected_capability === "eligible") {
      await task({ width, phase: "auto-exec", protectedTask: true });
      await task({ width, phase: "auto-job", kind: "job", protectedTask: true });
      await saveGlobal("off");
      await task({ width, phase: "off-exec" });
      await saveGlobal("auto");
      await saveProject("off");
      await task({ width, phase: "project-off", project: true });
      await saveProject(null);
      await task({ width, phase: "project-inherited-auto", project: true, protectedTask: true });
    } else {
      await task({ width, phase: "auto-fallback", fallback: true });
      await saveGlobal("required");
      await task({ width, phase: "required-exec-denied", denied: true });
      await task({ width, phase: "required-job-denied", kind: "job", denied: true });
      await saveGlobal("off");
      await task({ width, phase: "off-unavailable" });
    }
    console.log(`real ${meta.expected_capability} cgroup E2E ${width}px passed`);
  }
  assert.deepEqual(h.problems, []);
} finally {
  try {
    if (h.projectId) await h.cleanup();
  } finally {
    fs.writeFileSync(path.join(meta.root, "browser-evidence.json"), JSON.stringify({ runId: meta.run_id, results, problems: h.problems }, null, 2));
    await h.stop();
  }
}
assert.deepEqual(h.problems, [], "cleanup must also succeed without hidden errors");
