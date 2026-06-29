//! cli.rs — argv → typed Command, help text, exit-code policy.
//!
//! Hand-rolled parsing (no clap) per house style: help text is part of the
//! CLI surface spec (§7 demands it match the Swift binary), and usage errors
//! must exit 64 (§5). Parsing is pure — argv in, Result<Command, UsageError>
//! out — so the whole surface is unit-testable.
//!
//! Spec §2: `mootx01` with no subcommand prints usage and exits 64,
//! unconditionally. No TTY/pipe detection, no implicit default subcommand —
//! the installer writes explicit args (`serve`, `proxy`) into client configs.

use std::fmt;

/// A fully parsed invocation.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// §4.1 serve [--db <name>] [--http <port|auto>]
    Serve { db: Option<String>, http: Option<HttpMode> },
    /// §4.2 install [--target <ids>] [--location global|local] [--yes]
    ///              [--mode server|skills|plugin]
    ///              [--grant-permissions] [--no-permissions] [--no-mgr] [--no-daemon]
    ///              [--vault-on | --vault-off]
    Install {
        target: Option<Vec<String>>,
        location: Location,
        yes: bool,
        /// Opt-in flag: write ARIA tool permissions to settings.json. Off by default
        /// so the installer does not silently grant broad MCP tool approval.
        grant_permissions: bool,
        no_permissions: bool,
        no_mgr: bool,
        no_daemon: bool,
        /// True when vault is enabled (default). False when --vault-off is passed.
        /// --vault-on is a no-op (vault is on by default) but is accepted for
        /// symmetry and to let users be explicit. If both flags are given,
        /// vault_on=false (--vault-off wins — the safer choice) per ADR-015.
        vault_on: bool,
        /// Integration depth (§4.4). None when `--mode` was not supplied — the
        /// command then prompts (interactive) or defaults to plugin (`--yes` /
        /// non-interactive). Some(_) when `--mode server|skills|plugin` is given.
        depth: Option<InstallDepthArg>,
    },
    /// §4.3 uninstall [--target <ids>] [--location global|local] [--yes] [--purge]
    Uninstall {
        target: Option<Vec<String>>,
        location: Option<Location>,
        yes: bool,
        purge: bool,
    },
    /// §4.4 db <create|list|open|delete>
    Db(DbCommand),
    /// §4.5 status
    Status,
    /// §4.6 query <verb> [--db <name>] [--json] [-- <args...>]
    Query { verb: String, db: Option<String>, json: bool, args: Vec<String> },
    /// §4.7 proxy [--daemon-url <url>]
    Proxy { daemon_url: Option<String> },
    /// drain [--db <name>] — finish draining an estate's encode queue, then exit
    /// (the detached background finisher an stdio serve spawns on exit; T5).
    Drain { db: Option<String> },
    /// dream [--db <name>] — run one REM-ALPHA dreaming cycle, then exit
    /// (the detached background finisher an stdio serve spawns on startup/exit
    /// when the dreaming queue has pending items; T10 / ADR-021 Phase 5).
    Dream { db: Option<String> },
    /// §4.8 upgrade [--from <path>] [--check] [--yes] [--no-restart]
    Upgrade { from: Option<String>, check: bool, yes: bool, no_restart: bool },
    /// --version on the root command.
    Version,
    /// --help / help on the root command (prints usage, exits 0).
    Help,
    /// help <subcommand> / <subcommand> --help.
    HelpFor(&'static str),
}

/// §3/§4.1 HTTP transport request. `Auto` hunts upward from 4242 to the
/// first free port (service units use this); an explicit port is exact —
/// busy means fail, never hunt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpMode {
    Auto,
    Port(u16),
}

