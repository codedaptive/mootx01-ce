//! Exercise fatal stderr and exit behavior through the shipped CLI entry.
//! Native logging is a no-op on this development platform.
#![cfg(target_os = "macos")]

#[test]
fn platform_log_catalog_failure_keeps_interactive_stderr_and_exit_code() {
    let root = std::env::temp_dir().join(format!("platform-log-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_mootx01"))
        .args(["serve", "--db", "platform-log-missing-estate"])
        // Isolate catalog creation as well as the selected estate. This must
        // never read or create files in the user's actual configuration.
        .env("XDG_DATA_HOME", &root)
        .env("MOOTX01_DATA_DIR", &root)
        .env_remove("MOOTX01_HTTP_PORT")
        .output()
        .unwrap();
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    let stderr = String::from_utf8(output.stderr).unwrap();
    let fatal: Vec<_> = stderr
        .lines()
        .filter(|line| line.contains("serve fatal:"))
        .collect();
    assert_eq!(fatal, ["mootx01 serve fatal: mootx01: 'platform-log-missing-estate' is not a registered estate; an unregistered estate needs a path (<dir>/platform-log-missing-estate)"]);
}
