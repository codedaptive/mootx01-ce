//! moot-mgr binary — the Rust observer/manager host entry point.
//!
//! Parses the CLI command and dispatches. One-shot store commands
//! (monitoring/retention/status) open the manager, run the command, print the
//! result, and exit. `serve` brings up the resident multi-plane host (loopback
//! HTTP read-API + gated local IPC control channel — UDS on Unix, named pipe on
//! Windows) and runs the retention loop on the configured cadence until signalled.
//!
//! Per the no-FFI law this binary is a COMPLETE Rust vertical — it never calls
//! Swift, Swift never calls it. The macOS GUI is not ported; the host serves the
//! same language-neutral web dashboard assets over loopback HTTP.

use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use moot_mgr::manager::MootManager;
use moot_mgr::manager_cli::{self, ManagerCommand};
use moot_mgr::manager_config::ManagerConfig;
use moot_mgr::resident_host::{ResidentHost, ResidentHostConfig};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = match manager_cli::parse(&args) {
        Some(c) => c,
        None => {
            eprintln!("{}", manager_cli::usage());
            return ExitCode::from(2);
        }
    };

    match command {
        ManagerCommand::Help => {
            println!("{}", manager_cli::usage());
            ExitCode::SUCCESS
        }
        ManagerCommand::Serve => run_serve(),
        // One-shot store commands.
        other => run_one_shot(&other),
    }
}

/// The current Unix time in seconds (the binary owns the wall clock; the engines
/// take an explicit `now`).
fn now_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Open a manager, run a one-shot command, print the result, and exit.
fn run_one_shot(command: &ManagerCommand) -> ExitCode {
    let config = ManagerConfig::from_environment();
    let mut manager = MootManager::new(config);
    if let Err(e) = manager.start() {
        eprintln!("moot-mgr: cannot open store: {e:?}");
        return ExitCode::FAILURE;
    }
    let result = manager_cli::run(command, &mut manager, now_secs());
    manager.stop();
    match result {
        Ok(text) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("moot-mgr: {e:?}");
            ExitCode::FAILURE
        }
    }
}

/// Bring up the resident host and block, running the retention loop on the
/// configured cadence until the process is terminated.
fn run_serve() -> ExitCode {
    let config = ResidentHostConfig::from_environment();
    let cadence = config.manager.retention_cadence_secs.max(1);
    let mut host = ResidentHost::new(config, now_secs());
    if let Err(e) = host.start() {
        eprintln!("moot-mgr: cannot start resident host: {e:?}");
        return ExitCode::FAILURE;
    }
    eprintln!(
        "moot-mgr: resident host serving (HTTP :{})",
        host.bound_http_port()
    );
    // Retention loop: wake every `cadence` seconds and run one pass. The loop
    // owns the clock boundary; the store engines receive the computed cutoff.
    // This blocks the main thread for the life of the process (the HTTP listener
    // + UDS control channel serve on their own dedicated threads).
    loop {
        std::thread::sleep(std::time::Duration::from_secs(cadence as u64));
        let _ = host.run_retention_tick(now_secs());
    }
}