#[derive(Debug, Clone, PartialEq)]
pub enum DbCommand {
    Create { name: String },
    List,
    Open { name: String },
    Delete { name: String, force: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Location {
    Global,
    Local,
}

/// §4.4 `--mode` value: integration depth. Parse-layer mirror of
/// core::depth::InstallDepth (kept here so cli.rs stays pure and
/// dependency-light; install.rs maps it to the core type).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallDepthArg {
    Server,
    Skills,
    Plugin,
}

/// A usage error: carries the message printed to stderr. Exit code is
/// always `exit::USAGE` (64).
#[derive(Debug, Clone, PartialEq)]
pub struct UsageError(pub String);

impl fmt::Display for UsageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Parse argv (without the program name) into a Command.
pub fn parse(args: &[String]) -> Result<Command, UsageError> {
    let mut it = args.iter().peekable();

    let first = match it.next() {
        // §2: bare invocation → usage, exit 64. Surfaced as a UsageError
        // whose message is the root usage text.
        None => return Err(UsageError(root_usage().to_string())),
        Some(a) => a.as_str(),
    };

    match first {
        "--version" => Ok(Command::Version),
        "--help" | "-h" | "help" => match it.next() {
            None => Ok(Command::Help),
            Some(s) => help_for(s).map(Command::HelpFor),
        },
        "serve" => parse_serve(&mut it),
        "install" => parse_install(&mut it),
        "uninstall" => parse_uninstall(&mut it),
        "db" => parse_db(&mut it),
        "status" => {
            if let Some(h) = expect_help_or_end(&mut it, "status")? {
                return Ok(h);
            }
            Ok(Command::Status)
        }
        "query" => parse_query(&mut it),
        "proxy" => parse_proxy(&mut it),
        "drain" => parse_drain(&mut it),
        "dream" => parse_dream(&mut it),
        "upgrade" => parse_upgrade(&mut it),
        other => Err(UsageError(format!(
            "Error: unknown subcommand '{other}'.\n\n{}",
            root_usage()
        ))),
    }
}

type Args<'a> = std::iter::Peekable<std::slice::Iter<'a, String>>;

/// Consume `--help` (→ Ok(Some(HelpFor))) or require end-of-args (→ Ok(None)).
fn expect_help_or_end(
    it: &mut Args,
    cmd: &'static str,
) -> Result<Option<Command>, UsageError> {
    match it.next() {
        None => Ok(None),
        Some(a) if a == "--help" || a == "-h" => Ok(Some(Command::HelpFor(cmd))),
        Some(a) => Err(UsageError(format!(
            "Error: unexpected argument '{a}' for '{cmd}'."
        ))),
    }
}

fn take_value(it: &mut Args, flag: &str) -> Result<String, UsageError> {
    it.next()
        .map(|s| s.to_string())
        .ok_or_else(|| UsageError(format!("Error: '{flag}' requires a value.")))
}

fn parse_serve(it: &mut Args) -> Result<Command, UsageError> {
    let (mut db, mut http) = (None, None);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--db" => db = Some(take_value(it, "--db")?),
            "--http" => {
                let v = take_value(it, "--http")?;
                http = Some(if v == "auto" {
                    HttpMode::Auto
                } else {
                    HttpMode::Port(v.parse::<u16>().map_err(|_| {
                        UsageError(format!(
                            "Error: '--http' expects a port number or 'auto', got '{v}'."
                        ))
                    })?)
                });
            }
            "--help" | "-h" => return Ok(Command::HelpFor("serve")),
            other => return Err(unexpected(other, "serve")),
        }
    }
    Ok(Command::Serve { db, http })
}

fn parse_drain(it: &mut Args) -> Result<Command, UsageError> {
    let mut db = None;
    while let Some(a) = it.next() {
        match a.as_str() {
            "--db" => db = Some(take_value(it, "--db")?),
            "--help" | "-h" => return Ok(Command::HelpFor("drain")),
            other => return Err(unexpected(other, "drain")),
        }
    }
    Ok(Command::Drain { db })
}

fn parse_dream(it: &mut Args) -> Result<Command, UsageError> {
    let mut db = None;
    while let Some(a) = it.next() {
        match a.as_str() {
            "--db" => db = Some(take_value(it, "--db")?),
            "--help" | "-h" => return Ok(Command::HelpFor("dream")),
            other => return Err(unexpected(other, "dream")),
        }
    }
    Ok(Command::Dream { db })
}

