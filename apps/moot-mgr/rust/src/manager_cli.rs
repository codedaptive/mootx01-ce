// manager_cli.rs — Rust twin of the Swift moot-mgr ManagerCLI.swift.
//
// The CLI surface: argument parsing into a typed command, and the driver that
// runs a one-shot command against a MootManager. Kept in the library (not just
// the binary) so tests exercise the full parse→dispatch path without spawning a
// process.
//
// Command surface:
//   moot-mgr monitoring on        — set the global switch ON (broadcast)
//   moot-mgr monitoring off       — set the global switch OFF (broadcast)
//   moot-mgr monitoring status    — print "ON"/"OFF"
//   moot-mgr retention run        — run one retention pass now
//   moot-mgr status               — print the full read/status surface
//   moot-mgr serve                — run the resident host (long-running)
//   moot-mgr help                 — usage

use crate::manager::{ManagerError, MootManager};

/// A parsed moot-mgr CLI command. Mirrors Swift `ManagerCommand`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManagerCommand {
    /// Set the global monitoring switch ON (the broadcast signal).
    MonitoringOn,
    /// Set the global monitoring switch OFF.
    MonitoringOff,
    /// Print the current monitoring state ("ON"/"OFF").
    MonitoringStatus,
    /// Run one retention pass now (roll off samples older than the window).
    RetentionRun,
    /// Print the full read/status surface.
    Status,
    /// Run the resident host (loopback HTTP read-API + gated local IPC control
    /// channel + retention loop) until the process is signalled. The long-running surface
    /// handled by the binary's `main`, not by `run` (which covers one-shot store
    /// operations).
    Serve,
    /// Print usage text.
    Help,
}

/// Parse `arguments` (excluding the program name) into a `ManagerCommand`.
/// Returns `None` if the arguments are not a recognised command (the caller
/// prints usage and exits non-zero). Mirrors Swift `ManagerCLI.parse(_:)`.
pub fn parse(arguments: &[String]) -> Option<ManagerCommand> {
    let first = match arguments.first() {
        // A bare invocation is informational — show help.
        None => return Some(ManagerCommand::Help),
        Some(f) => f.as_str(),
    };
    match first {
        "help" | "--help" | "-h" => Some(ManagerCommand::Help),
        "status" => Some(ManagerCommand::Status),
        "serve" => Some(ManagerCommand::Serve),
        "monitoring" => {
            // Second token selects the monitoring action.
            match arguments.get(1).map(|s| s.as_str()) {
                Some("on") => Some(ManagerCommand::MonitoringOn),
                Some("off") => Some(ManagerCommand::MonitoringOff),
                Some("status") => Some(ManagerCommand::MonitoringStatus),
                _ => None,
            }
        }
        "retention" => {
            if arguments.get(1).map(|s| s.as_str()) == Some("run") {
                Some(ManagerCommand::RetentionRun)
            } else {
                None
            }
        }
        _ => None,
    }
}

/// Usage text for the `help` command and parse failures. Mirrors Swift
/// `ManagerCLI.usage`.
pub fn usage() -> &'static str {
    "moot-mgr — MOOTx01 observer/manager (Rust)\n\
\n\
USAGE:\n\
\u{20}\u{20}moot-mgr <command>\n\
\n\
COMMANDS:\n\
\u{20}\u{20}monitoring on        Enable monitoring fleet-wide (broadcast to consumers)\n\
\u{20}\u{20}monitoring off       Disable monitoring fleet-wide\n\
\u{20}\u{20}monitoring status    Print the current monitoring state (ON/OFF)\n\
\u{20}\u{20}retention run        Run one retention pass now (roll off old samples)\n\
\u{20}\u{20}status               Print the full status surface\n\
\u{20}\u{20}serve                Run the resident host: loopback HTTP read-API +\n\
\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}gated UDS control channel + retention loop (blocks)\n\
\u{20}\u{20}help                 Print this message\n\
\n\
ENVIRONMENT:\n\
\u{20}\u{20}MOOT_MGR_STORE                      Override the stats-store path\n\
\u{20}\u{20}MOOT_MGR_RETENTION_SECONDS          Retention window in seconds (default 604800 = 7d)\n\
\u{20}\u{20}MOOT_MGR_RETENTION_CADENCE_SECONDS  Resident retention-loop cadence (default 3600 = 1h)\n\
\u{20}\u{20}MOOT_MGR_HTTP_PORT                  Loopback HTTP read-API port (serve; default 4200)\n\
\u{20}\u{20}MOOT_MGR_CONTROL_TOKEN              Bearer token gating HTTP control (serve; required, >=16 chars)\n\
\u{20}\u{20}MOOT_MGR_CONTROL_SOCKET             UDS path for the gated control channel (serve)\n\
\u{20}\u{20}MOOT_MGR_ESTATES_DIR                Admin-plane estates directory (serve)"
}

/// Run a parsed command against a started manager and return the text to print.
/// The caller owns process start/stop and the clock (`now` epoch seconds).
/// `help` is handled by the caller; this driver covers the commands that touch
/// the store. Mirrors Swift `ManagerCLI.run(_:manager:now:)`.
pub fn run(
    command: &ManagerCommand,
    manager: &mut MootManager,
    now_epoch: f64,
) -> Result<String, ManagerError> {
    match command {
        ManagerCommand::Help => Ok(usage().to_string()),
        ManagerCommand::MonitoringOn => {
            manager.set_monitoring(true)?;
            Ok("monitoring: ON".to_string())
        }
        ManagerCommand::MonitoringOff => {
            manager.set_monitoring(false)?;
            Ok("monitoring: OFF".to_string())
        }
        ManagerCommand::MonitoringStatus => {
            let on = manager.is_monitoring()?;
            Ok(format!("monitoring: {}", if on { "ON" } else { "OFF" }))
        }
        ManagerCommand::RetentionRun => {
            let deleted = manager.run_retention(now_epoch)?;
            Ok(format!("retention: rolled off {deleted} rows"))
        }
        ManagerCommand::Status => {
            let report = manager.status(now_epoch, 20)?;
            Ok(report.render_text())
        }
        ManagerCommand::Serve => {
            // `serve` is a long-running surface handled by the binary's `main`
            // (it owns the host lifecycle and blocks). Not a one-shot store
            // operation, so this driver does not run it.
            Ok("serve: handled by the resident host entry point".to_string())
        }
    }
}
