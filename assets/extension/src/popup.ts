// The popup: the Longx address, 连接 / 断开, and what the worker reports.
// It asks the worker every second while open — a message wakes the worker
// when Chrome had stopped it, which is exactly when the person looks.
import "./popup.css";
import type { PopupMessage, PopupReply, PopupStatus, StatusReport } from "./messages";

const LABELS: Record<PopupStatus, string> = {
  disconnected: "未连接",
  connecting: "连接中…",
  pending: "等待 Longx 里允许…",
  approved: "已连接",
  bad_token: "令牌失效，重新申请中…",
  revoked: "已被撤销",
  error: "连接失败",
};

const HINTS: Partial<Record<PopupStatus, string>> = {
  pending: "在 Longx 的 设置 → 浏览器 里点「允许」。",
  revoked: "Longx 里移除了这个浏览器。再点「连接」会重新申请。",
  bad_token: "Longx 不认这个浏览器的令牌。若一直如此，在 Longx 的 设置 → 浏览器 里吊销它后再连接。",
};

const $ = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T;
const form = $<HTMLFormElement>("form");
const server = $<HTMLInputElement>("server");
const deviceName = $<HTMLInputElement>("device-name");
const saveName = $<HTMLButtonElement>("save-name");
const connectButton = $<HTMLButtonElement>("connect");
const disconnectButton = $<HTMLButtonElement>("disconnect");
const status = $<HTMLParagraphElement>("status");
const identity = $<HTMLParagraphElement>("identity");
const hint = $<HTMLParagraphElement>("hint");
const sessions = $<HTMLElement>("sessions");

let addressShown = false;
let nameDirty = false;
let connectPending = false;
// a refused address (no URL): shown under the field until the person edits it,
// over the status hint the poll would otherwise put there
let fieldError: string | null = null;

function ask(message: PopupMessage): Promise<PopupReply> {
  return chrome.runtime.sendMessage(message);
}

function updateConnectButton(): void {
  connectButton.disabled = connectPending || !server.value.trim();
}

function render(reply: PopupReply): void {
  if ("failed" in reply) {
    fieldError = reply.failed;
    hint.hidden = false;
    hint.textContent = fieldError;
    hint.classList.add("error");
    return;
  }
  const r: StatusReport = reply;
  if (!nameDirty && r.deviceName) deviceName.value = r.deviceName;
  // the stored address fills the field once; what the person types stays
  if (!addressShown && r.serverUrl) {
    server.value = r.serverUrl;
    addressShown = true;
  }
  updateConnectButton();
  status.dataset.status = r.status;
  status.textContent =
    r.status === "approved" && r.name
      ? `${LABELS.approved}：${r.name}`
      : r.status === "error" && r.error
        ? `${LABELS.error}：${r.error}`
        : r.status === "connecting" && r.error
          ? `${LABELS.connecting}（${r.error}）`
          : LABELS[r.status];
  const h = fieldError ?? HINTS[r.status];
  identity.textContent = [
    r.serverUrl ? `Longx：${r.serverUrl}` : null,
    r.peerIp ? `连接来源 IP：${r.peerIp}` : null,
    r.browserId ? `设备 ID：${r.browserId}` : null,
  ].filter(Boolean).join("\n");
  identity.style.whiteSpace = "pre-wrap";
  identity.style.overflowWrap = "anywhere";
  hint.hidden = !h;
  hint.textContent = h ?? "";
  hint.classList.toggle("error", fieldError !== null);
  disconnectButton.hidden = r.status === "disconnected";
  connectButton.textContent = r.status === "disconnected" || r.status === "revoked" ? "连接" : "重新连接";

  const list = sessions.querySelector("ul")!;
  list.replaceChildren(
    ...r.sessions.map((s) => {
      const li = document.createElement("li");
      const title = document.createElement("span");
      title.textContent = s.title || "（未命名会话）";
      const tabs = document.createElement("span");
      tabs.textContent = `${s.tabs} 个标签`;
      li.append(title, tabs);
      return li;
    }),
  );
  sessions.hidden = r.status !== "approved" || r.sessions.length === 0;
}

form.addEventListener("submit", (e) => {
  e.preventDefault();
  const serverUrl = server.value.trim();
  if (!serverUrl || connectPending) return;
  connectPending = true;
  updateConnectButton();
  fieldError = null;
  const submittedName = deviceName.value;
  ask({ type: "connect", serverUrl, deviceName: submittedName })
    .then((reply) => {
      if (!("failed" in reply) && deviceName.value === submittedName) nameDirty = false;
      render(reply);
    }, (err: unknown) => render({ failed: err instanceof Error ? err.message : String(err) }))
    .finally(() => {
      connectPending = false;
      updateConnectButton();
    });
});

server.addEventListener("input", () => {
  addressShown = true;
  fieldError = null;
  updateConnectButton();
});

deviceName.addEventListener("input", () => { nameDirty = true; fieldError = null; });
saveName.addEventListener("click", () => {
  saveName.disabled = true;
  fieldError = null;
  const submittedName = deviceName.value;
  void ask({ type: "rename", deviceName: submittedName }).then((reply) => {
    if (!("failed" in reply) && deviceName.value === submittedName) nameDirty = false;
    render(reply);
  }, (err: unknown) => render({ failed: err instanceof Error ? err.message : String(err) }))
    .finally(() => { saveName.disabled = false; });
});
disconnectButton.addEventListener("click", () => void ask({ type: "disconnect" }).then(render));

updateConnectButton();
void ask({ type: "status" }).then(render);
setInterval(() => void ask({ type: "status" }).then(render), 1000);
