pub mod bridge;
pub mod host;

pub fn access_key() -> String {
    use base64::Engine;
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("OS random source unavailable");
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}
