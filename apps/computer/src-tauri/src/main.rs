#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use longx_computer::{
    access_key,
    host::{Config, Host},
};
use serde::Serialize;
use std::{path::PathBuf, sync::Arc};
use tauri::{Manager, State};
use tokio::sync::Mutex;

mod updates;

struct Desktop {
    config: Config,
    host: Option<Host>,
    data: PathBuf,
    binary: PathBuf,
    config_path: PathBuf,
    upgrade_installed: bool,
}
type Shared = Arc<Mutex<Desktop>>;

fn key() -> Result<String, String> {
    let entry = keyring::Entry::new("com.longx.computer", "http-access-key")
        .map_err(|_| "无法访问系统凭据库")?;
    match entry.get_password() {
        Ok(key) => Ok(key),
        Err(keyring::Error::NoEntry) => {
            let key = access_key();
            entry.set_password(&key).map_err(|_| "无法保存访问凭据")?;
            Ok(key)
        }
        Err(_) => Err("无法读取系统凭据库，请解锁系统钥匙串/凭据库".into()),
    }
}

#[derive(Serialize)]
struct Report {
    config: Config,
    running: bool,
    busy: bool,
    clients: usize,
    permissions: Permissions,
}

#[derive(Serialize)]
struct Permissions {
    accessibility: Option<bool>,
    screen_recording: Option<bool>,
    note: &'static str,
}

#[cfg(target_os = "macos")]
mod macos {
    use core_foundation::{
        base::TCFType, boolean::CFBoolean, dictionary::CFDictionary, string::CFString,
    };
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> bool;
        fn AXIsProcessTrustedWithOptions(
            options: core_foundation::dictionary::CFDictionaryRef,
        ) -> bool;
        fn CGPreflightScreenCaptureAccess() -> bool;
        fn CGRequestScreenCaptureAccess() -> bool;
    }
    pub fn status() -> super::Permissions {
        super::Permissions {
            accessibility: Some(unsafe { AXIsProcessTrusted() }),
            screen_recording: Some(unsafe { CGPreflightScreenCaptureAccess() }),
            note:
                "权限属于 Longx Computer；系统授权后重启服务刷新 Driver，必要时完全退出再打开应用。",
        }
    }
    pub fn request(kind: &str) -> Result<(), String> {
        match kind {
            "accessibility" => {
                let options = CFDictionary::from_CFType_pairs(&[(
                    CFString::new("AXTrustedCheckOptionPrompt"),
                    CFBoolean::true_value(),
                )]);
                unsafe {
                    AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef());
                }
            }
            "screen_recording" => unsafe {
                CGRequestScreenCaptureAccess();
            },
            _ => return Err("未知权限".into()),
        }
        Ok(())
    }
}

fn permissions() -> Permissions {
    #[cfg(target_os = "macos")]
    {
        macos::status()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Permissions {
        accessibility: None, screen_recording: None,
        note: "Windows 必须运行在用户交互桌面；Linux 需要图形/无障碍会话，Wayland 可能要求 portal 授权。",
    }
    }
}

#[tauri::command]
async fn report(state: State<'_, Shared>) -> Result<Report, String> {
    let state = state.lock().await;
    let (running, busy, clients) = match &state.host {
        Some(host) => (
            host.alive().await,
            host.bridge.busy().await,
            host.bridge.clients().await,
        ),
        None => (false, false, 0),
    };
    Ok(Report {
        config: state.config.clone(),
        running,
        busy,
        clients,
        permissions: permissions(),
    })
}

#[tauri::command]
async fn start_service(state: State<'_, Shared>, config: Config) -> Result<(), String> {
    config.address()?;
    let token = tokio::task::spawn_blocking(key)
        .await
        .map_err(|_| "凭据读取失败")??;
    let mut state = state.lock().await;
    if state.upgrade_installed {
        return Err("更新已经安装，请退出并重新打开应用后启动服务".into());
    }
    if let Some(host) = state.host.take() {
        host.stop().await;
    }
    let host = Host::start(&config, token, state.binary.clone(), state.data.clone()).await?;
    let data = serde_json::to_vec_pretty(&config).map_err(|_| "配置编码失败")?;
    if std::fs::write(&state.config_path, data).is_err() {
        host.stop().await;
        return Err("配置保存失败，服务未启用".into());
    }
    state.config = config;
    state.host = Some(host);
    Ok(())
}

#[tauri::command]
async fn stop_service(state: State<'_, Shared>) -> Result<(), String> {
    let mut state = state.lock().await;
    if let Some(host) = state.host.take() {
        host.stop().await;
    }
    Ok(())
}

#[tauri::command]
async fn access_credential() -> Result<String, String> {
    tokio::task::spawn_blocking(key)
        .await
        .map_err(|_| "凭据读取失败")?
}

#[tauri::command]
async fn rotate_credential(state: State<'_, Shared>) -> Result<(), String> {
    stop_service(state).await?;
    tokio::task::spawn_blocking(|| {
        let entry = keyring::Entry::new("com.longx.computer", "http-access-key")
            .map_err(|_| "凭据库不可用")?;
        entry
            .set_password(&access_key())
            .map_err(|_| "凭据保存失败")?;
        Ok::<_, String>(())
    })
    .await
    .map_err(|_| "凭据更新失败")?
}

