//! commands/status.rs — §4.5: server state, active estate, wired clients.
//!
//! Liveness is determined by the daemon's port file plus a loopback TCP probe —
//! the resident daemon writes `daemon.port` in the configuration directory and
//! `estate.pid` in the estate it serves (serve, §3); a TCP probe of the
//! recorded port is portable across Unix and Windows where a kill(pid, 0)
//! check is not. Stale pid/port files are cleaned here. Swift StatusCommand
//! uses kill(pid, 0) on the PID file and cleans only the PID file; both
//! produce equivalent liveness results for normal daemon states.
//!
//! Wired-client detection is format-aware (JSON / TOML / YAML), matching the
//! Swift StatusCommand which also delegates to format-aware wired detection.

use std::net::TcpStream;
use std::process::ExitCode;
use std::time::Duration;

use genius_locus_kit::EstateCatalog;

use crate::core::{clients, paths};
use crate::exit;

pub fn run() -> ExitCode {
    let data = EstateCatalog::configuration_directory();
    let home = home_dir();
    // Active estate, from the catalog. Status reports; it does not create the
    // catalog, so a machine that has never run install or serve says so.
    let active = EstateCatalog::load().map(|catalog| catalog.active().clone());

    println!("mootx01 status");
    println!("─────────────────────────────────");

    // Server liveness: daemon.port + TCP probe; PID from the active estate's
    // `estate.pid` marker (the served estate is the catalog's active record).
    let port_file = paths::daemon_port_file(&data);
    let pid_file = active
        .as_ref()
        .map(|record| record.pid_path())
        .unwrap_or_else(|_| data.join("estate.pid"));
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

    // Active estate and its file.
    match &active {
        Ok(record) => {
            println!("Active estate: {}", record.name);
            let estate = record.database_path();
            match std::fs::metadata(&estate) {
                Ok(m) => println!("Estate file: {} ({})", estate.display(), format_bytes(m.len())),
                Err(_) => println!("Estate file: not yet created (run `mootx01 serve` to initialise)"),
            }
        }
        Err(error) => println!("Active estate: none ({error})"),
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
