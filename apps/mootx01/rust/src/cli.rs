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
    ///              [--no-permissions] [--no-mgr] [--no-daemon]
    Install {
        target: Option<Vec<String>>,
        location: Location,
        yes: bool,
        no_permissions: bool,
        no_mgr: bool,
        no_daemon: bool,
    },
    /// §4.3 uninstall [--target <ids>] [--yes] [--purge]
    Uninstall { target: Option<Vec<String>>, yes: bool, purge: bool },
    /// §4.4 db <create|list|open|delete>
    Db(DbCommand),
    /// §4.5 status
    Status,
    /// §4.6 query <verb> [--db <name>] [--json] [-- <args...>]
    Query { verb: String, db: Option<String>, json: bool, args: Vec<String> },
    /// §4.7 proxy [--daemon-url <url>]
    Proxy { daemon_url: Option<String> },
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

fn parse_install(it: &mut Args) -> Result<Command, UsageError> {
    let mut target = None;
    let mut location = Location::Global;
    let (mut yes, mut no_permissions, mut no_mgr, mut no_daemon) = (false, false, false, false);
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
            "--yes" | "-y" => yes = true,
            "--no-permissions" => no_permissions = true,
            "--no-mgr" => no_mgr = true,
            "--no-daemon" => no_daemon = true,
            "--help" | "-h" => return Ok(Command::HelpFor("install")),
            other => return Err(unexpected(other, "install")),
        }
    }
    Ok(Command::Install { target, location, yes, no_permissions, no_mgr, no_daemon })
}

fn parse_uninstall(it: &mut Args) -> Result<Command, UsageError> {
    let mut target = None;
    let (mut yes, mut purge) = (false, false);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--target" => {
                let v = take_value(it, "--target")?;
                target = Some(v.split(',').map(|s| s.trim().to_string()).collect());
            }
            "--yes" | "-y" => yes = true,
            "--purge" => purge = true,
            "--help" | "-h" => return Ok(Command::HelpFor("uninstall")),
            other => return Err(unexpected(other, "uninstall")),
        }
    }
    Ok(Command::Uninstall { target, yes, purge })
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
     \x20 install                 Wire mootx01 into MCP clients and grant tool permissions.\n\
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
            \x20 --http <port|auto>      Resident HTTP port on 127.0.0.1 (also MOOTX01_HTTP_PORT). 'auto' hunts upward from 4242 to the first free port; an explicit port is exact. When set, runs the resident daemon (HTTP + Brain pump + telemetry) instead of stdio.".into(),
        "install" => "Wire mootx01 into MCP clients and grant tool permissions.\n\
            \n\
            USAGE: mootx01 install [--target <ids>] [--location <scope>] [--yes] [--no-permissions] [--no-mgr] [--no-daemon]\n\
            \n\
            OPTIONS:\n\
            \x20 --target <ids>          Comma-separated client ids to install (e.g. claude,cursor). Default: interactive picker.\n\
            \x20 --location <scope>      Config scope: 'global' (default) or 'local' (project .mcp.json for Claude Code).\n\
            \x20 -y, --yes               Skip prompts; auto-detect and install all present clients.\n\
            \x20 --no-permissions        Skip writing to settings.json (do not grant tool permissions).\n\
            \x20 --no-mgr                Skip registering the moot-mgr management console as a background service.\n\
            \x20 --no-daemon             Skip registering the resident mootx01 daemon (HTTP MCP server + Brain pump) as a background service.".into(),
        "uninstall" => "Remove mootx01 from MCP clients.\n\
            \n\
            USAGE: mootx01 uninstall [--target <ids>] [--yes] [--purge]\n\
            \n\
            OPTIONS:\n\
            \x20 --target <ids>          Comma-separated client ids to uninstall. Default: all detected.\n\
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
                no_permissions: true,
                no_mgr: true,
                no_daemon: true,
            }
        );
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