fn parse_install(it: &mut Args) -> Result<Command, UsageError> {
    let mut target = None;
    let mut location = Location::Global;
    let (mut yes, mut grant_permissions, mut no_permissions, mut no_mgr, mut no_daemon) =
        (false, false, false, false, false);
    // vault_on tracks the net choice: true = vault enabled (the default).
    // --vault-off sets it false; --vault-on is a no-op but is accepted for
    // symmetry. If both appear, --vault-off wins (last-write wins in the loop,
    // but --vault-off always sets false regardless of order, so it dominates).
    let mut vault_on = true;
    // §4.4 integration depth. None until --mode is seen.
    let mut depth: Option<InstallDepthArg> = None;
    while let Some(a) = it.next() {
        match a.as_str() {
            "--target" => {
                let v = take_value(it, "--target")?;
                target = Some(v.split(',').map(|s| s.trim().to_string()).collect());
            }
            "--location" => {
                let v = take_value(it, "--location")?;
                location = match v.as_str() {
                    "global" => Location::Global,
                    "local" => Location::Local,
                    other => {
                        return Err(UsageError(format!(
                            "Error: '--location' must be 'global' or 'local', got '{other}'."
                        )))
                    }
                };
            }
            // §4.4: integration depth. Honored in both silent and guided modes.
            "--mode" => {
                let v = take_value(it, "--mode")?;
                depth = Some(match v.as_str() {
                    "server" => InstallDepthArg::Server,
                    "skills" => InstallDepthArg::Skills,
                    "plugin" => InstallDepthArg::Plugin,
                    other => {
                        return Err(UsageError(format!(
                            "Error: '--mode' must be 'server', 'skills', or 'plugin', got '{other}'."
                        )))
                    }
                });
            }
            "--yes" | "-y" => yes = true,
            "--grant-permissions" => grant_permissions = true,
            "--no-permissions" => no_permissions = true,
            "--no-mgr" => no_mgr = true,
            "--no-daemon" => no_daemon = true,
            // ADR-015: vault surface toggle. --vault-off wins over --vault-on
            // when both are present (the safer choice). --vault-on is explicit
            // opt-in to the default and is accepted for symmetry / scripting.
            "--vault-on" => { /* vault_on already true; explicit for clarity */ }
            "--vault-off" => vault_on = false,
            "--help" | "-h" => return Ok(Command::HelpFor("install")),
            other => return Err(unexpected(other, "install")),
        }
    }
    Ok(Command::Install { target, location, yes, grant_permissions, no_permissions, no_mgr, no_daemon, vault_on, depth })
}

fn parse_uninstall(it: &mut Args) -> Result<Command, UsageError> {
    let mut target = None;
    let mut location = None;
    let (mut yes, mut purge) = (false, false);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--target" => {
                let v = take_value(it, "--target")?;
                target = Some(v.split(',').map(|s| s.trim().to_string()).collect());
            }
            "--location" => {
                let v = take_value(it, "--location")?;
                location = Some(match v.as_str() {
                    "global" => Location::Global,
                    "local" => Location::Local,
                    other => {
                        return Err(UsageError(format!(
                            "Error: '--location' must be 'global' or 'local', got '{other}'."
                        )))
                    }
                });
            }
            "--yes" | "-y" => yes = true,
            "--purge" => purge = true,
            "--help" | "-h" => return Ok(Command::HelpFor("uninstall")),
            other => return Err(unexpected(other, "uninstall")),
        }
    }
    Ok(Command::Uninstall {
        target,
        location,
        yes,
        purge,
    })
}

fn parse_db(it: &mut Args) -> Result<Command, UsageError> {
    let sub = match it.next() {
        None => {
            return Err(UsageError(
                "Error: 'db' requires a subcommand: create, list, open, delete.".into(),
            ))
        }
        Some(s) => s.as_str(),
    };
    match sub {
        "create" => {
            let name = take_value(it, "db create <name>")?;
            if let Some(h) = expect_help_or_end(it, "db")? {
                return Ok(h);
            }
            Ok(Command::Db(DbCommand::Create { name }))
        }
        "list" => {
            if let Some(h) = expect_help_or_end(it, "db")? {
                return Ok(h);
            }
            Ok(Command::Db(DbCommand::List))
        }
        "open" => {
            let name = take_value(it, "db open <name>")?;
            if let Some(h) = expect_help_or_end(it, "db")? {
                return Ok(h);
            }
            Ok(Command::Db(DbCommand::Open { name }))
        }
        "delete" => {
            let name = take_value(it, "db delete <name>")?;
            let mut force = false;
            while let Some(a) = it.next() {
                match a.as_str() {
                    "--force" | "-f" => force = true,
                    other => return Err(unexpected(other, "db delete")),
                }
            }
            Ok(Command::Db(DbCommand::Delete { name, force }))
        }
        "--help" | "-h" => Ok(Command::HelpFor("db")),
        other => Err(UsageError(format!(
            "Error: unknown db subcommand '{other}'. Expected create, list, open, delete."
        ))),
    }
}

