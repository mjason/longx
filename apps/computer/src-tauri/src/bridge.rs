//! Authenticated HTTP MCP facade. A session owns a persistent stdio proxy;
//! TCP reconnects do not change its Driver transport. Never retry actions.
use axum::{
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::post,
    Json, Router,
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    path::PathBuf,
    process::Stdio,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdin, ChildStdout, Command},
    sync::{watch, Mutex},
};

pub const TOOLS: &[&str] = &[
    "list_apps",
    "list_windows",
    "launch_app",
    "get_window_state",
    "get_desktop_state",
    "verify_state",
    "click",
    "double_click",
    "right_click",
    "drag",
    "scroll",
    "type_text",
    "set_value",
    "press_key",
    "hotkey",
    "zoom",
    "set_window_frame",
    "invoke_menu",
    "clipboard_read",
    "clipboard_write",
    "start_session",
    "end_session",
    "check_permissions",
    "health_report",
];
const MAX_CLIENTS: usize = 8;
const MAX_REPLY: usize = 32 * 1024 * 1024;

struct Proxy {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Proxy {
    fn spawn(binary: &PathBuf, socket: &str) -> Result<Self, ()> {
        let mut child = Command::new(binary)
            .args(["mcp", "--embedded", "--socket", socket])
            .env("CUA_DRIVER_EMBEDDED", "1")
            .env("CUA_DRIVER_HOST_BUNDLE_ID", "com.longx.computer")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|_| ())?;
        Ok(Self {
            stdin: child.stdin.take().ok_or(())?,
            stdout: BufReader::new(child.stdout.take().ok_or(())?),
            child,
        })
    }

    async fn request(&mut self, request: &Value) -> Result<Value, ()> {
        let mut bytes = serde_json::to_vec(request).map_err(|_| ())?;
        bytes.push(b'\n');
        self.stdin.write_all(&bytes).await.map_err(|_| ())?;
        self.stdin.flush().await.map_err(|_| ())?;
        // Bound individual lines as well as the number of unsolicited messages.
        for _ in 0..32 {
            let mut line = Vec::new();
            loop {
                let available = self.stdout.fill_buf().await.map_err(|_| ())?;
                if available.is_empty() {
                    return Err(());
                }
                let n = available
                    .iter()
                    .position(|&c| c == b'\n')
                    .map_or(available.len(), |n| n + 1);
                if line.len() + n > MAX_REPLY {
                    return Err(());
                }
                let end = available[n - 1] == b'\n';
                line.extend_from_slice(&available[..n]);
                self.stdout.consume(n);
                if end {
                    break;
                }
            }
            let result: Value = serde_json::from_slice(&line).map_err(|_| ())?;
            if result.get("id") == request.get("id") {
                return Ok(result);
            }
        }
        Err(())
    }
}

struct Session {
    proxy: Mutex<Option<Proxy>>,
    seen: Mutex<Instant>,
    active: AtomicBool,
    cancel: watch::Sender<bool>,
}

pub struct Bridge {
    token: String,
    binary: PathBuf,
    socket: String,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    owner: Mutex<Option<(String, String)>>,
    allow_foreground: bool,
    enabled: AtomicBool,
}

impl Bridge {
    pub fn new(
        token: String,
        binary: PathBuf,
        socket: String,
        allow_foreground: bool,
    ) -> Arc<Self> {
        Arc::new(Self {
            token,
            binary,
            socket,
            sessions: Mutex::new(HashMap::new()),
            owner: Mutex::new(None),
            allow_foreground,
            enabled: AtomicBool::new(true),
        })
    }

    pub fn router(self: &Arc<Self>) -> Router {
        Router::new()
            .route("/mcp", post(dispatch).delete(disconnect))
            .layer(DefaultBodyLimit::max(1024 * 1024))
            .with_state(self.clone())
    }

    fn authenticated(&self, headers: &HeaderMap) -> bool {
        headers
            .get("authorization")
            .and_then(|h| h.to_str().ok())
            .and_then(|h| h.strip_prefix("Bearer "))
            .is_some_and(|token| bool::from(token.as_bytes().ct_eq(self.token.as_bytes())))
    }

