// Compile only for core tests, never as an application binary. The fixture
// accepts the test suite's id=1 requests and performs no computer operation.
use std::io::{self, BufRead, Write};
fn main() {
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        if line.contains("\"name\":\"press_key\"") {
            std::thread::sleep(std::time::Duration::from_secs(60));
        }
        let result = if line.contains("\"method\":\"initialize\"") {
            r#"{"protocolVersion":"2025-06-18"}"#
        } else if line.contains("\"method\":\"tools/list\"") {
            r#"{"tools":[{"name":"click"},{"name":"stop"},{"name":"get_window_state"}]}"#
        } else {
            r#"{"content":[],"structuredContent":{"ok":true}}"#
        };
        println!(r#"{{"jsonrpc":"2.0","id":1,"result":{result}}}"#);
        io::stdout().flush().unwrap();
    }
}