fn parse_query(it: &mut Args) -> Result<Command, UsageError> {
    let verb = match it.next() {
        None => {
            return Err(UsageError(
                "Error: 'query' requires a verb, e.g. 'mootx01 query drawer_recall'.".into(),
            ))
        }
        Some(v) if v == "--help" || v == "-h" => return Ok(Command::HelpFor("query")),
        Some(v) => v.to_string(),
    };
    let (mut db, mut json) = (None, false);
    let mut args = Vec::new();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--db" => db = Some(take_value(it, "--db")?),
            "--json" => json = true,
            "--help" | "-h" => return Ok(Command::HelpFor("query")),
            // Remaining args pass through as --key value tool arguments.
            other => args.push(other.to_string()),
        }
    }
    Ok(Command::Query { verb, db, json, args })
}

fn parse_proxy(it: &mut Args) -> Result<Command, UsageError> {
    let mut daemon_url = None;
    while let Some(a) = it.next() {
        match a.as_str() {
            "--daemon-url" => daemon_url = Some(take_value(it, "--daemon-url")?),
            "--help" | "-h" => return Ok(Command::HelpFor("proxy")),
            other => return Err(unexpected(other, "proxy")),
        }
    }
    Ok(Command::Proxy { daemon_url })
}

fn parse_upgrade(it: &mut Args) -> Result<Command, UsageError> {
    let mut from = None;
    let (mut check, mut yes, mut no_restart) = (false, false, false);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--from" => from = Some(take_value(it, "--from")?),
            "--check" => check = true,
            "--yes" => yes = true,
            "--no-restart" => no_restart = true,
            "--help" | "-h" => return Ok(Command::HelpFor("upgrade")),
            other => return Err(unexpected(other, "upgrade")),
        }
    }
    Ok(Command::Upgrade { from, check, yes, no_restart })
}

fn unexpected(arg: &str, cmd: &str) -> UsageError {
    UsageError(format!("Error: unexpected argument '{arg}' for '{cmd}'."))
}

fn help_for(s: &str) -> Result<&'static str, UsageError> {
    match s {
        "serve" => Ok("serve"),
        "install" => Ok("install"),
        "uninstall" => Ok("uninstall"),
        "db" => Ok("db"),
        "status" => Ok("status"),
        "query" => Ok("query"),
        "proxy" => Ok("proxy"),
        "drain" => Ok("drain"),
        "dream" => Ok("dream"),
        "upgrade" => Ok("upgrade"),
        other => Err(UsageError(format!("Error: unknown subcommand '{other}'."))),
    }
}

/// Root usage text. Abstracts per spec §4; one line per subcommand.
pub fn root_usage() -> &'static str {
    "OVERVIEW: ARIA MCP server and estate management tool.\n\
     \n\
     USAGE: mootx01 <subcommand>\n\
     \n\
     OPTIONS:\n\
     \x20 --version               Print the version and exit.\n\
     \x20 -h, --help              Show help information.\n\
     \n\
     SUBCOMMANDS:\n\
     \x20 serve                   Start the ARIA MCP server (stdio, or resident HTTP when --http / MOOTX01_HTTP_PORT is set).\n\
     \x20 install                 Wire mootx01 into MCP clients.\n\
     \x20 uninstall               Remove mootx01 from MCP clients.\n\
     \x20 db                      Manage named estate databases.\n\
     \x20 status                  Show server state, active estate, and wired clients.\n\
     \x20 query                   Issue a single ARIA tool call (v1.0: MCP subprocess passthrough).\n\
     \x20 proxy                   Proxy stdin JSON-RPC frames to the resident daemon over loopback HTTP (for Claude Desktop).\n\
     \x20 upgrade                 Upgrade mootx01 to the latest release or a local build.\n\
     \n\
     \x20 See 'mootx01 help <subcommand>' for detailed help."
}

