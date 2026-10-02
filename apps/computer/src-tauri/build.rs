fn main() {
    println!("cargo:rerun-if-env-changed=LONGX_COMPUTER_UPDATE_URL");
    println!("cargo:rerun-if-env-changed=LONGX_COMPUTER_UPDATE_PUBLIC_KEY");
    #[cfg(feature = "test-fixture")]
    {
        let dest =
            std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap()).join(if cfg!(windows) {
                "mcp-fixture.exe"
            } else {
                "mcp-fixture"
            });
        let rustc = std::env::var_os("RUSTC").unwrap_or_else(|| "rustc".into());
        assert!(std::process::Command::new(rustc)
            .args(["tests/support/mcp-fixture.rs", "-o"])
            .arg(&dest)
            .status()
            .unwrap()
            .success());
        println!("cargo:rustc-env=LONGX_MCP_FIXTURE={}", dest.display());
        println!("cargo:rerun-if-changed=tests/support/mcp-fixture.rs");
    }
    #[cfg(feature = "desktop")]
    tauri_build::build()
}
