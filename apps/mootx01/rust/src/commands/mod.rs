//! commands/mod.rs — subcommand dispatch.
//!
//! `serve` is live (it hosts the full aria-mcp runtime). The remaining
//! subcommands land as the installer-core port progresses; until then they
//! fail honestly with exit 1 rather than pretending.

use std::process::ExitCode;

use crate::cli::Command;

pub mod db;
pub mod install;
pub mod proxy;
pub mod query;
pub mod serve;
pub mod status;
pub mod uninstall;
pub mod upgrade;

pub fn dispatch(command: Command) -> ExitCode {
    match command {
        Command::Serve { db, http } => serve::run(db, http),
        Command::Install { target, location, yes, no_permissions, no_mgr, no_daemon, vault_on } => {
            install::run(target, location, yes, no_permissions, no_mgr, no_daemon, vault_on)
        }
        Command::Uninstall { target, yes, purge } => uninstall::run(target, yes, purge),
        Command::Db(sub) => db::run(sub),
        Command::Status => status::run(),
        Command::Query { verb, db, json, args } => query::run(verb, db, json, args),
        Command::Proxy { daemon_url } => proxy::run(daemon_url),
        Command::Upgrade { from, check, yes, no_restart } => {
            upgrade::run(from, check, yes, no_restart)
        }
        // Version/Help/HelpFor are handled in main before dispatch.
        Command::Version | Command::Help | Command::HelpFor(_) => {
            unreachable!("handled in main")
        }
    }
}
