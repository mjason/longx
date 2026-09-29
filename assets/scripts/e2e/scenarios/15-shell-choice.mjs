// Select zsh through the real settings API, then prove both command paths
// execute zsh-only syntax. The settings UI is covered by SettingsPage.test.
// Restore the person's global choice even if an assertion fails.
import { BASE, expect } from "../lib.mjs";

export async function run(h) {
  const initial = await h.rpc("agent_settings", {}, ["commandShell"]);

  try {
    await h.rpc("set_agent_settings", { commandShell: "zsh" }, ["commandShell"]);
    const saved = await h.rpc("agent_settings", {}, ["commandShell"]);
    expect(saved.commandShell === "zsh", `saved command shell: ${JSON.stringify(saved)}`);

    await h.project();
    const t = await h.thread();
    await h.send(
      t.id,
      `请只用 exec_command 执行一次下面这条命令，不要改写，然后只回复它的完整输出：print -r -- "SHELL_E2E_EXEC:\${(t)path}"`,
    );
    const foreground = await h.idle(t.id, 180_000);
    expect(foreground[0]?.status === "completed", `exec_command turn: ${JSON.stringify(foreground)}`);

    const foregroundItems = await threadItems(h, t.id);
    const command = foregroundItems.find((item) => item.type === "commandExecution" && item.command?.includes("SHELL_E2E_EXEC"));
    expect(command?.aggregatedOutput?.includes("SHELL_E2E_EXEC:array"), `exec_command used zsh: ${JSON.stringify(command)}`);

    await h.send(
      t.id,
      `请用 start_job 启动名为 shellcheck 的后台任务，命令必须是 \`sleep 1; print -r -- "SHELL_E2E_JOB:\${(t)path}"\`。启动后立即结束本轮，只回复“已启动”。任务结束唤醒你后，用 job_output 读取输出并准确复述标记。`,
    );
    const turns = await h.idle(t.id, 240_000, 3);
    expect(turns.some((turn) => turn.status === "completed"), `job turns: ${JSON.stringify(turns)}`);

    await h.open(h.page, `/p/${h.slug}/t/${t.id}`);
    const items = await threadItems(h, t.id);
    const jobOutput = items.find((item) => item.type === "dynamicToolCall" && item.tool === "job_output" && item.arguments?.name === "shellcheck");
    expect(
      jobOutput && JSON.stringify(jobOutput.contentItems).includes("SHELL_E2E_JOB:array"),
      `the job's zsh output: ${JSON.stringify(jobOutput)}`,
    );
    const answer = items.filter((item) => item.type === "agentMessage").map((item) => item.text ?? "").join("\n");
    expect(answer.includes("SHELL_E2E_JOB:array"), `start_job used zsh: ${answer}`);
  } finally {
    await h.rpc("set_agent_settings", { commandShell: initial.commandShell }, ["commandShell"]);
  }
}

async function threadItems(h, threadId) {
  const response = await fetch(`${BASE}/api/p/${encodeURIComponent(h.slug)}/t/${threadId}?turns=1`);
  const report = await response.json();
  return report.turns.list.flatMap((turn) => turn.items);
}
