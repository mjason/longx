#![cfg(feature = "test-fixture")]
use axum::{
    body::{to_bytes, Body},
    http::{Request, StatusCode},
};
use longx_computer::bridge::Bridge;
use serde_json::{json, Value};
use std::sync::Arc;
use tower::ServiceExt;
const TOKEN: &str = "fixture-key-012345678901234567890123";

fn bridge() -> Arc<Bridge> {
    Bridge::new(
        TOKEN.into(),
        env!("LONGX_MCP_FIXTURE").into(),
        "fixture".into(),
        false,
    )
}
async fn call(
    bridge: &Arc<Bridge>,
    session: Option<&str>,
    method: &str,
    params: Value,
) -> (StatusCode, String, Value) {
    let mut request = Request::builder()
        .method("POST")
        .uri("/mcp")
        .header("authorization", format!("Bearer {TOKEN}"))
        .header("content-type", "application/json");
    if let Some(session) = session {
        request = request.header("mcp-session-id", session);
    }
    let response = bridge
        .router()
        .oneshot(
            request
                .body(Body::from(
                    json!({
                        "jsonrpc":"2.0","id":1,"method":method,"params":params
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    let session = response
        .headers()
        .get("mcp-session-id")
        .map(|h| h.to_str().unwrap())
        .unwrap_or("")
        .to_owned();
    let value = serde_json::from_slice(&to_bytes(response.into_body(), 1024 * 1024).await.unwrap())
        .unwrap();
    (status, session, value)
}

#[tokio::test]
async fn auth_and_browser_origin_are_rejected() {
    let bridge = bridge();
    for (auth, origin, expected) in [
        ("bad", false, StatusCode::UNAUTHORIZED),
        (TOKEN, true, StatusCode::FORBIDDEN),
    ] {
        let mut request = Request::builder()
            .method("POST")
            .uri("/mcp")
            .header("authorization", format!("Bearer {auth}"))
            .header("content-type", "application/json");
        if origin {
            request = request.header("origin", "http://untrusted.example");
        }
        let response = bridge
            .router()
            .oneshot(
                request
                    .body(Body::from(
                        json!({"jsonrpc":"2.0","id":1,"method":"initialize"}).to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), expected);
    }
}

#[tokio::test]
async fn sessions_survive_http_requests_and_desktop_is_exclusive() {
    let bridge = bridge();
    let (_, a, _) = call(&bridge, None, "initialize", json!({})).await;
    let (_, b, _) = call(&bridge, None, "initialize", json!({})).await;
    assert_ne!(a, b);
    let (_, _, tools) = call(&bridge, Some(&a), "tools/list", json!({})).await;
    assert_eq!(tools["result"]["tools"].as_array().unwrap().len(), 2);
    let (_, _, result) = call(
        &bridge,
        Some(&a),
        "tools/call",
        json!({"name":"start_session","arguments":{"session":"a"}}),
    )
    .await;
    assert_ne!(result["result"]["isError"], true);
    assert!(bridge.busy().await);
    let (_, _, result) = call(
        &bridge,
        Some(&b),
        "tools/call",
        json!({"name":"start_session","arguments":{"session":"b"}}),
    )
    .await;
    assert_eq!(result["result"]["isError"], true);
    let (_, _, result) = call(
        &bridge,
        Some(&a),
        "tools/call",
        json!({"name":"click","arguments":{"session":"a","delivery_mode":"foreground"}}),
    )
    .await;
    assert_eq!(result["result"]["isError"], true);
    bridge.remove(&a).await;
    assert!(!bridge.busy().await);
    let (status, _, _) = call(&bridge, Some(&a), "ping", json!({})).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    bridge.stop().await;
    assert_eq!(bridge.clients().await, 0);
}

#[tokio::test]
async fn actions_without_a_lease_are_refused() {
    let bridge = bridge();
    let (_, session, _) = call(&bridge, None, "initialize", json!({})).await;
    let (_, _, result) = call(
        &bridge,
        Some(&session),
        "tools/call",
        json!({"name":"click","arguments":{}}),
    )
    .await;
    assert_eq!(result["result"]["isError"], true);
    bridge.stop().await;
}

#[tokio::test]
async fn disconnect_cancels_a_pending_driver_request_without_replaying_it() {
    let bridge = bridge();
    let (_, session, _) = call(&bridge, None, "initialize", json!({})).await;
    call(
        &bridge,
        Some(&session),
        "tools/call",
        json!({"name":"start_session","arguments":{"session":"a"}}),
    )
    .await;
    let worker_bridge = bridge.clone();
    let worker_session = session.clone();
    let request = tokio::spawn(async move {
        call(
            &worker_bridge,
            Some(&worker_session),
            "tools/call",
            json!({"name":"press_key","arguments":{"session":"a","key":"2"}}),
        )
        .await
    });
    tokio::time::sleep(std::time::Duration::from_millis(30)).await;
    tokio::time::timeout(std::time::Duration::from_secs(2), bridge.remove(&session))
        .await
        .unwrap();
    let (status, _, _) = tokio::time::timeout(std::time::Duration::from_secs(2), request)
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(
        status,
        StatusCode::BAD_GATEWAY | StatusCode::NOT_FOUND
    ));
    assert!(!bridge.busy().await);
    assert_eq!(bridge.clients().await, 0);
}

#[tokio::test]
#[ignore = "Explicit installed Driver contract check; no GUI actions or permission requests"]
async fn packaged_driver_contract() {
    use longx_computer::host::{Config, Host};
    let binary = std::env::var("LONGX_COMPUTER_DRIVER").expect("Set the verified Driver path");
    let data =
        std::env::var("LONGX_COMPUTER_SMOKE_DIR").expect("Set a project-local test directory");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let host = Host::start(
        &Config {
            port,
            ..Config::default()
        },
        TOKEN.into(),
        binary.into(),
        data.into(),
    )
    .await
    .expect("Embedded daemon must start with its own private endpoint");
    let (status, session, response) = call(
        &host.bridge,
        None,
        "initialize",
        json!({
            "protocolVersion":"2025-06-18","capabilities":{},
            "clientInfo":{"name":"longx-computer-contract-test","version":"0.1.0"}
        }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(response["result"]["protocolVersion"], "2025-06-18");
    let initialized = host
        .bridge
        .router()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/mcp")
                .header("authorization", format!("Bearer {TOKEN}"))
                .header("content-type", "application/json")
                .header("mcp-session-id", &session)
                .body(Body::from(
                    json!({"jsonrpc":"2.0","method":"notifications/initialized"}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(initialized.status(), StatusCode::ACCEPTED);
    let (_, _, response) = call(&host.bridge, Some(&session), "tools/list", json!({})).await;
    assert!(response["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .any(|tool| tool["name"] == "get_window_state"));
    let (_, _, response) = call(
        &host.bridge,
        Some(&session),
        "tools/call",
        json!({"name":"check_permissions","arguments":{"prompt":false}}),
    )
    .await;
    assert_ne!(response["result"]["isError"], true);
    assert_eq!(
        response["result"]["structuredContent"]["source"]["attribution"],
        "host"
    );
    let (_, _, response) = call(
        &host.bridge,
        Some(&session),
        "tools/call",
        json!({"name":"start_session","arguments":{"session":"contract"}}),
    )
    .await;
    assert_ne!(response["result"]["isError"], true);
    let (_, _, response) = call(
        &host.bridge,
        Some(&session),
        "tools/call",
        json!({"name":"end_session","arguments":{"session":"contract"}}),
    )
    .await;
    assert_ne!(response["result"]["isError"], true);
    // This test host is not a signed GUI app; attribution is a mode check,
    // not proof of permission inheritance or capture readiness.
    host.stop().await;
}
