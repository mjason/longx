// Complete publishing: @ autocomplete -> write here -> send the full MDX ->
// the other project's session saves it verbatim -> its reply comes back.
// Real projects, directory, model calls, delivery and files; nothing mocked.
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { Harness, OUT, expect } from "../lib.mjs";

async function snapshot(page, kernelThreadId) {
  return page.evaluate((id) => new Promise((resolve, reject) => {
    const url = new URL("/socket/websocket?vsn=2.0.0", location.href);
    url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(url);
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error("snapshot timed out"));
    }, 15_000);
    ws.onopen = () => ws.send(JSON.stringify(["1", "1", `thread:${id}`, "phx_join", { limit: "all" }]));
    ws.onmessage = ({ data }) => {
      const message = JSON.parse(data);
      if (message[3] !== "phx_reply") return;
      clearTimeout(timer);
      ws.close();
      if (message[4].status === "ok") resolve(message[4].response);
      else reject(new Error(JSON.stringify(message[4])));
    };
    ws.onerror = () => {
      clearTimeout(timer);
      ws.close();
      reject(new Error("snapshot socket failed"));
    };
  }), kernelThreadId);
}

export async function run(h) {
  await h.context.addInitScript(() => localStorage.setItem("longx:language", "zh-CN"));
  await h.project();
  const target = new Harness(`${h.name}-receiver`);
  // Share the RPC transport, not the sender's project identity.
  target.page = h.page;
  target.csrf = h.csrf;
  try {
    await target.project();
    const receiver = await target.thread();
    const offDuty = await target.thread();
    await h.rpc("set_thread_handle", { threadId: receiver.id, handle: "notes" }, ["id", "handle"]);
    const directory = await h.rpc("directory", { projectId: h.projectId, scope: "all" }, ["sessions"]);
    const remote = directory.sessions.find((s) => s.threadId === receiver.id);
    const plain = directory.sessions.find((s) => s.threadId === offDuty.id);
    expect(remote?.onDuty && remote.address === `${target.slug}:notes`, "the real directory exposes the complete cross-project address");
    expect(plain && !plain.onDuty, "the receiver project also has an off-duty conversation");
    await target.send(receiver.id, "你是本次端到端测试的 notes 接收会话。别的会话发来完整 MDX 正文后，请从 frontmatter 的 slug 字段取文件名，原样保存到本项目 content/notes/<slug>.mdx。只接收已经写好的正文，不替对方写文章，不改正文，不添加说明。只允许写本项目的 content/notes/ 目录。保存后回复相对文件路径和一句摘要。现在只回复“接收协议已就绪”，不要创建文件。");
    const ready = await h.idle(receiver.id);
    expect(ready.every((t) => t.status === "completed"), "the real recipient is ready to save completed articles");
    let received = 1;
    const verified = [];

    for (const mode of ["desktop", "phone"]) {
      const sender = await h.thread();
      const marker = `e2e-cross-${mode}-${Date.now()}`;
      const relativePath = `content/notes/${marker}.mdx`;
      const task = `请你先在当前会话写好一篇约 300 字的中文研究报告，不能把写作工作交给对方。事实材料：样本 A 初始值 100、最终值 110；样本 B 初始值 100、最终值 95。报告需说明两者的变化、样本有限不能推广，以及下一步验证办法。采用 MDX 格式：YAML frontmatter 含 title、slug: ${marker} 和 summary，正文至少两个二级标题。在当前会话完整展示 MDX 正文，并把这份已经完成的完整正文发给下面补全选中的会话保存。调用 send_message 时，message 参数只能包含这份完整 MDX 正文（不要带代码围栏），与当前会话展示的正文逐字一致，不要只发写作任务或文件路径。你不要在本项目写文件。收到对方保存后的回复，把路径和摘要告诉我。成果接收会话：`;
      const page = mode === "phone" ? await h.phone() : h.page;
      if (mode === "phone") {
        await page.context().addInitScript(() => localStorage.setItem("longx:language", "zh-CN"));
      }
      await h.open(page, `/p/${h.slug}/t/${sender.id}`);
      const composer = page.getByRole("textbox", { name: "随心输入" });
      await composer.fill(task);
      await composer.pressSequentially("@notes");
      const completion = page.getByRole("option", { name: new RegExp(remote.address) });
      await completion.waitFor();
      expect(await page.getByRole("option", { name: new RegExp(plain.address) }).count() === 0, "off-duty conversations are not offered as recipients");
      await h.noOverflow(page, `${mode} autocomplete`);
      await h.shot(page, `${mode}-autocomplete`);
      await completion.click();
      const draft = await composer.inputValue();
      expect(draft.includes(`@session("${remote.address}")`) && draft.includes(task), "autocomplete preserves the task and inserts the complete session reference");
      expect((await h.rpc("list_turns", { threadId: sender.id }, ["id"])).length === 0, "autocomplete does not send");
      await h.shot(page, `${mode}-draft`);

      // The directory's discovery and copy affordances remain functional too.
      if (mode === "desktop") await page.keyboard.press("ControlOrMeta+3");
      else await page.getByTestId("bottom-toolbar").getByRole("button", { name: "Agent 与会话" }).click();
      const panel = page.getByTestId("session-directory");
      await panel.getByRole("button", { name: "其他项目", exact: true }).click();
      await panel.getByText(remote.address, { exact: true }).waitFor();
      expect(await panel.getByText(plain.address, { exact: true }).count() === 0, "off-duty conversations are not offered as delegates");
      await panel.getByRole("textbox", { name: "搜索会话或地址" }).fill(remote.address);
      expect(await panel.getByTestId("session-row").count() === 1, "search narrows the real directory to the target");
      await panel.getByRole("button", { name: "复制完整地址" }).click();
      await page.getByText("已复制完整地址", { exact: true }).waitFor();
      await h.noOverflow(page, `${mode} directory`);
      await h.shot(page, `${mode}-directory`);
      if (mode === "desktop") await page.keyboard.press("ControlOrMeta+3");
      else {
        await page.getByTestId("tool-sheet").getByRole("button", { name: "Close", exact: true }).click();
        await page.getByTestId("tool-sheet").waitFor({ state: "hidden" });
      }
      expect(new URL(page.url()).pathname.endsWith(`/t/${sender.id}`), "the original writing conversation stays open");
      await composer.press("Enter");
      console.log(`    ${mode}: submitted from the composer to ${remote.address}`);

      const receiverTurns = await h.idle(receiver.id, 180_000, ++received);
      const senderTurns = await h.idle(sender.id, 180_000, 2);
      expect(receiverTurns.every((t) => t.status === "completed"), `receiver turns: ${JSON.stringify(receiverTurns)}`);
      expect(senderTurns.every((t) => t.status === "completed"), `sender turns: ${JSON.stringify(senderTurns)}`);
      const sent = await snapshot(page, sender.kernelThreadId);
      const accepted = await snapshot(page, receiver.kernelThreadId);
      fs.writeFileSync(path.join(OUT, `${h.name}-${mode}-trace.json`), JSON.stringify({ sent, accepted }, null, 2) + "\n");
      const callIndex = sent.items.findIndex((i) => i.type === "dynamicToolCall" && i.tool === "send_message" && i.arguments?.to === remote.address);
      const call = sent.items[callIndex];
      expect(call?.success === true, "the real model called send_message with the full address and delivery succeeded");
      const body = call.arguments.message;
      expect(typeof body === "string" && body.length > 240 && /^---\r?\n/.test(body) && body.includes(marker) && (body.match(/^## /gm) ?? []).length >= 2, "the message is a complete authored MDX article, not a delegated task or a path");
      // A model can display the finished document before or after its tool call.
      // Its send_message arguments must already contain the entire authored text;
      // the recipient is not asked to write it. Require the sender's original
      // turn (not a later turn quoting the recipient's reply) to show the same MDX.
      const authored = sent.items.filter((i) => i.type === "agentMessage" && i.turnId === call.turnId).map((i) => i.text ?? "").join("");
      expect(authored.includes(body.trimEnd()), "the writing turn displays the same complete MDX that it sent");
      expect(accepted.items.some((i) => i.type === "userMessage" && i.from && i.content.some((c) => c.text?.includes(marker))), "the target received this exact task from another agent");
      const saved = fs.readFileSync(path.join(target.root, relativePath), "utf8");
      expect(saved.trimEnd() === body.trimEnd(), "the recipient saved exactly the author's full text without rewriting it");
      expect(!fs.existsSync(path.join(h.root, "content")), "the writer did not save or modify a notes application in its own project");
      expect(sent.items.some((i) => i.type === "userMessage" && i.from === "notes" && i.content.some((c) => c.text?.includes(relativePath))), "the recipient's saved-file path returned to the writer");
      expect((await h.rpc("list_turns", { threadId: offDuty.id }, ["id"])).length === 0, "the off-duty conversation was never woken");
      await page.getByTestId("tool-send-message").first().waitFor();
      expect((await page.getByTestId("tool-send-message").first().innerText()).includes(remote.address), "the outgoing row names the exact destination");
      await page.getByTestId("agent-message-kind").filter({ hasText: "回复" }).first().waitFor();
      await h.noOverflow(page, `${mode} reply`);
      await h.shot(page, `${mode}-reply`);
      // Preserve the generated example after the temporary projects are cleaned up.
      fs.copyFileSync(path.join(target.root, relativePath), path.join(OUT, `${h.name}-${mode}-published.mdx`));
      verified.push({ mode, address: remote.address, relativePath, characters: saved.length, sha256: createHash("sha256").update(saved).digest("hex"), senderProvidedFullText: true, displayedTextMatches: true, savedVerbatim: true, replyReturned: true });
      console.log(`    ${mode}: authored here, sent full MDX, saved verbatim and received file-path reply (${saved.length} characters)`);
    }
    fs.writeFileSync(path.join(OUT, `${h.name}-verified.json`), JSON.stringify(verified, null, 2) + "\n");
  } finally {
    await target.cleanup();
  }
}
