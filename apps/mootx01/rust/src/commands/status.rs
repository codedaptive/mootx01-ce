//! commands/status.rs — §4.5: server state, active estate, wired clients.
//!
//! Output shape matches the Swift StatusCommand verbatim (§7). Liveness is
//! determined by the daemon's port file plus a loopback TCP probe — the
//! resident daemon writes `daemon.port` and `mootx01.pid` (serve, §3); a
//! probe of the recorded port is portable across Unix and Windows where a
//! kill(pid, 0) check is not. Stale pid/port files are cleaned here, same as
//! the Swift side cleans a stale pid file.
//!
//! Wired-client detection is format-aware (JSON / TOML / YAML) — the Swift
//! status only checks JSON today (spec §8 conformance note).

use std::net::TcpStream;
use std::process::ExitCode;
use std::time::Duration;

use crate::core::{clients, paths};
use crate::exit;

pub fn run() -> ExitCode {
    let data = paths::data_dir();
    let home = home_dir();

    println!("mootx01 status");
    println!("─────────────────────────────────");

    // Server liveness: daemon.port + TCP probe; PID from mootx01.pid.
    let port_file = paths::daemon_port_file(&data);
    let pid_file = data.join("mootx01.pid");
    let live_port = paths::read_port_file(&port_file).filter(|&p| probe(p));
    match live_port {
        Some(_) => {
            let pid = std::fs::read_to_string(&pid_file)
                .ok()
                .and_then(|s| s.trim().parse::<u32>().ok());
            match pid {
                Some(pid) => println!("Server: running (PID {pid})"),
                None => println!("Server: running"),
            }
        }
        None => {
            println!("Server: not running");
            // Clean stale files if the daemon is gone.
            if port_file.exists() {
                let _ = std::fs::remove_file(&port_file);
            }
            if pid_file.exists() {
                let _ = std::fs::remove_file(&pid_file);
            }
        }
    }

    // Active estate.
    let active = paths::active_estate(&data);
    println!("Active estate: {active}");

    // Estate file info.
    let estate = paths::estate_sqlite_path(&data, &active);
    match std::fs::metadata(&estate) {
        Ok(m) => println!(
            "Estate file: {} ({})",
            estate.display(),
            format_bytes(m.len())
        ),
        Err(_) => println!("Estate file: not yet created (run `mootx01 serve` to initialise)"),
    }

    // Wired clients.
    println!();
    println!("Wired clients:");
    let mut found = false;
    for client in clients::supported() {
        if client.wired(&home) {
            println!("  ✓ {}", client.display_name);
            found = true;
        }
    }
    if !found {
        println!("  (none — run `mootx01 install` to wire clients)");
    }

    println!();
    ExitCode::from(exit::OK)
}

fn probe(port: u16) -> bool {
    TcpStream::connect_timeout(
        &std::net::SocketAddr::from(([127, 0, 0, 1], port)),
        Duration::from_millis(250),
    )
    .is_ok()
}

fn home_dir() -> std::path::PathBuf {
    #[cfg(target_os = "windows")]
    {
        std::env::var("USERPROFILE")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::path::PathBuf::from("."))
    }
    #[cfg(not(target_os = "windows"))]
    {
        std::env::var("HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::path::PathBuf::from("."))
    }
}

/// Integer-division byte formatting, matching the Swift formatBytes.
fn format_bytes(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{bytes} B")
    } else if bytes < 1024 * 1024 {
        format!("{} KB", bytes / 1024)
    } else {
        format!("{} MB", bytes / (1024 * 1024))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_bytes_matches_swift_integer_division() {
        assert_eq!(format_bytes(0), "0 B");
        assert_eq!(format_bytes(1023), "1023 B");
        assert_eq!(format_bytes(1024), "1 KB");
        assert_eq!(format_bytes(217_088), "212 KB");
        assert_eq!(format_bytes(5 * 1024 * 1024), "5 MB");
    }
}