    pub async fn busy(&self) -> bool {
        self.owner.lock().await.is_some()
    }
    pub async fn clients(&self) -> usize {
        self.sessions.lock().await.len()
    }

    pub async fn remove(&self, id: &str) {
        let session = self.sessions.lock().await.remove(id);
        if let Some(session) = session {
            session.active.store(false, Ordering::SeqCst);
            let _ = session.cancel.send(true);
            if let Some(mut proxy) = session.proxy.lock().await.take() {
                let _ = proxy.child.kill().await;
            }
        } else {
            // Another cleanup owns the process now; don't release its lease
            // until that cleanup has actually stopped the proxy.
            return;
        }
        let mut owner = self.owner.lock().await;
        if owner.as_ref().is_some_and(|(client, _)| client == id) {
            *owner = None;
        }
    }

    pub async fn stop(&self) {
        self.enabled.store(false, Ordering::SeqCst);
        let ids: Vec<_> = self.sessions.lock().await.keys().cloned().collect();
        for id in ids {
            self.remove(&id).await;
        }
    }

    pub async fn expire(&self) {
        let sessions: Vec<_> = self
            .sessions
            .lock()
            .await
            .iter()
            .map(|(id, session)| (id.clone(), session.clone()))
            .collect();
        for (id, session) in sessions {
            if session.seen.lock().await.elapsed() > Duration::from_secs(90) {
                self.remove(&id).await;
            }
        }
    }
}

// If the HTTP handler is cancelled, invalidate the whole session. A lost
// response may already have applied; subsequent requests must not reuse it.
struct InFlight {
    bridge: Arc<Bridge>,
    id: String,
    complete: bool,
}
impl Drop for InFlight {
    fn drop(&mut self) {
        if !self.complete {
            let bridge = self.bridge.clone();
            let id = self.id.clone();
            tokio::spawn(async move {
                bridge.remove(&id).await;
            });
        }
    }
}

