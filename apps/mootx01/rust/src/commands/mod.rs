//! commands/mod.rs — subcommand dispatch.
//!
//! `serve` is live (it hosts the full aria-mcp runtime). The remaining
//! subcommands land as the installer-core port progresses; until then they
//! fail honestly with exit 1 rather than pretending.

use std::process::ExitCode;

use crate::cli::Command;
use crate::core::paths;

pub mod db;
pub mod drain;
pub mod dream;
pub mod install;
pub mod proxy;
pub mod query;
pub mod serve;
pub mod status;
pub mod uninstall;
pub mod upgrade;
/// ADR-025 unlock/lock commands (password-based, Rust/Linux/Windows path).
pub mod unlock;

pub fn dispatch(command: Command) -> ExitCode {
    match command {
        Command::Serve { db, http } => serve::run(db, http),
        Command::Install {
            target, location, yes, grant_permissions, no_permissions, no_mgr, no_daemon, vault_on, depth,
        } => install::run(target, location, yes, grant_permissions, no_permissions, no_mgr, no_daemon, vault_on, depth),
        Command::Uninstall {
            target,
            location,
            yes,
            purge,
        } => uninstall::run(target, location, yes, purge),
        Command::Db(sub) => db::run(sub),
        Command::Status => status::run(),
        Command::Query { verb, db, json, args } => query::run(verb, db, json, args),
        Command::Proxy { daemon_url } => proxy::run(daemon_url),
        Command::Drain { db } => drain::run(db),
        Command::Dream { db } => dream::run(db),
        Command::Upgrade { from, check, yes, no_restart } => {
            upgrade::run(from, check, yes, no_restart)
        }
        // ADR-025: sensitivity unlock / lock.
        Command::Unlock { tier, db: _ } => {
            // Resolve the data directory for the sidecar and daemon-port files.
            // The `--db` flag (estate override) is accepted by the parser but the
            // daemon itself owns grant-issuance — the estate name affects which
            // estate is opened by `serve`, not which port to unlock on. The port
            // is always resolved via the standard daemon-port-file mechanism.
            let data_dir = paths::data_dir();
            ExitCode::from(unlock::run_unlock(&tier, &data_dir) as u8)
        }
        Command::Lock => ExitCode::from(unlock::run_lock() as u8),
        // Version/Help/HelpFor are handled in main before dispatch.
        Command::Version | Command::Help | Command::HelpFor(_) => {
            unreachable!("handled in main")
        }
    }
}