/// Per-subcommand help text. Flag help strings per spec §4.
pub fn subcommand_usage(cmd: &str) -> String {
    match cmd {
        "serve" => "Start the ARIA MCP server (stdio, or resident HTTP when --http / MOOTX01_HTTP_PORT is set).\n\
            \n\
            USAGE: mootx01 serve [--db <name>] [--http <port|auto>]\n\
            \n\
            OPTIONS:\n\
            \x20 --db <name>             Named estate to serve. Default: active estate.\n\
            \x20 --http <port|auto>      Resident HTTP port on 127.0.0.1 (also MOOTX01_HTTP_PORT). 'auto' hunts upward from 4242 to the first free port; an explicit port is exact. When set, runs the resident daemon (HTTP + autonomic governor + telemetry) instead of stdio.".into(),
        "install" => "Wire mootx01 into MCP clients.\n\
            \n\
            USAGE: mootx01 install [--target <ids>] [--location <scope>] [--mode <depth>] [--yes] [--grant-permissions] [--no-permissions] [--no-mgr] [--no-daemon] [--vault-on | --vault-off]\n\
            \n\
            OPTIONS:\n\
            \x20 --target <ids>          Comma-separated client ids to install (e.g. claude,cursor). Default: interactive picker.\n\
            \x20 --location <scope>      Config scope: 'global' (default) or 'local' (project .mcp.json for Claude Code).\n\
            \x20 --mode <depth>          Integration depth for every selected client: 'server' (MCP only), 'skills' (server + mootx01-memory skill), or 'plugin' (server + native plugin). Default: prompt when interactive, else 'plugin'. Plugin falls back to skills on hosts without a plugin format.\n\
            \x20 -y, --yes               Skip prompts; auto-detect and install all present clients.\n\
            \x20 --grant-permissions     Opt in to settings.json permissions.allow grants.\n\
            \x20 --no-permissions        Do not grant tool permissions (default; retained for scripts).\n\
            \x20 --no-mgr                Skip registering the moot-mgr management console as a background service.\n\
            \x20 --no-daemon             Skip registering the resident mootx01 daemon (HTTP MCP server + autonomic governor) as a background service.\n\
            \x20 --vault-on              Enable Vault MCP tools (moot_vault_*). Default behavior: vault is on when neither flag is specified.\n\
            \x20 --vault-off             Hide Vault MCP tools from the MCP surface. Disables import/export for a more secure install position.".into(),
        "uninstall" => "Remove mootx01 from MCP clients.\n\
            \n\
            USAGE: mootx01 uninstall [--target <ids>] [--location <scope>] [--yes] [--purge]\n\
            \n\
            OPTIONS:\n\
            \x20 --target <ids>          Comma-separated client ids to uninstall. Default: all detected.\n\
            \x20 --location <scope>      Config scope: 'global', 'local', or omitted for both. Local removes Claude Code project .mcp.json and .claude/settings.json.\n\
            \x20 -y, --yes               Skip prompts; uninstall from all detected clients.\n\
            \x20 --purge                 Also delete all estate databases. Irreversible.".into(),
        "db" => "Manage named estate databases.\n\
            \n\
            USAGE: mootx01 db <create|list|open|delete>\n\
            \n\
            SUBCOMMANDS:\n\
            \x20 create <name>           Create a new named estate.\n\
            \x20 list                    List all known estates.\n\
            \x20 open <name>             Set the active estate (used by serve and status).\n\
            \x20 delete <name> [-f]      Delete a named estate and its database files. Cannot delete 'default' (use uninstall --purge).".into(),
        "status" => "Show server state, active estate, and wired clients.\n\
            \n\
            USAGE: mootx01 status".into(),
        "query" => "Issue a single ARIA tool call (v1.0: MCP subprocess passthrough).\n\
            \n\
            USAGE: mootx01 query <verb> [--db <name>] [--json] [<args>...]\n\
            \n\
            ARGUMENTS:\n\
            \x20 <verb>                  ARIA verb name without moot_ prefix, e.g. 'drawer_recall'.\n\
            \x20 <args>                  Tool arguments as --key value pairs.\n\
            \n\
            OPTIONS:\n\
            \x20 --db <name>             Named estate to query. Default: active estate.\n\
            \x20 --json                  Output raw JSON instead of human-readable text.".into(),
        "proxy" => "Proxy stdin JSON-RPC frames to the resident daemon over loopback HTTP (for Claude Desktop).\n\
            \n\
            USAGE: mootx01 proxy [--daemon-url <url>]\n\
            \n\
            OPTIONS:\n\
            \x20 --daemon-url <url>      Resident daemon base URL. Default: read daemon.port file, else http://127.0.0.1:4242.".into(),
        "drain" => "Finish draining an estate's encode queue, then exit. The detached background finisher an stdio serve spawns when it exits with encode work still pending (T5); rarely run by hand.\n\
            \n\
            USAGE: mootx01 drain [--db <name>]\n\
            \n\
            OPTIONS:\n\
            \x20 --db <name>             Named estate to drain. Default: active estate.".into(),
        "dream" => "Run one REM-ALPHA dreaming cycle, then exit. The detached background finisher an stdio serve spawns on startup or exit when the dreaming queue has pending items (T10 / ADR-021 Phase 5); rarely run by hand.\n\
            \n\
            USAGE: mootx01 dream [--db <name>]\n\
            \n\
            OPTIONS:\n\
            \x20 --db <name>             Named estate to process dreaming jobs for. Default: active estate.".into(),
        "upgrade" => "Upgrade mootx01 to the latest release or a local build.\n\
            \n\
            USAGE: mootx01 upgrade [--from <path>] [--check] [--yes] [--no-restart]\n\
            \n\
            OPTIONS:\n\
            \x20 --from <path>           Path to the new binary to install (skips online check).\n\
            \x20 --check                 Print the latest available version and exit without downloading.\n\
            \x20 --yes                   Skip the confirmation prompt before downloading a new release.\n\
            \x20 --no-restart            Copy the binary but skip restarting the background agents.".into(),
        other => format!("(no help for '{other}')"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &[&str]) -> Result<Command, UsageError> {
        let v: Vec<String> = s.iter().map(|x| x.to_string()).collect();
        parse(&v)
    }

    #[test]
    fn bare_invocation_is_usage_error() {
        assert!(p(&[]).is_err()); // §2: no default subcommand, exit 64
    }

    #[test]
    fn version_flag() {
        assert_eq!(p(&["--version"]).unwrap(), Command::Version);
    }

    #[test]
    fn serve_defaults() {
        assert_eq!(p(&["serve"]).unwrap(), Command::Serve { db: None, http: None });
    }

    #[test]
    fn serve_flags() {
        assert_eq!(
            p(&["serve", "--db", "work", "--http", "4242"]).unwrap(),
            Command::Serve { db: Some("work".into()), http: Some(HttpMode::Port(4242)) }
        );
        assert_eq!(
            p(&["serve", "--http", "auto"]).unwrap(),
            Command::Serve { db: None, http: Some(HttpMode::Auto) }
        );
    }

    #[test]
    fn serve_bad_port_is_usage_error() {
        assert!(p(&["serve", "--http", "nope"]).is_err());
    }

    #[test]
    fn install_full_surface() {
        assert_eq!(
            p(&["install", "--target", "claude,cursor", "--location", "local",
                "--yes", "--no-permissions", "--no-mgr", "--no-daemon"]).unwrap(),
            Command::Install {
                target: Some(vec!["claude".into(), "cursor".into()]),
                location: Location::Local,
                yes: true,
                grant_permissions: false, // not passed → off by default
                no_permissions: true,
                no_mgr: true,
                no_daemon: true,
                vault_on: true, // default when neither --vault-on nor --vault-off is passed
                depth: None,    // default when --mode is not passed
            }
        );
        // --grant-permissions flips the opt-in flag on.
        assert_eq!(
            p(&["install", "--grant-permissions"]).unwrap(),
            Command::Install {
                target: None,
                location: Location::Global,
                yes: false,
                grant_permissions: true,
                no_permissions: false,
                no_mgr: false,
                no_daemon: false,
                vault_on: true,
                depth: None,
            }
        );
    }

    #[test]
    fn install_mode_flag() {
        // §4.4: --mode parses the three depth values.
        for (flag, want) in [
            ("server", InstallDepthArg::Server),
            ("skills", InstallDepthArg::Skills),
            ("plugin", InstallDepthArg::Plugin),
        ] {
            assert_eq!(
                p(&["install", "--mode", flag]).unwrap(),
                Command::Install {
                    target: None,
                    location: Location::Global,
                    yes: false,
                    grant_permissions: false,
                    no_permissions: false,
                    no_mgr: false,
                    no_daemon: false,
                    vault_on: true,
                    depth: Some(want),
                }
            );
        }
        // No --mode → depth None (the command prompts or defaults to plugin).
        assert!(matches!(
            p(&["install"]).unwrap(),
            Command::Install { depth: None, .. }
        ));
        // Unrecognised value is a usage error.
        assert!(p(&["install", "--mode", "bogus"]).is_err());
    }

    #[test]
    fn install_vault_flags() {
        // --vault-off disables vault
        assert_eq!(
            p(&["install", "--vault-off"]).unwrap(),
            Command::Install {
                target: None,
                location: Location::Global,
                yes: false,
                grant_permissions: false,
                no_permissions: false,
                no_mgr: false,
                no_daemon: false,
                vault_on: false,
                depth: None,
            }
        );
        // --vault-on is explicit opt-in to the default
        assert_eq!(
            p(&["install", "--vault-on"]).unwrap(),
            Command::Install {
                target: None,
                location: Location::Global,
                yes: false,
                grant_permissions: false,
                no_permissions: false,
                no_mgr: false,
                no_daemon: false,
                vault_on: true,
                depth: None,
            }
        );
        // default (neither flag) is vault-on
        assert_eq!(
            p(&["install"]).unwrap(),
            Command::Install {
                target: None,
                location: Location::Global,
                yes: false,
                grant_permissions: false,
                no_permissions: false,
                no_mgr: false,
                no_daemon: false,
                vault_on: true,
                depth: None,
            }
        );
    }

    #[test]
    fn uninstall_location_flag() {
        assert_eq!(
            p(&[
                "uninstall",
                "--target",
                "claude-code",
                "--location",
                "local",
                "--yes"
            ])
            .unwrap(),
            Command::Uninstall {
                target: Some(vec!["claude-code".into()]),
                location: Some(Location::Local),
                yes: true,
                purge: false,
            }
        );
        assert!(p(&["uninstall", "--location", "bogus"]).is_err());
    }

    #[test]
    fn db_surface() {
        assert_eq!(p(&["db", "create", "work"]).unwrap(),
                   Command::Db(DbCommand::Create { name: "work".into() }));
        assert_eq!(p(&["db", "list"]).unwrap(), Command::Db(DbCommand::List));
        assert_eq!(p(&["db", "open", "work"]).unwrap(),
                   Command::Db(DbCommand::Open { name: "work".into() }));
        assert_eq!(p(&["db", "delete", "work", "-f"]).unwrap(),
                   Command::Db(DbCommand::Delete { name: "work".into(), force: true }));
    }

    #[test]
    fn db_requires_subcommand() {
        assert!(p(&["db"]).is_err());
    }

    #[test]
    fn query_verb_and_passthrough() {
        assert_eq!(
            p(&["query", "drawer_recall", "--db", "work", "--json", "--limit", "5"]).unwrap(),
            Command::Query {
                verb: "drawer_recall".into(),
                db: Some("work".into()),
                json: true,
                args: vec!["--limit".into(), "5".into()],
            }
        );
    }

    #[test]
    fn upgrade_flags() {
        assert_eq!(
            p(&["upgrade", "--check"]).unwrap(),
            Command::Upgrade { from: None, check: true, yes: false, no_restart: false }
        );
    }

    #[test]
    fn unknown_subcommand_is_usage_error() {
        assert!(p(&["frobnicate"]).is_err());
    }
}