fn error(status: StatusCode, id: Value, message: &str) -> Response {
    (
        status,
        Json(json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":message}})),
    )
        .into_response()
}
fn refused(id: Value, message: &str) -> Response {
    Json(json!({"jsonrpc":"2.0","id":id,"result":{
        "isError":true,"content":[{"type":"text","text":message}]
    }}))
    .into_response()
}

fn window_only(response: &mut Value) {
    let Some(elements) = response["result"]["structuredContent"]["elements"].as_array() else {
        return;
    };
    let mut omitted = std::collections::HashSet::new();
    let mut kept = Vec::new();
    for element in elements {
        let menu = element["role"]
            .as_str()
            .is_some_and(|role| role.contains("Menu"));
        let omitted_parent = element["parent_index"]
            .as_u64()
            .is_some_and(|parent| omitted.contains(&parent));
        if menu || omitted_parent {
            if let Some(index) = element["element_index"].as_u64() {
                omitted.insert(index);
            }
        } else {
            kept.push(element.clone());
        }
    }
    if omitted.is_empty() {
        return;
    }
    let markdown = kept
        .iter()
        .map(|element| {
            format!(
                "[{}] {} {} {}",
                element["element_index"],
                element["role"],
                element["label"].as_str().unwrap_or(""),
                element["value"].as_str().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    let result = &mut response["result"];
    result["structuredContent"]["elements"] = json!(kept);
    result["structuredContent"]["tree_markdown"] = json!(&markdown);
    result["structuredContent"]["app_menus_omitted"] = json!(true);
    if let Some(content) = result["content"].as_array_mut() {
        content.retain(|item| item["type"] != "text");
        content.push(json!({"type":"text","text":markdown}));
    }
}

async fn disconnect(State(bridge): State<Arc<Bridge>>, headers: HeaderMap) -> Response {
    if !bridge.authenticated(&headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if headers.contains_key("origin") {
        return StatusCode::FORBIDDEN.into_response();
    }
    if let Some(id) = headers.get("mcp-session-id").and_then(|h| h.to_str().ok()) {
        bridge.remove(id).await;
    }
    StatusCode::NO_CONTENT.into_response()
}

async fn dispatch(
    State(bridge): State<Arc<Bridge>>,
    headers: HeaderMap,
    Json(mut request): Json<Value>,
) -> Response {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let method = request["method"].as_str().unwrap_or("").to_owned();
    if !bridge.authenticated(&headers) {
        return error(StatusCode::UNAUTHORIZED, id, "Invalid access key");
    }
    if headers.contains_key("origin") {
        return error(
            StatusCode::FORBIDDEN,
            id,
            "Browser origins are not accepted",
        );
    }
    if !bridge.enabled.load(Ordering::SeqCst) {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            id,
            "Computer control stopped",
        );
    }
    if request["jsonrpc"] != "2.0"
        || !request.is_object()
        || (id.is_null() && method != "notifications/initialized")
    {
        return error(
            StatusCode::BAD_REQUEST,
            id,
            "Expected a JSON-RPC request with an id",
        );
    }
    if !matches!(
        method.as_str(),
        "initialize" | "notifications/initialized" | "ping" | "tools/list" | "tools/call"
    ) {
        return error(StatusCode::BAD_REQUEST, id, "Method not exposed");
    }
    if method == "tools/call"
        && (!request["params"].is_object()
            || !request["params"]["name"].is_string()
            || (request["params"].get("arguments").is_some()
                && !request["params"]["arguments"].is_object()))
    {
        return error(
            StatusCode::BAD_REQUEST,
            id,
            "Expected tool name and object arguments",
        );
    }
    let (session_id, session) = if method == "initialize" {
        let mut sessions = bridge.sessions.lock().await;
        if sessions.len() >= MAX_CLIENTS {
            return error(StatusCode::TOO_MANY_REQUESTS, id, "Too many clients");
        }
        let proxy = match Proxy::spawn(&bridge.binary, &bridge.socket) {
            Ok(proxy) => proxy,
            Err(_) => return error(StatusCode::SERVICE_UNAVAILABLE, id, "Driver unavailable"),
        };
        let session_id = uuid::Uuid::new_v4().to_string();
        let (cancel, _) = watch::channel(false);
        let session = Arc::new(Session {
            proxy: Mutex::new(Some(proxy)),
            seen: Mutex::new(Instant::now()),
            active: AtomicBool::new(true),
            cancel,
        });
        sessions.insert(session_id.clone(), session.clone());
        (session_id, session)
    } else {
        let session_id = headers
            .get("mcp-session-id")
            .and_then(|h| h.to_str().ok())
            .unwrap_or("")
            .to_owned();
        let session = bridge.sessions.lock().await.get(&session_id).cloned();
        match session {
            Some(session) => (session_id, session),
            None => {
                return error(
                    StatusCode::NOT_FOUND,
                    id,
                    "Session expired; reconnect and observe, do not replay input",
                )
            }
        }
    };
    *session.seen.lock().await = Instant::now();
    let mut flight = InFlight {
        bridge: bridge.clone(),
        id: session_id.clone(),
        complete: false,
    };
    if method == "notifications/initialized" {
        let mut guard = session.proxy.lock().await;
        let result = if let Some(proxy) = guard.as_mut() {
            let mut bytes = serde_json::to_vec(&request).unwrap();
            bytes.push(b'\n');
            proxy.stdin.write_all(&bytes).await
        } else {
            Err(std::io::Error::other("Session closed"))
        };
        drop(guard);
        flight.complete = result.is_ok();
        return if result.is_ok() {
            StatusCode::ACCEPTED.into_response()
        } else {
            error(StatusCode::BAD_GATEWAY, id, "Driver connection lost")
        };
    }
    let tool = request["params"]["name"].as_str().unwrap_or("").to_owned();
    let mut release = false;
    if method == "tools/call" {
        if !TOOLS.contains(&tool.as_str()) {
            flight.complete = true;
            return refused(id, "Tool not exposed by Longx Computer");
        }
        let args = &mut request["params"]["arguments"];
        if !args.is_object() {
            *args = json!({});
        }
        if !bridge.allow_foreground
            && (args["delivery_mode"] == "foreground"
                || args["scope"] == "desktop"
                || args["target"]["kind"] == "desktop"
                || matches!(tool.as_str(), "get_desktop_state" | "invoke_menu"))
        {
            flight.complete = true;
            return refused(
                id,
                "Enable foreground/full-display control in the desktop app first",
            );
        }
        let observation_only = matches!(tool.as_str(), "check_permissions" | "health_report");
        let label = args["session"].as_str().unwrap_or("implicit").to_owned();
        let mut owner = bridge.owner.lock().await;
        if !observation_only {
            if tool == "start_session" {
                if owner
                    .as_ref()
                    .is_some_and(|(client, current)| client != &session_id || current != &label)
                {
                    flight.complete = true;
                    return refused(id, "Desktop is controlled by another session");
                }
                *owner = Some((session_id.clone(), label.clone()));
            } else if !owner
                .as_ref()
                .is_some_and(|(client, current)| client == &session_id && current == &label)
            {
                flight.complete = true;
                return refused(id, "Start your desktop session before using computer tools");
            }
            release = tool == "end_session";
        }
        // Public labels do not select another transport's private session.
        if let Some(args) = args.as_object_mut() {
            args.retain(|key, _| {
                !key.starts_with('_')
                    && !matches!(key.as_str(), "screenshot_out_file" | "debug_image_out")
            });
            if !observation_only {
                args.insert("session".into(), json!(format!("{}:{}", session_id, label)));
            }
        }
    }
    let outcome = tokio::time::timeout(Duration::from_secs(30), async {
        let mut proxy = session.proxy.lock().await;
        if !session.active.load(Ordering::SeqCst) {
            return Err(());
        }
        let mut cancelled = session.cancel.subscribe();
        if *cancelled.borrow() {
            return Err(());
        }
        tokio::select! {
            biased;
            _ = cancelled.changed() => Err(()),
            result = proxy.as_mut().ok_or(())?.request(&request) => result,
        }
    })
    .await;
    match outcome {
        Ok(Ok(mut response)) => {
            if tool == "get_window_state" && !bridge.allow_foreground {
                window_only(&mut response);
            }
            if method == "tools/list" {
                if let Some(tools) = response["result"]["tools"].as_array_mut() {
                    tools.retain(|tool| {
                        tool["name"]
                            .as_str()
                            .is_some_and(|name| TOOLS.contains(&name))
                    });
                }
            }
            let tool_failed =
                response["result"]["isError"] == true || response.get("error").is_some();
            if release || (tool == "start_session" && tool_failed) {
                let mut owner = bridge.owner.lock().await;
                if owner
                    .as_ref()
                    .is_some_and(|(client, _)| client == &session_id)
                {
                    *owner = None;
                }
            }
            flight.complete = true;
            let mut result = Json(response).into_response();
            result
                .headers_mut()
                .insert("mcp-session-id", session_id.parse().unwrap());
            result
        }
        _ => {
            bridge.remove(&session_id).await;
            flight.complete = true;
            error(
                StatusCode::BAD_GATEWAY,
                id,
                "Driver connection lost; input may have happened, do not replay",
            )
        }
    }
}

#[cfg(test)]
mod privacy_tests {
    use super::*;
    #[test]
    fn global_app_menus_are_not_returned_in_background_mode() {
        let mut response = json!({"result":{
            "structuredContent":{"elements":[
                {"element_index":0,"role":"AXWindow","label":"Calculator"},
                {"element_index":1,"parent_index":0,"role":"AXButton","label":"2","element_token":"fresh"},
                {"element_index":2,"role":"AXMenuBar"},
                {"element_index":3,"parent_index":2,"role":"AXMenuItem","label":"private-recent.txt"}
            ],"tree_markdown":"private-recent.txt"},
            "content":[{"type":"text","text":"private-recent.txt"},{"type":"image","data":"fake"}]
        }});
        window_only(&mut response);
        assert!(!response.to_string().contains("private-recent.txt"));
        assert_eq!(
            response["result"]["structuredContent"]["elements"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(
            response["result"]["structuredContent"]["elements"][1]["element_token"],
            "fresh"
        );
        assert_eq!(response["result"]["content"][0]["type"], "image");
    }
}
