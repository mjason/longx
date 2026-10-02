const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);
let loaded = false;
let working = false;
async function action(fn) {
  if (working) return;
  working = true;
  $("error").textContent = "";
  try { await fn(); await refresh(); }
  catch (error) { $("error").textContent = String(error); }
  finally { working = false; }
}
async function refresh() {
  const state = await invoke("report");
  if (!loaded) {
    $("bind").value = state.config.bind_address;
    $("port").value = state.config.port;
    $("remote").checked = state.config.allow_remote;
    $("foreground").checked = state.config.allow_foreground;
    loaded = true;
  }
  const grant = (value) => value === true ? "已授权" : value === false ? "未授权" : "由系统会话管理";
  for (const [id, value] of [
    ["accessibility-state", state.permissions.accessibility],
    ["screen-recording-state", state.permissions.screen_recording],
  ]) {
    $(id).textContent = grant(value);
    $(id).dataset.granted = String(value);
  }
  $("permission-note").textContent = state.permissions.note;
  $("service-badge").textContent = state.running ? (state.busy ? "控制中" : "运行中") : "已停止";
  $("service-badge").dataset.state = state.running ? (state.busy ? "busy" : "running") : "stopped";
  $("status").textContent = state.running
    ? `服务运行中 · ${state.clients} 个连接 · ${state.busy ? "桌面正在被控制" : "桌面空闲"}`
    : "服务已停止";
  const host = state.config.bind_address.includes(":") ? `[${state.config.bind_address}]` : state.config.bind_address;
  $("url").textContent = `http://${host}:${state.config.port}/mcp${state.config.allow_remote ? "（远程请填写这台电脑的实际地址）" : ""}`;
}
$("service").addEventListener("submit", (event) => {
  event.preventDefault();
  action(() => invoke("start_service", { config: {
    bind_address: $("bind").value.trim(), port: Number($("port").value),
    allow_remote: $("remote").checked, allow_foreground: $("foreground").checked,
  }}));
});
$("stop").onclick = () => {
  // Emergency stop must not wait for another UI action to finish.
  invoke("stop_service").then(refresh).catch((error) => { $("error").textContent = String(error); });
};
$("reveal").onclick = () => action(async () => {
  if ($("key").type === "password") {
    $("key").value = await invoke("access_credential");
    $("key").type = "text";
    setTimeout(() => { $("key").type = "password"; $("key").value = ""; }, 30000);
  } else { $("key").type = "password"; $("key").value = ""; }
});
$("rotate").onclick = () => {
  if (confirm("撤销所有旧连接并更换访问密钥？Longx 中也需要更新密钥。")) action(async () => {
    await invoke("rotate_credential");
    $("key").value = ""; $("key").type = "password";
  });
};
document.querySelectorAll("[data-permission]").forEach((button) => {
  button.onclick = () => action(() => invoke("request_permission", { kind: button.dataset.permission }));
});
document.querySelectorAll("[data-settings]").forEach((button) => {
  button.onclick = () => action(() => invoke("open_permission_settings", { kind: button.dataset.settings }));
});
$("refresh-permissions").onclick = () => action(async () => {
  await refresh();
  $("permission-feedback").textContent = "已重新检测权限。若授权后状态仍未更新，请从托盘退出，再重新打开 Longx Computer。";
});
document.querySelectorAll("[data-reset]").forEach((button) => {
  button.onclick = () => {
    const name = button.dataset.reset === "accessibility" ? "辅助功能" : "屏幕录制";
    if (!confirm(`重新授权${name}会停止电脑服务，并重置 Longx Computer 的这项权限，不影响其他应用。之后需退出并重新打开应用，再申请权限。继续吗？`)) return;
    action(async () => {
      await invoke("reset_permission", { kind: button.dataset.reset });
      $("permission-feedback").textContent = `${name}授权已重置。请从托盘退出并重新打开本应用，再点击申请权限。`;
    });
  };
});
function renderUpdate(update) {
  $("update-status").textContent = update.available
    ? `当前版本 ${update.current} · 可升级至 ${update.available}`
    : `当前版本 ${update.current}${update.enabled ? "" : " · 自升级未启用"}`;
  $("update-note").textContent = update.note;
  $("install-update").hidden = !update.available;
  $("check-update").disabled = !update.enabled;
}
$("check-update").onclick = () => action(async () => {
  $("update-status").textContent = "正在检查更新…";
  $("install-update").hidden = true;
  try {
    const update = await invoke("check_update");
    renderUpdate(update);
    if (!update.available) $("update-status").textContent = `当前版本 ${update.current} · 已是最新版本`;
  } catch (error) {
    $("update-status").textContent = "检查更新失败，可重试";
    throw error;
  }
});
$("install-update").onclick = () => {
  if (!confirm("下载并验证更新签名，停止电脑服务并安装更新？完成后需退出并重新打开应用，Longx 也需要重新连接。")) return;
  action(async () => {
    $("install-update").hidden = true;
    $("update-status").textContent = "正在下载、验证签名并安装更新…";
    try {
      await invoke("install_update");
      $("update-status").textContent = "更新已安装。请从托盘退出并重新打开应用，再启动服务。";
      $("check-update").disabled = true;
    } catch (error) {
      $("update-status").textContent = "更新未完成，请重新检查更新";
      throw error;
    }
  });
};
invoke("update_status").then(renderUpdate).catch((error) => {
  $("update-status").textContent = "无法读取更新配置";
  $("error").textContent = String(error);
});
refresh().catch((error) => { $("error").textContent = String(error); });
setInterval(() => { if (!working) refresh().catch(() => {}); }, 2000);
window.addEventListener("blur", () => { $("key").type = "password"; $("key").value = ""; });