#[tauri::command]
async fn request_permission(app: tauri::AppHandle, kind: String) -> Result<(), String> {
    let (send, receive) = tokio::sync::oneshot::channel();
    app.run_on_main_thread(move || {
        #[cfg(target_os = "macos")]
        let result = macos::request(&kind).and_then(|_| {
            let permissions = macos::status();
            let granted = match kind.as_str() {
                "accessibility" => permissions.accessibility,
                "screen_recording" => permissions.screen_recording,
                _ => None,
            };
            if granted == Some(false) {
                open_permission_settings(kind)?;
                return Err("系统尚未授权，已打开权限设置。曾拒绝或授权失效时可使用「重新授权」；完成后退出并重新打开应用。".into());
            }
            Ok(())
        });
        #[cfg(not(target_os = "macos"))]
        let result = {
            let _ = kind;
            Err("请通过系统桌面/portal 授权".into())
        };
        let _ = send.send(result);
    })
    .map_err(|_| "无法调用系统权限界面")?;
    receive.await.map_err(|_| "权限请求未完成")?
}

#[tauri::command]
fn open_permission_settings(kind: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let pane = match kind.as_str() {
            "accessibility" => "Privacy_Accessibility",
            "screen_recording" => "Privacy_ScreenCapture",
            _ => return Err("未知权限".into()),
        };
        std::process::Command::new("/usr/bin/open")
            .arg(format!(
                "x-apple.systempreferences:com.apple.preference.security?{pane}"
            ))
            .spawn()
            .map_err(|_| "无法打开系统设置")?;
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = kind;
        Err("请打开系统设置管理权限".into())
    }
}

#[tauri::command]
async fn reset_permission(state: State<'_, Shared>, kind: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let service = match kind.as_str() {
            "accessibility" => "Accessibility",
            "screen_recording" => "ScreenCapture",
            _ => return Err("未知权限".into()),
        };
        // Explicit local UI confirmation precedes this command. Only reset
        // our own app, never every app's grants or the standalone Driver.
        stop_service(state).await?;
        let success = tokio::task::spawn_blocking(move || {
            std::process::Command::new("/usr/bin/tccutil")
                .args(["reset", service, "com.longx.computer"])
                .output()
                .map(|output| output.status.success())
        })
        .await
        .map_err(|_| "权限重置任务失败")?
        .map_err(|_| "无法调用系统权限重置")?;
        if !success {
            return Err("系统拒绝重置权限，请在系统设置中移除 Longx Computer 后重新添加。".into());
        }
        open_permission_settings(kind)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (state, kind);
        Err("请在系统桌面或 portal 设置中重新授权；本应用不会重置全局权限。".into())
    }
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(updates::Updates::default())
        .setup(|app| {
            let data = app.path().app_local_data_dir()?;
            std::fs::create_dir_all(&data)?;
            let config_path = data.join("service.json");
            let config = std::fs::read(&config_path)
                .ok()
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .unwrap_or_default();
            let executable = if cfg!(windows) {
                "cua-driver.exe"
            } else {
                "cua-driver"
            };
            let binary = app.path().resource_dir()?.join("driver").join(executable);
            #[cfg(debug_assertions)]
            let binary = if !binary.is_file() {
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("resources/driver")
                    .join(executable)
            } else {
                binary
            };
            app.manage(Arc::new(Mutex::new(Desktop {
                config,
                host: None,
                data,
                binary,
                config_path,
                upgrade_installed: false,
            })));
            let show = tauri::menu::MenuItem::with_id(
                app,
                "show",
                "打开 Longx Computer",
                true,
                None::<&str>,
            )?;
            let stop = tauri::menu::MenuItem::with_id(
                app,
                "stop",
                "立即停止电脑控制",
                true,
                None::<&str>,
            )?;
            let quit = tauri::menu::MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = tauri::menu::Menu::with_items(app, &[&show, &stop, &quit])?;
            let mut tray = tauri::tray::TrayIconBuilder::new()
                .tooltip("Longx Computer — 本机 HTTP MCP")
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.show();
                            let _ = window.set_focus();
                        }
                    }
                    "stop" => {
                        let state = app.state::<Shared>().inner().clone();
                        tauri::async_runtime::spawn(async move {
                            if let Some(host) = state.lock().await.host.take() {
                                host.stop().await;
                            }
                        });
                    }
                    "quit" => app.exit(0),
                    _ => {}
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            report,
            start_service,
            stop_service,
            access_credential,
            rotate_credential,
            request_permission,
            open_permission_settings,
            reset_permission,
            updates::update_status,
            updates::check_update,
            updates::install_update
        ])
        .build(tauri::generate_context!())
        .expect("Could not initialize Longx Computer");
    app.run(|app, event| {
        if let tauri::RunEvent::Exit = event {
            let state = app.state::<Shared>();
            tauri::async_runtime::block_on(async {
                if let Some(host) = state.lock().await.host.take() {
                    host.stop().await;
                }
            });
        }
    });
}
