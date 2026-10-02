use crate::bridge::Bridge;
use serde::{Deserialize, Serialize};
use std::{
    net::{IpAddr, SocketAddr},
    path::PathBuf,
    process::Stdio,
    sync::Arc,
    time::Duration,
};
use tokio::{
    net::TcpListener,
    process::{Child, Command},
    sync::{watch, Mutex},
    task::JoinHandle,
};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub bind_address: String,
    pub port: u16,
    pub allow_remote: bool,
    pub allow_foreground: bool,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            bind_address: "127.0.0.1".into(),
            port: 7797,
            allow_remote: false,
            allow_foreground: false,
        }
    }
}
impl Config {
    pub fn address(&self) -> Result<SocketAddr, String> {
        let ip: IpAddr = self
            .bind_address
            .parse()
            .map_err(|_| "监听地址必须是 IPv4 或 IPv6 地址")?;
        if self.port == 0 {
            return Err("端口必须在 1–65535 之间".into());
        }
        if !ip.is_loopback() && !self.allow_remote {
            return Err("远程监听需要明确勾选允许远程访问".into());
        }
        Ok(SocketAddr::new(ip, self.port))
    }
}

pub struct Host {
    pub bridge: Arc<Bridge>,
    daemon: Arc<Mutex<Child>>,
    stop: watch::Sender<bool>,
    server: JoinHandle<()>,
    reaper: JoinHandle<()>,
    _socket_dir: tempfile::TempDir,
}
impl Host {
    pub async fn start(
        config: &Config,
        token: String,
        binary: PathBuf,
        data: PathBuf,
    ) -> Result<Self, String> {
        let listener = TcpListener::bind(config.address()?)
            .await
            .map_err(|_| "监听失败：地址不可用或端口已被占用")?;
        if !binary.is_file() {
            return Err("安装包缺少内置 CUA Driver，请重新安装完整应用".into());
        }
        std::fs::create_dir_all(&data).map_err(|_| "无法创建应用数据目录")?;
        // macOS Unix socket paths have a small length limit. Use an owned,
        // private temporary directory, not the application's long bundle path.
        let socket_dir = tempfile::Builder::new()
            .prefix("longx-cua-")
            .tempdir()
            .map_err(|_| "无法创建私有连接目录")?;
        #[cfg(windows)]
        let socket = format!(r"\\.\pipe\longx-computer-{}", uuid::Uuid::new_v4());
        #[cfg(not(windows))]
        let socket = socket_dir
            .path()
            .join("cua.sock")
            .to_string_lossy()
            .to_string();
        let daemon = Command::new(&binary)
            .args([
                "serve",
                "--embedded",
                "--parent-liveness-stdio",
                "--no-permissions-gate",
                "--permission-mode",
                "standard",
                "--socket",
                &socket,
            ])
            .env("CUA_DRIVER_EMBEDDED", "1")
            .env("CUA_DRIVER_HOST_BUNDLE_ID", "com.longx.computer")
            .env(
                "CUA_DRIVER_EMBEDDED_HOST_PID",
                std::process::id().to_string(),
            )
            .env_remove("CUA_DRIVER_RS_MCP_HTTP_PORT")
            .env_remove("CUA_DRIVER_RS_MCP_HTTP_TOKEN")
            // Retaining Child.stdin keeps the liveness pipe open. Host death
            // closes it even when destructors cannot run.
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(
                if std::env::var_os("LONGX_COMPUTER_DRIVER_DIAGNOSTICS").is_some() {
                    Stdio::inherit()
                } else {
                    Stdio::null()
                },
            )
            .kill_on_drop(true)
            .spawn()
            .map_err(|_| "无法启动内置 Driver")?;
        let daemon = Arc::new(Mutex::new(daemon));
        // Wait for the private endpoint; never publish an HTTP listener whose
        // runtime is still starting or has failed.
        let mut ready = false;
        for _ in 0..100 {
            if let Some(exit) = daemon
                .lock()
                .await
                .try_wait()
                .map_err(|_| "Driver 状态不可用")?
            {
                return Err(format!(
                    "Driver 启动时退出（{exit}）；请检查内置运行时与应用权限身份"
                ));
            }
            #[cfg(unix)]
            {
                ready = tokio::net::UnixStream::connect(&socket).await.is_ok();
            }
            #[cfg(windows)]
            {
                ready = tokio::net::windows::named_pipe::ClientOptions::new()
                    .open(&socket)
                    .is_ok();
            }
            if ready {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        if !ready {
            let _ = daemon.lock().await.kill().await;
            return Err("Driver 启动失败，未建立私有连接".into());
        }
        let bridge = Bridge::new(token, binary, socket, config.allow_foreground);
        let (stop, mut stopped) = watch::channel(false);
        let router = bridge.router();
        let server = tokio::spawn(async move {
            let _ = axum::serve(listener, router)
                .with_graceful_shutdown(async move {
                    let _ = stopped.changed().await;
                })
                .await;
        });
        let reaper_bridge = bridge.clone();
        let reaper_daemon = daemon.clone();
        let shutdown = stop.clone();
        let reaper = tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                if reaper_daemon
                    .lock()
                    .await
                    .try_wait()
                    .ok()
                    .flatten()
                    .is_some()
                {
                    reaper_bridge.stop().await;
                    let _ = shutdown.send(true);
                    break;
                }
                reaper_bridge.expire().await;
            }
        });
        Ok(Self {
            bridge,
            daemon,
            stop,
            server,
            reaper,
            _socket_dir: socket_dir,
        })
    }

    pub async fn alive(&self) -> bool {
        self.daemon
            .lock()
            .await
            .try_wait()
            .ok()
            .is_some_and(|exit| exit.is_none())
    }
    pub async fn stop(self) {
        let _ = self.stop.send(true);
        self.server.abort();
        self.reaper.abort();
        {
            use tokio::io::AsyncWriteExt;
            let mut daemon = self.daemon.lock().await;
            if let Some(mut liveness) = daemon.stdin.take() {
                let _ = liveness.shutdown().await;
            }
            if tokio::time::timeout(Duration::from_millis(750), daemon.wait())
                .await
                .is_err()
            {
                let _ = daemon.kill().await;
            }
        }
        self.bridge.stop().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn default_is_local_and_remote_is_explicit() {
        assert_eq!(
            Config::default().address().unwrap().to_string(),
            "127.0.0.1:7797"
        );
        let mut config = Config {
            bind_address: "0.0.0.0".into(),
            ..Config::default()
        };
        assert!(config.address().is_err());
        config.allow_remote = true;
        assert!(config.address().is_ok());
        config.port = 0;
        assert!(config.address().is_err());
    }
}
