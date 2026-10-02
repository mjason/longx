use serde::Serialize;
use std::time::Duration;
use tauri::{AppHandle, State};
use tauri_plugin_updater::{Update, UpdaterExt};
use tokio::sync::Mutex;

#[derive(Default)]
pub struct Updates {
    pub pending: Mutex<Option<Update>>,
}

#[derive(Serialize)]
pub struct UpdateReport {
    current: String,
    enabled: bool,
    available: Option<String>,
    note: String,
}

fn configuration() -> Result<(&'static str, &'static str), String> {
    if cfg!(debug_assertions) {
        return Err("开发包不启用自升级；正式发布需要稳定应用签名和更新签名公钥。".into());
    }
    let endpoint = option_env!("LONGX_COMPUTER_UPDATE_URL").unwrap_or("");
    let public_key = option_env!("LONGX_COMPUTER_UPDATE_PUBLIC_KEY").unwrap_or("");
    if !endpoint.starts_with("https://") || public_key.is_empty() {
        return Err("此构建尚未配置 HTTPS 更新源和更新签名公钥。".into());
    }
    Ok((endpoint, public_key))
}

pub fn status(app: &AppHandle) -> UpdateReport {
    UpdateReport {
        current: app.package_info().version.to_string(),
        enabled: configuration().is_ok(),
        available: None,
        note: configuration().err().unwrap_or_else(|| {
            "升级保留配置与访问密钥；macOS 权限延续还依赖相同的发布签名身份。".into()
        }),
    }
}

#[tauri::command]
pub async fn update_status(app: AppHandle) -> UpdateReport {
    status(&app)
}

#[tauri::command]
pub async fn check_update(
    app: AppHandle,
    updates: State<'_, Updates>,
) -> Result<UpdateReport, String> {
    let (endpoint, public_key) = configuration()?;
    let mut pending = updates.pending.lock().await;
    // Never leave an old offer installable when a new check fails.
    *pending = None;
    let updater = app
        .updater_builder()
        .pubkey(public_key)
        .endpoints(vec![endpoint.parse().map_err(|_| "更新源地址无效")?])
        .map_err(|_| "更新源必须使用 HTTPS")?
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|_| "无法初始化签名更新器")?;
    let update = updater
        .check()
        .await
        .map_err(|_| "检查更新失败，请检查网络或更新源")?;
    if update
        .as_ref()
        .is_some_and(|update| update.download_url.scheme() != "https")
    {
        return Err("更新包下载地址必须使用 HTTPS".into());
    }
    let mut report = status(&app);
    report.available = update.as_ref().map(|update| update.version.clone());
    *pending = update;
    Ok(report)
}

#[tauri::command]
pub async fn install_update(
    updates: State<'_, Updates>,
    desktop: State<'_, super::Shared>,
) -> Result<(), String> {
    configuration()?;
    // One offer, one install. A failed download requires a fresh check.
    let mut pending = updates.pending.lock().await;
    let update = pending.take().ok_or("请先检查更新")?;
    {
        let state = desktop.lock().await;
        if let Some(host) = &state.host {
            if host.bridge.busy().await {
                return Err("桌面正在被控制，请先结束任务再升级".into());
            }
        }
    }
    // The plugin verifies the artifact signature before returning bytes.
    // Do not stop the service for a failed or untrusted download.
    let bytes = update
        .download(|_, _| {}, || {})
        .await
        .map_err(|_| "更新下载或签名验证失败；未安装更新")?;
    let mut state = desktop.lock().await;
    if state.upgrade_installed {
        return Err("更新已经安装，请退出并重新打开应用".into());
    }
    if let Some(host) = &state.host {
        if host.bridge.busy().await {
            return Err("下载期间开始了电脑任务；更新未安装，请结束任务后重试".into());
        }
    }
    if let Some(host) = state.host.take() {
        host.stop().await;
    }
    // Keep the desktop mutex until installation is done: no new service can
    // start while its bundled Driver is being replaced.
    tokio::task::spawn_blocking(move || update.install(bytes))
        .await
        .map_err(|_| "安装更新任务失败，服务保持停止")?
        .map_err(|_| "安装更新失败，服务保持停止，请检查应用目录写入权限")?;
    state.upgrade_installed = true;
    Ok(())
}
