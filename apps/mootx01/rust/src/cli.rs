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
//! `parse` itself is unchanged by the argv0 dispatch below — that dispatch
//! runs BEFORE `parse` sees the args (main.rs), so this invariant still
//! holds for every caller that reaches `parse` with a non-empty args slice.
//!
//! argv0 dispatch (Wave 6 addendum, `resolve_argv0_dispatch`): two routes,
//! evaluated in this order:
//!
//! 1. `mootx01-botLink` (BL-2): NAMESPACING route — prepend `"botlink"` to
//!    the raw args regardless of whether args is empty or not. A leading
//!    explicit `"botlink"` is left untouched (no double-prepend). This fires
//!    for ARGS-CARRYING invocations too: `mootx01-botLink ping` becomes
//!    `["botlink","ping"]`. Evaluated FIRST because it applies unconditionally.
//!
//! 2. `mootx01-proxy`: BARE-INVOCATION default — fires only when args is
//!    empty AND the basename matches. ProxyCommand takes no subcommands so the
//!    bare-only default is the whole surface; explicit args always pass through
//!    unchanged.
//!
//! Mirrors Swift's `ArgvDispatch.resolvedArguments` (MootInstallerCore).
//! Rust has no bare-pipe → `serve` default (that half of the Swift function
//! does not apply here, per this file's own §2 spec citation).

use std::fmt;

/// `mootx01 botlink` subcommand selector (BL-2).
#[derive(Debug, Clone, PartialEq)]
pub enum BotLinkSub {
    /// `botlink ping` — liveness + identity: moot_estate_ping + transport attribution.
    Ping,
    /// `botlink list` — emit the MCP tools/list result object; cursors followed internally.
    List,
    /// `botlink call <verb>` — one ARIA tool call; stdout is the raw MCP result object.
    Call {
        verb: String,
        /// `--args <json>` base object (optional).
        args_json: Option<String>,
        /// All remaining tokens (captured verbatim for KV parsing in the engine).
        /// Mirrors Swift's `@Argument(parsing: .allUnrecognized)` on `remaining`.
        kv: Vec<String>,
    },
    /// `botlink rpc [frame]` — forward one raw JSON-RPC frame and print the response.
    Rpc {
        /// The frame as a positional argument; None = read from stdin to EOF.
        frame: Option<String>,
    },
}

/// A fully parsed invocation.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// §4.1 serve [--db <name>|<dir>/<name>] [--http <port|auto>] [--frozen] [--in-memory]
    Serve { db: Option<String>, http: Option<HttpMode>, frozen: bool, in_memory: bool },
    /// §4.2 install [--target <ids>] [--location global|local] [--yes]
    ///              [--mode server|skills|plugin]
    ///              [--grant-permissions] [--no-permissions] [--no-mgr] [--no-daemon]
    ///              [--vault-on | --vault-off] [--reuse-db | --replace-db] [--no-encrypt]
    Install {
        target: Option<Vec<String>>,
        location: Location,
        yes: bool,
        /// Write EVERY tool to permissions.allow (full auto-approval). Without it
        /// the install writes TIERED defaults (allow/ask/deny by capability).
        grant_permissions: bool,
        no_permissions: bool,
        no_mgr: bool,
        no_daemon: bool,
        /// True when vault is enabled (default). False when --vault-off is passed.
        /// --vault-on is a no-op (vault is on by default) but is accepted for
        /// symmetry and to let users be explicit. If both flags are given,
        /// vault_on=false (--vault-off wins — the safer choice).
        vault_on: bool,
        /// Integration depth (§4.4). None when `--mode` was not supplied — the
        /// command then prompts (interactive) or defaults to plugin (`--yes` /
        /// non-interactive). Some(_) when `--mode server|skills|plugin` is given.
        depth: Option<InstallDepthArg>,
        /// What to do when an estate database already exists at install time.
        /// None → prompt when interactive, leave everything untouched when not.
        /// Some(Reuse) → adopt the existing database as the default estate and
        /// reset the moot-mgr history store. Some(Replace) → move the existing
        /// default estate and the moot-mgr store to the platform trash so a
        /// fresh database is created on first serve.
        db: Option<ExistingDbArg>,
        /// Record the at-rest encryption opt-out for the DEFAULT estate
        /// (marker file beside the estate; honored on first create only).
        /// Default is encrypted; `mootx01 upgrade` encrypts an opted-out
        /// estate later. Same flag shape as `db create --no-encrypt`.
        no_encrypt: bool,
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
    /// §4.6 query <verb> [--db <name>|<dir>/<name>] [--json] [-- <args...>]
    Query { verb: String, db: Option<String>, json: bool, args: Vec<String> },
    /// botlink <ping|list|call|rpc> [--http <url>] [--db <name>]
    BotLink { sub: BotLinkSub, http: Option<String>, db: Option<String> },
    /// §4.7 proxy [--daemon-url <url>]
    Proxy { daemon_url: Option<String> },
    /// drain [--db <name>] — finish draining an estate's encode queue, then exit
    /// (the detached background finisher an stdio serve spawns on exit; T5).
    Drain { db: Option<String> },
    /// dream [--db <name>] — run one REM-ALPHA dreaming cycle, then exit
    /// (the detached background finisher an stdio serve spawns on startup/exit
    /// when the dreaming queue has pending items;  / recall-driven dreaming).
    Dream { db: Option<String> },
    /// §4.8 upgrade [--from <path>] [--db <name>|<dir>/<name>] [--check] [--yes] [--no-restart] [--backfill-only]
    Upgrade { from: Option<String>, db: Option<String>, check: bool, yes: bool, no_restart: bool, converge_only: bool, backfill_only: bool },
    /// out-of-band sensitivity grants unlock <private|secret>
    /// Authenticate and issue an in-RAM sensitivity-tier grant to the daemon.
    /// "private" maps to the restricted tier; "secret" to the secret tier.
    /// Always operates on the active estate's daemon; --db has no spec entry.
    Unlock { tier: String },
    /// out-of-band sensitivity grants lock — revoke all sensitivity grants (no auth required).
    Lock,
    /// enable <feature> [--yes] [--ingest-all]
    ///
    /// Supported features:
    ///   memory-tool      Anthropic memory_20250818 adapter — governed /memories backend
    ///   harness-memory   Route Claude Code project-memory writes into the estate
    Enable { feature: String, yes: bool, ingest_all: bool },
    /// disable <feature> [--yes] [--restore-all | --no-restore]
    ///
    /// Supported features: same set as `enable`.
    Disable { feature: String, yes: bool, restore_all: bool, no_restore: bool },
    /// hook-capture — Claude Code PreToolUse hook entry point.
    ///
    /// Reads the tool-call JSON payload from stdin, captures memory writes to
    /// the estate, and outputs an allow/deny JSON decision to stdout.  Called
    /// by the hook script installed at ~/.mootx01/hooks/capture-harness-memory.sh.
    /// Not intended for direct user invocation.
    HookCapture,
    /// codex-hook <event> — Codex lifecycle adapter entry point.
    CodexHook { event: String },
    /// codex-memory doctor — Codex/MOOT posture diagnostics.
    CodexMemoryDoctor,
    /// codex-memory import-chronicle [--yes] — Chronicle Markdown importer.
    CodexMemoryImportChronicle { yes: bool },
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
    /// `value` is a bare name (registered, at the default location) or
    /// `<dir>/<name>` (unregistered, at that place). `no_encrypt` mirrors
    /// `install --no-encrypt` deliberately: the two estate-creating surfaces
    /// must not disagree about the default.
    Create { value: String, no_encrypt: bool },
    /// Register an existing estate: the same `<value>` shape as create.
    Register { value: String },
    /// Forget a registered estate; its files are untouched.
    Unregister { name: String },
    List,
    Open { name: String },
    Delete { name: String, yes: bool },
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

/// Explicit disposition of a pre-existing estate database at install time
/// (`--reuse-db` / `--replace-db`). Mirrors the Swift InstallCommand flags —
/// both ports must present the same reinstall contract.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ExistingDbArg {
    Reuse,
    Replace,
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

/// The argv0 basename that triggers implicit `proxy` dispatch. Mirrors
/// Swift `ArgvDispatch.proxyInvocationName`.
pub const PROXY_INVOCATION_NAME: &str = "mootx01-proxy";

/// The argv0 basename that triggers `botlink` namespacing dispatch (BL-2).
/// Capital L is deliberate — matches the symlink the installer places beside
/// the binary (`mootx01-botLink → mootx01`). Mirrors Swift
/// `ArgvDispatch.botLinkInvocationName`.
pub const BOTLINK_INVOCATION_NAME: &str = "mootx01-botLink";

/// Resolve argv0-based subcommand dispatch. Two routes evaluated in order —
/// see this module's doc comment for the full rationale.
///
/// Route 1 (mootx01-botLink): NAMESPACING — checked FIRST because it applies
/// to args-carrying invocations too. If basename == mootx01-botLink and the
/// first arg is already "botlink", return args unchanged (no double-prepend).
/// Otherwise prepend "botlink" unconditionally.
///
/// Route 2 (mootx01-proxy): BARE-INVOCATION default — fires only when args is
/// empty AND basename is exactly `mootx01-proxy`.
///
/// - Parameters:
///   - argv0: the invoked program path or name (`std::env::args().next()`;
///     may be absolute, relative, or a bare PATH-resolved name).
///   - args: the arguments AFTER argv0.
/// - Returns: the modified args slice (or args unchanged when neither route
///   fires).
pub fn resolve_argv0_dispatch(argv0: &str, args: &[String]) -> Vec<String> {
    let basename = argv0.rsplit(['/', '\\']).next().unwrap_or(argv0);
    // Route 1: botLink namespacing — evaluated BEFORE the empty-args guard
    // because it fires for args-carrying invocations too.
    if basename == BOTLINK_INVOCATION_NAME {
        // No double-prepend: if the caller already wrote "mootx01-botLink botlink ping",
        // return args as-is so the "botlink" subcommand is not duplicated.
        if args.first().map(|s| s.as_str()) == Some("botlink") {
            return args.to_vec();
        }
        let mut v = vec!["botlink".to_string()];
        v.extend_from_slice(args);
        return v;
    }
    // Route 2: proxy bare-invocation default.
    if args.is_empty() && basename == PROXY_INVOCATION_NAME {
        return vec!["proxy".to_string()];
    }
    args.to_vec()
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
        "botlink" => parse_botlink(&mut it),
        "proxy" => parse_proxy(&mut it),
        "drain" => parse_drain(&mut it),
        "dream" => parse_dream(&mut it),
        "upgrade" => parse_upgrade(&mut it),
        "unlock" => parse_unlock(&mut it),
        "lock" => {
            if let Some(h) = expect_help_or_end(&mut it, "lock")? {
                return Ok(h);
            }
            Ok(Command::Lock)
        }
        "enable" => parse_enable(&mut it),
        "disable" => parse_disable(&mut it),
        "hook-capture" => {
            // No flags — reads everything from stdin.
            if let Some(h) = expect_help_or_end(&mut it, "hook-capture")? {
                return Ok(h);
            }
            Ok(Command::HookCapture)
        }
        "codex-hook" => {
            let event = it.next().ok_or_else(|| UsageError(
                "Error: 'codex-hook' requires an event name.".into()))?.to_string();
            if it.next().is_some() {
                return Err(UsageError("Error: unexpected argument for 'codex-hook'.".into()));
            }
            Ok(Command::CodexHook { event })
        }
        "codex-memory" => {
            let sub = it.next().ok_or_else(|| UsageError(
                "Error: 'codex-memory' requires a subcommand: doctor | import-chronicle".into()))?;
            match sub.as_str() {
                "doctor" => {
                    if let Some(a) = it.next() {
                        if a == "--help" || a == "-h" {
                            return Ok(Command::HelpFor("codex-memory doctor"));
                        }
                        return Err(UsageError(
                            "Error: 'codex-memory doctor' takes no arguments.".into()));
                    }
                    Ok(Command::CodexMemoryDoctor)
                }
                "import-chronicle" => {
                    let mut yes = false;
                    while let Some(arg) = it.next() {
                        match arg.as_str() {
                            "--yes" | "-y" => yes = true,
                            "--help" | "-h" => return Ok(Command::HelpFor("codex-memory import-chronicle")),
                            other => return Err(UsageError(format!(
                                "Error: unknown flag '{other}' for 'codex-memory import-chronicle'."))),
                        }
                    }
                    Ok(Command::CodexMemoryImportChronicle { yes })
                }
                "--help" | "-h" => Ok(Command::HelpFor("codex-memory")),
                other => Err(UsageError(format!(
                    "Error: unknown subcommand '{other}' for 'codex-memory'. Use: doctor | import-chronicle"))),
            }
        }
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
    let (mut db, mut http, mut frozen, mut in_memory) = (None, None, false, false);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--db" => db = Some(take_value(it, "--db")?),
            "--frozen" => frozen = true,
            "--in-memory" => in_memory = true,
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
    Ok(Command::Serve { db, http, frozen, in_memory })
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
    // At-rest encryption opt-out for the default estate. Encrypted is the
    // default; the flag records a marker the open posture honors on create.
    let mut no_encrypt = false;
    // vault_on tracks the net choice: true = vault enabled (the default).
    // --vault-off sets it false; --vault-on is a no-op but is accepted for
    // symmetry. If both appear, --vault-off wins (last-write wins in the loop,
    // but --vault-off always sets false regardless of order, so it dominates).
    let mut vault_on = true;
    // §4.4 integration depth. None until --mode is seen.
    let mut depth: Option<InstallDepthArg> = None;
    // Existing-database disposition. None until --reuse-db/--replace-db is
    // seen; the two flags are mutually exclusive because they resolve the
    // same question in opposite directions.
    let mut db: Option<ExistingDbArg> = None;
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
            "--no-encrypt" => no_encrypt = true,
            // vault surface toggle. --vault-off wins over --vault-on
            // when both are present (the safer choice). --vault-on is explicit
            // opt-in to the default and is accepted for symmetry / scripting.
            "--vault-on" => { /* vault_on already true; explicit for clarity */ }
            "--vault-off" => vault_on = false,
            "--reuse-db" | "--replace-db" => {
                let this = if a == "--reuse-db" { ExistingDbArg::Reuse } else { ExistingDbArg::Replace };
                if matches!(db, Some(prior) if prior != this) {
                    return Err(UsageError(
                        "Error: '--reuse-db' and '--replace-db' are mutually exclusive.".into(),
                    ));
                }
                db = Some(this);
            }
            "--help" | "-h" => return Ok(Command::HelpFor("install")),
            other => return Err(unexpected(other, "install")),
        }
    }
    Ok(Command::Install { target, location, yes, grant_permissions, no_permissions, no_mgr, no_daemon, vault_on, depth, db, no_encrypt })
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
                "Error: 'db' requires a subcommand: create, register, unregister, list, open, delete.".into(),
            ))
        }
        Some(s) => s.as_str(),
    };
    match sub {
        "create" => {
            let value = take_value(it, "db create <name>|<dir>/<name>")?;
            // create takes flags, so it parses a flag loop rather than
            // expect_help_or_end: --no-encrypt is the same opt-out shape
            // as `install --no-encrypt`.
            let mut no_encrypt = false;
            while let Some(a) = it.next() {
                match a.as_str() {
                    "--no-encrypt" => no_encrypt = true,
                    "--help" | "-h" => return Ok(Command::HelpFor("db")),
                    other => return Err(unexpected(other, "db create")),
                }
            }
            Ok(Command::Db(DbCommand::Create { value, no_encrypt }))
        }
        "register" => {
            let value = take_value(it, "db register <name>|<dir>/<name>")?;
            if let Some(h) = expect_help_or_end(it, "db")? {
                return Ok(h);
            }
            Ok(Command::Db(DbCommand::Register { value }))
        }
        "unregister" => {
            let name = take_value(it, "db unregister <name>")?;
            if let Some(h) = expect_help_or_end(it, "db")? {
                return Ok(h);
            }
            Ok(Command::Db(DbCommand::Unregister { name }))
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
            let mut yes = false;
            while let Some(a) = it.next() {
                match a.as_str() {
                    "--yes" | "-y" => yes = true,
                    other => return Err(unexpected(other, "db delete")),
                }
            }
            Ok(Command::Db(DbCommand::Delete { name, yes }))
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

/// Parse `mootx01 botlink <ping|list|call|rpc> [--http <url>] [--db <name>]`.
///
/// Subcommand is the first token; missing or unknown → UsageError (exit 64).
/// "botlink --help" → HelpFor("botlink").
///
/// - ping / list: accept only --http, --db, --help; any other token → UsageError.
/// - call: REQUIRED first positional verb (missing → UsageError); then --args,
///   --http, --db, --help are recognized; EVERY other token (flags and
///   positionals alike, in order) is collected verbatim into kv. This mirrors
///   Swift's @Argument(parsing: .allUnrecognized) — kv tokens are NOT validated
///   at parse time.
/// - rpc: optional single positional frame; --http/--db/--help; a second
///   positional or unknown flag → UsageError.
fn parse_botlink(it: &mut Args) -> Result<Command, UsageError> {
    let sub_str = match it.next() {
        None => return Err(UsageError(
            "Error: 'botlink' requires a subcommand: ping, list, call, rpc.\n\n\
             Use 'mootx01 botlink --help' for usage.".into()
        )),
        Some(s) if s == "--help" || s == "-h" => return Ok(Command::HelpFor("botlink")),
        Some(s) => s.as_str(),
    };

    match sub_str {
        "ping" => {
            match parse_botlink_simple_options(it, "botlink ping", "botlink ping")? {
                BotLinkSimpleOptions::Help(page) => Ok(Command::HelpFor(page)),
                BotLinkSimpleOptions::Options { http, db } => {
                    Ok(Command::BotLink { sub: BotLinkSub::Ping, http, db })
                }
            }
        }
        "list" => {
            match parse_botlink_simple_options(it, "botlink list", "botlink list")? {
                BotLinkSimpleOptions::Help(page) => Ok(Command::HelpFor(page)),
                BotLinkSimpleOptions::Options { http, db } => {
                    Ok(Command::BotLink { sub: BotLinkSub::List, http, db })
                }
            }
        }
        "call" => parse_botlink_call(it),
        "rpc" => parse_botlink_rpc(it),
        other => {
            // Mirrors Swift ArgumentParser: honour --help ahead of unknown-subcommand
            // validation. Consume remaining tokens; if any is --help or -h, return the
            // generic botlink help page rather than erroring (reviewer finding F-1,
            // measured cross-port: `mootx01 botlink install --help` must exit 0).
            let remaining: Vec<&String> = it.collect();
            if remaining.iter().any(|t| *t == "--help" || *t == "-h") {
                return Ok(Command::HelpFor("botlink"));
            }
            Err(UsageError(format!(
                "Error: unknown 'botlink' subcommand '{other}'. Use: ping | list | call | rpc"
            )))
        }
    }
}

/// Result of parsing `--http` / `--db` / `--help` for the `ping` and `list`
/// subcommands. `Help` carries the HelpFor page key for the specific subcommand
/// (e.g. "botlink ping") so per-subcommand help is returned (reviewer F-3).
/// `Options` carries the parsed flags otherwise.
enum BotLinkSimpleOptions {
    Options { http: Option<String>, db: Option<String> },
    Help(&'static str),
}

/// Parse --http / --db / --help for ping and list. Returns
/// Ok(BotLinkSimpleOptions::Help(help_page)) on --help, where help_page is the
/// per-subcommand HelpFor key (e.g. "botlink ping"). Any unrecognized token →
/// UsageError (mirrors Swift ArgumentParser strictness for commands with no
/// @Argument(parsing: .allUnrecognized)).
fn parse_botlink_simple_options(
    it: &mut Args,
    cmd: &'static str,
    help_page: &'static str,
) -> Result<BotLinkSimpleOptions, UsageError> {
    let (mut http, mut db) = (None, None);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--http" => http = Some(take_value(it, "--http")?),
            "--db" => db = Some(take_value(it, "--db")?),
            "--help" | "-h" => return Ok(BotLinkSimpleOptions::Help(help_page)),
            other => return Err(UsageError(format!(
                "Error: unexpected argument '{other}' for '{cmd}'."
            ))),
        }
    }
    Ok(BotLinkSimpleOptions::Options { http, db })
}

fn parse_botlink_call(it: &mut Args) -> Result<Command, UsageError> {
    // verb is the first token; must be present and must not start with "--".
    let verb = match it.next() {
        None => return Err(UsageError(
            "Error: 'botlink call' requires a verb, e.g. 'mootx01 botlink call memory_search'.".into()
        )),
        Some(v) if v == "--help" || v == "-h" => return Ok(Command::HelpFor("botlink call")),
        Some(v) if v.starts_with("--") => return Err(UsageError(format!(
            "Error: 'botlink call' requires a verb before flags, got '{v}'."
        ))),
        Some(v) => v.to_string(),
    };
    let (mut http, mut db, mut args_json) = (None, None, None);
    let mut kv: Vec<String> = Vec::new();
    // Collect remaining tokens: recognized flags consumed here; everything
    // else goes verbatim into kv (mirrors .allUnrecognized — NOT validated).
    while let Some(a) = it.next() {
        match a.as_str() {
            "--http" => http = Some(take_value(it, "--http")?),
            "--db" => db = Some(take_value(it, "--db")?),
            "--args" => args_json = Some(take_value(it, "--args")?),
            "--help" | "-h" => return Ok(Command::HelpFor("botlink call")),
            other => {
                // Unrecognized flag or positional: collect verbatim into kv.
                kv.push(other.to_string());
                // If this was a flag (starts with "--"), also peek and collect
                // its value if it does not itself start with "--".
                if other.starts_with("--") {
                    if let Some(next) = it.peek() {
                        if !next.starts_with("--") {
                            kv.push(it.next().unwrap().to_string());
                        }
                    }
                }
            }
        }
    }
    Ok(Command::BotLink { sub: BotLinkSub::Call { verb, args_json, kv }, http, db })
}

fn parse_botlink_rpc(it: &mut Args) -> Result<Command, UsageError> {
    let (mut http, mut db) = (None, None);
    let mut frame: Option<String> = None;
    while let Some(a) = it.next() {
        match a.as_str() {
            "--http" => http = Some(take_value(it, "--http")?),
            "--db" => db = Some(take_value(it, "--db")?),
            "--help" | "-h" => return Ok(Command::HelpFor("botlink rpc")),
            other if other.starts_with("--") => return Err(UsageError(format!(
                "Error: unexpected argument '{other}' for 'botlink rpc'."
            ))),
            other => {
                // First positional is the frame; a second positional is a usage error.
                if frame.is_some() {
                    return Err(UsageError(format!(
                        "Error: unexpected argument '{other}' for 'botlink rpc' (frame already given)."
                    )));
                }
                frame = Some(other.to_string());
            }
        }
    }
    Ok(Command::BotLink { sub: BotLinkSub::Rpc { frame }, http, db })
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
    let mut db = None;
    let (mut check, mut yes, mut no_restart, mut converge_only, mut backfill_only) =
        (false, false, false, false, false);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--from" => from = Some(take_value(it, "--from")?),
            "--db" => db = Some(take_value(it, "--db")?),
            "--check" => check = true,
            "--yes" => yes = true,
            "--no-restart" => no_restart = true,
            // Internal, deliberately absent from `upgrade --help`: the upgrade
            // re-executes the binary it just installed with this flag so the
            // convergence steps run the NEW code. See `upgrade::run`.
            "--converge-only" => converge_only = true,
            // Estate-only convergence for scripted and benchmark estates: run
            // only the estate migration steps against the selected estate,
            // then exit. No network, no service manager, no prompts.
            "--backfill-only" => backfill_only = true,
            "--help" | "-h" => return Ok(Command::HelpFor("upgrade")),
            other => return Err(unexpected(other, "upgrade")),
        }
    }
    Ok(Command::Upgrade { from, db, check, yes, no_restart, converge_only, backfill_only })
}

fn parse_unlock(it: &mut Args) -> Result<Command, UsageError> {
    // First positional argument is the tier name.
    let tier = match it.next() {
        None => {
            return Err(UsageError(
                "Error: 'unlock' requires a tier: 'private' or 'secret'.".into(),
            ))
        }
        Some(v) if v == "--help" || v == "-h" => return Ok(Command::HelpFor("unlock")),
        Some(v) => {
            let s = v.to_lowercase();
            // Validate early so the error message is at parse time, not dispatch time.
            match s.as_str() {
                "private" | "restricted" | "secret" => {}
                _ => {
                    return Err(UsageError(format!(
                        "Error: unknown tier '{v}'. Use 'private' or 'secret'."
                    )))
                }
            }
            s
        }
    };
    while let Some(a) = it.next() {
        match a.as_str() {
            "--help" | "-h" => return Ok(Command::HelpFor("unlock")),
            other => return Err(unexpected(other, "unlock")),
        }
    }
    Ok(Command::Unlock { tier })
}

fn parse_enable(it: &mut Args) -> Result<Command, UsageError> {
    // First positional argument is the feature name.
    let feature = match it.next() {
        None => {
            return Err(UsageError(
                "Error: 'enable' requires a feature name: memory-tool, harness-memory.".into(),
            ))
        }
        Some(v) if v == "--help" || v == "-h" => return Ok(Command::HelpFor("enable")),
        Some(v) => v.to_string(),
    };
    let (mut yes, mut ingest_all) = (false, false);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--yes" | "-y" => yes = true,
            "--ingest-all" => ingest_all = true,
            "--help" | "-h" => return Ok(Command::HelpFor("enable")),
            other => return Err(unexpected(other, "enable")),
        }
    }
    Ok(Command::Enable { feature, yes, ingest_all })
}

fn parse_disable(it: &mut Args) -> Result<Command, UsageError> {
    // First positional argument is the feature name.
    let feature = match it.next() {
        None => {
            return Err(UsageError(
                "Error: 'disable' requires a feature name: memory-tool, harness-memory.".into(),
            ))
        }
        Some(v) if v == "--help" || v == "-h" => return Ok(Command::HelpFor("disable")),
        Some(v) => v.to_string(),
    };
    let (mut yes, mut restore_all, mut no_restore) = (false, false, false);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--yes" | "-y" => yes = true,
            "--restore-all" => {
                if no_restore {
                    return Err(UsageError(
                        "Error: '--restore-all' and '--no-restore' are mutually exclusive.".into(),
                    ));
                }
                restore_all = true;
            }
            "--no-restore" => {
                if restore_all {
                    return Err(UsageError(
                        "Error: '--restore-all' and '--no-restore' are mutually exclusive.".into(),
                    ));
                }
                no_restore = true;
            }
            "--help" | "-h" => return Ok(Command::HelpFor("disable")),
            other => return Err(unexpected(other, "disable")),
        }
    }
    Ok(Command::Disable { feature, yes, restore_all, no_restore })
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
        "botlink" => Ok("botlink"),
        "botlink ping" => Ok("botlink ping"),
        "botlink list" => Ok("botlink list"),
        "botlink call" => Ok("botlink call"),
        "botlink rpc" => Ok("botlink rpc"),
        "proxy" => Ok("proxy"),
        "drain" => Ok("drain"),
        "dream" => Ok("dream"),
        "upgrade" => Ok("upgrade"),
        "unlock" => Ok("unlock"),
        "lock" => Ok("lock"),
        "enable" => Ok("enable"),
        "disable" => Ok("disable"),
        "hook-capture" => Ok("hook-capture"),
        "codex-memory" | "codex-memory doctor" | "codex-memory import-chronicle" => Ok("codex-memory"),
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
     \x20 db                      Manage estate databases.\n\
     \x20 status                  Show server state, active estate, and wired clients.\n\
     \x20 query                   Issue a single ARIA tool call (v1.0: MCP subprocess passthrough).\n\
     \x20 botlink                 One-shot MCP transport for cloud agents (machine JSON stdout, loopback only).\n\
     \x20 proxy                   Proxy stdin JSON-RPC frames to the resident daemon over loopback HTTP (for Claude Desktop).\n\
     \x20 upgrade                 Upgrade mootx01 to the latest release or a local build.\n\
     \x20 unlock                  Authenticate and issue a sensitivity-tier grant (private → midnight; secret → 30 min).\n\
     \x20 lock                    Revoke all sensitivity grants immediately.\n\
     \x20 enable                  Enable an optional feature (memory-tool, harness-memory).\n\
     \x20 disable                 Disable an optional feature (memory-tool, harness-memory).\n\
     \n\
     \x20 See 'mootx01 help <subcommand>' for detailed help."
}

/// Per-subcommand help text. Flag help strings per spec §4.
pub fn subcommand_usage(cmd: &str) -> String {
    match cmd {
        "serve" => "Start the ARIA MCP server (stdio, or resident HTTP when --http / MOOTX01_HTTP_PORT is set).\n\
            \n\
            USAGE: mootx01 serve [--db <name>|<dir>/<name>] [--http <port|auto>] [--frozen] [--in-memory]\n\
            \n\
            OPTIONS:\n\
            \x20 --db <name>|<dir>/<name>  A registered estate by name, or a transient estate at <dir>/<name>/ (plaintext, no identity, forgotten at exit). Default: the active estate.\n\
            \x20 --in-memory             Serve from the in-memory backend: same protocol and algorithms, no filesystem; the estate lives and dies with this process.\n\
            \x20 --http <port|auto>      Resident HTTP port on 127.0.0.1 (also MOOTX01_HTTP_PORT). 'auto' hunts upward from 4242 to the first free port; an explicit port is exact. When set, runs the resident daemon (HTTP + autonomic governor + telemetry) instead of stdio.\n\
            \x20 --frozen                Serve the estate as a read-only snapshot (also MOOTX01_FROZEN=1): no background workers, no recall traces or reward marks, mutating tools refused. stdio only — refused with --http.".into(),
        "install" => "Wire mootx01 into MCP clients.\n\
            \n\
            USAGE: mootx01 install [--target <ids>] [--location <scope>] [--mode <depth>] [--yes] [--grant-permissions] [--no-permissions] [--no-mgr] [--no-daemon] [--vault-on | --vault-off] [--reuse-db | --replace-db] [--no-encrypt]\n\
            \n\
            OPTIONS:\n\
            \x20 --target <ids>          Comma-separated client ids to install (e.g. claude,cursor). Default: interactive picker.\n\
            \x20 --location <scope>      Config scope: 'global' (default) or 'local' (project .mcp.json for Claude Code).\n\
            \x20 --mode <depth>          Integration depth for every selected client: 'server' (MCP only), 'skills' (server + mootx01-memory skill), or 'plugin' (server + native plugin). Default: prompt when interactive, else 'plugin'. Plugin falls back to skills on hosts without a plugin format.\n\
            \x20 -y, --yes               Skip prompts; auto-detect and install all present clients.\n\
            \x20 --grant-permissions     Write EVERY tool to permissions.allow (full auto-approval). Default is tiered: diagnostics allow, reads/writes ask, destructive deny.\n\
            \x20 --no-permissions        Do not write tool permissions at all (skips the tiered default).\n\
            \x20 --no-mgr                Skip registering the moot-mgr management console as a background service.\n\
            \x20 --no-daemon             Wire clients directly to `mootx01 serve` over stdio and skip registering the resident HTTP daemon. Stop an existing resident for socket-free MCP operation.\n\
            \x20 --vault-on              Enable Vault MCP tools (moot_vault_*). Default behavior: vault is on when neither flag is specified.\n\
            \x20 --vault-off             Hide Vault MCP tools from the MCP surface. Disables import/export for a more secure install position.\n\
            \x20 --reuse-db              When an estate database already exists: adopt it as the default estate and reset the moot-mgr history store (no prompt).\n\
            \x20 --replace-db            When an estate database already exists: move it and the moot-mgr history to the platform trash so a fresh database is created on first serve. Asks for a typed confirmation unless --yes.\n\
            \x20 --no-encrypt            Create the default estate WITHOUT at-rest encryption (records a marker honored on first create; an existing estate is never re-postured). Default is encrypted. Run `mootx01 upgrade` at any time to encrypt an unencrypted estate.".into(),
        "uninstall" => "Remove mootx01 from MCP clients.\n\
            \n\
            USAGE: mootx01 uninstall [--target <ids>] [--location <scope>] [--yes] [--purge]\n\
            \n\
            OPTIONS:\n\
            \x20 --target <ids>          Comma-separated client ids to uninstall. Default: all detected.\n\
            \x20 --location <scope>      Config scope: 'global', 'local', or omitted for both. Local removes Claude Code project .mcp.json and .claude/settings.json.\n\
            \x20 -y, --yes               Skip prompts; uninstall from all detected clients.\n\
            \x20 --purge                 Also remove all estate databases and the moot-mgr history (moved to the platform trash after a typed confirmation; --yes skips the prompt). Full uninstall only.".into(),
        "db" => "Manage estate databases.\n\
            \n\
            USAGE: mootx01 db <create|register|unregister|list|open|delete>\n\
            \n\
            A bare <name> means the default database location under the configuration directory; <dir>/<name> means exactly that place.\n\
            \n\
            SUBCOMMANDS:\n\
            \x20 create <name> [--no-encrypt]        Create an estate at the default location and register it. --no-encrypt creates it WITHOUT at-rest encryption (default is encrypted); run `mootx01 upgrade` at any time to encrypt it later.\n\
            \x20 create <dir>/<name> --no-encrypt    Create an unregistered (plaintext) estate at that place; attach it with `--db <dir>/<name>`.\n\
            \x20 register <name>|<dir>/<name>        Register an existing estate in the catalog. Its files are not touched.\n\
            \x20 unregister <name>                   Forget a registered estate. Its files are not touched.\n\
            \x20 list                                List the registered estates, active first.\n\
            \x20 open <name>                         Make a registered estate the active one (used by serve, drain, dream, query and status).\n\
            \x20 delete <name> [-y]                  Delete a registered estate: its files and its record. Cannot delete the active estate or 'default' (use uninstall --purge).".into(),
        "status" => "Show server state, active estate, and wired clients.\n\
            \n\
            USAGE: mootx01 status".into(),
        "query" => "Issue a single ARIA tool call (v1.0: MCP subprocess passthrough).\n\
            \n\
            USAGE: mootx01 query <verb> [--db <name>|<dir>/<name>] [--json] [<args>...]\n\
            \n\
            ARGUMENTS:\n\
            \x20 <verb>                  ARIA verb name without moot_ prefix, e.g. 'drawer_recall'.\n\
            \x20 <args>                  Tool arguments as --key value pairs.\n\
            \n\
            OPTIONS:\n\
            \x20 --db <name>|<dir>/<name>  Estate to query: a registered name, or <dir>/<name> for a transient estate (forces the subprocess path). Default: the active estate.\n\
            \x20 --json                  Output raw JSON instead of human-readable text.\n\
            \n\
            If you are a cloud agent that cannot reach `127.0.0.1` on the user's\n\
            machine and MCP `moot_*` tools are absent, use `mootx01-botLink` on the\n\
            user's computer. Do not use `mootx01 query`. Do not open a remote MCP\n\
            URL. If `moot_*` MCP tools exist (Cursor on the Mac), use those and\n\
            stop.".into(),
        "botlink" => "One-shot MCP transport for cloud agents (machine JSON stdout, loopback only).\n\
            \n\
            USAGE: mootx01 botlink <ping|list|call|rpc> [--http <url>] [--db <name>]\n\
            \n\
            SUBCOMMANDS:\n\
            \x20 ping                    Liveness + identity: moot_estate_ping plus transport attribution.\n\
            \x20 list                    Emit the MCP tools/list result object; cursors are followed internally.\n\
            \x20 call                    Issue one ARIA tool call; stdout is the raw MCP result object.\n\
            \x20 rpc                     Forward one raw JSON-RPC frame (argument or stdin) and print the response frame.\n\
            \n\
            OPTIONS:\n\
            \x20 --http <url>            Resident daemon base URL override (loopback required, e.g. http://127.0.0.1:4242). Dev only.\n\
            \x20 --db <name>             Named estate; forces the serve-subprocess path.\n\
            \n\
            The explicit AI data path for a cloud agent whose only channel to this\n\
            Mac is a permissioned one-shot shell. One invocation performs one MCP\n\
            operation against the local estate and exits. stdout is exactly one JSON\n\
            value — no banners, no log lines; diagnostics go to stderr. Exit codes:\n\
            0 success, 2 tool error (isError true), 1 transport failure, 64 usage /\n\
            non-loopback --http. The estate never leaves this Mac: botLink talks to\n\
            the loopback daemon or spawns a local serve subprocess, nothing else.".into(),
        "botlink ping" => "Liveness + identity: moot_estate_ping plus transport attribution.\n\
            \n\
            USAGE: mootx01 botlink ping [--http <url>] [--db <name>]\n\
            \n\
            OPTIONS:\n\
            \x20 --http <url>            Resident daemon base URL override (loopback required, e.g. http://127.0.0.1:4242). Dev only.\n\
            \x20 --db <name>             Named estate; forces the serve-subprocess path.".into(),
        "botlink list" => "Emit the MCP tools/list result object; cursors are followed internally.\n\
            \n\
            USAGE: mootx01 botlink list [--http <url>] [--db <name>]\n\
            \n\
            OPTIONS:\n\
            \x20 --http <url>            Resident daemon base URL override (loopback required, e.g. http://127.0.0.1:4242). Dev only.\n\
            \x20 --db <name>             Named estate; forces the serve-subprocess path.".into(),
        "botlink call" => "Issue one ARIA tool call; stdout is the raw MCP result object.\n\
            \n\
            USAGE: mootx01 botlink call <verb> [--args <json>] [--http <url>] [--db <name>] [--key value ...]\n\
            \n\
            ARGUMENTS:\n\
            \x20 <verb>                  ARIA verb name without moot_ prefix, e.g. 'memory_search'.\n\
            \x20 [--key value ...]       Additional tool arguments as --key value pairs.\n\
            \n\
            OPTIONS:\n\
            \x20 --args <json>           Base argument object as JSON (--key value pairs override on collision).\n\
            \x20 --http <url>            Resident daemon base URL override (loopback required, e.g. http://127.0.0.1:4242). Dev only.\n\
            \x20 --db <name>             Named estate; forces the serve-subprocess path.".into(),
        "botlink rpc" => "Forward one raw JSON-RPC frame (argument or stdin) and print the response frame.\n\
            \n\
            USAGE: mootx01 botlink rpc [<frame>] [--http <url>] [--db <name>]\n\
            \n\
            ARGUMENTS:\n\
            \x20 [<frame>]               JSON-RPC 2.0 frame as a string. Omit to read from stdin to EOF.\n\
            \n\
            OPTIONS:\n\
            \x20 --http <url>            Resident daemon base URL override (loopback required, e.g. http://127.0.0.1:4242). Dev only.\n\
            \x20 --db <name>             Named estate; forces the serve-subprocess path.".into(),
        "proxy" => "Proxy stdin JSON-RPC frames to the resident daemon over loopback HTTP (for Claude Desktop).\n\
            \n\
            USAGE: mootx01 proxy [--daemon-url <url>]\n\
            \n\
            OPTIONS:\n\
            \x20 --daemon-url <url>      Resident daemon base URL. Default: read daemon.port file, else http://127.0.0.1:4242.".into(),
        "drain" => "Finish draining an estate's encode queue, then exit. The detached background finisher an stdio serve spawns when it exits with encode work still pending (T5); rarely run by hand.\n\
            \n\
            USAGE: mootx01 drain [--db <name>|<dir>/<name>]\n\
            \n\
            OPTIONS:\n\
            \x20 --db <name>|<dir>/<name>  Named estate or transient path to drain. Default: active estate.".into(),
        "dream" => "Run one REM-ALPHA dreaming cycle, then exit. The detached background finisher an stdio serve spawns on startup or exit when the dreaming queue has pending items; rarely run by hand.\n\
            \n\
            USAGE: mootx01 dream [--db <name>|<dir>/<name>]\n\
            \n\
            OPTIONS:\n\
            \x20 --db <name>|<dir>/<name>  Named estate or transient path to process dreaming jobs for. Default: active estate.".into(),
        "upgrade" => "Upgrade mootx01 to the latest release or a local build.\n\
            \n\
            USAGE: mootx01 upgrade [--from <path>] [--db <name>|<dir>/<name>] [--check] [--yes] [--no-restart] [--backfill-only]\n\
            \n\
            OPTIONS:\n\
            \x20 --from <path>           Path to the new binary to install (skips online check).\n\
            \x20 --db <name>|<dir>/<name>  Estate to upgrade: a registered name, or <dir>/<name> for a transient estate. Default: the active estate. A transient estate gets the estate migration steps only.\n\
            \x20 --check                 Print the latest available version and exit without downloading.\n\
            \x20 --yes                   Skip the confirmation prompt before downloading a new release.\n\
            \x20 --no-restart            Copy the binary but skip restarting the background agents.\n\
            \x20 --backfill-only         Run only the estate migration steps (schema 10 → 20 and 19 → 20, kg_facts identity, projection backfill, shared-content reclaim, whole-record vacuum, ssc facts, dense pooling convergence, span encode, vector reclaim) then exit. No network, no service manager, no prompts — for scripted and benchmark estates.".into(),
        "unlock" => "Authenticate and issue a sensitivity-tier grant to the resident daemon.\n\
            \n\
            USAGE: mootx01 unlock <private|secret>\n\
            \n\
            ARGUMENTS:\n\
            \x20 private                 Grant access to restricted-tier rows until local midnight.\n\
            \x20 secret                  Grant access to secret-tier rows for 30 minutes.\n\
            \n\
            Authentication (Linux/Windows): verifies the tier-specific PBKDF2 password stored in\n\
            <dataDir>/sensitivity_hashes.json. Use `mootx01 lock` to revoke immediately.".into(),
        "lock" => "Revoke all sensitivity grants immediately (no authentication required).\n\
            \n\
            USAGE: mootx01 lock\n\
            \n\
            Calls the daemon's /api/control/lock endpoint and clears any active restricted\n\
            and secret grants for the current session. Reducing your own access is always\n\
            permitted — no identity verification is needed.".into(),
        "enable" => "Enable an optional feature on mootx01.\n\
            \n\
            USAGE: mootx01 enable <feature> [--yes] [--ingest-all]\n\
            \n\
            FEATURES:\n\
            \x20 memory-tool          Anthropic memory_20250818 adapter — governed /memories backend.\n\
            \x20                      Linux/Windows: sets MOOTX01_MEMORY_TOOL=1 in ~/.mootx01/features.env.\n\
            \x20 harness-memory       Harness Memory Mode — routes Claude Code memories into the MOOTx01 estate.\n\
            \x20                      Disables Claude Code auto-memory, installs a PreToolUse capture hook,\n\
            \x20                      and merges memory-governance text into ~/.claude/CLAUDE.md.\n\
            \x20                      Requires a reachable estate daemon (mootx01 serve). Consent-gated.\n\
            \n\
            OPTIONS:\n\
            \x20 -y, --yes            Skip confirmation prompts.\n\
            \x20 --ingest-all         Ingest all existing ~/.claude/projects/*/memory/ files without\n\
            \x20                      per-project prompts (harness-memory only). MOVE semantics:\n\
            \x20                      estate write confirmed before source deletion.".into(),
        "disable" => "Disable an optional feature on mootx01.\n\
            \n\
            USAGE: mootx01 disable <feature> [--yes] [--restore-all | --no-restore]\n\
            \n\
            FEATURES:\n\
            \x20 memory-tool          Remove MOOTX01_MEMORY_TOOL from ~/.mootx01/features.env.\n\
            \x20 harness-memory       Remove the capture hook, restore auto-memory setting, remove sentinel\n\
            \x20                      block from CLAUDE.md. Offers per-project restore of estate memories\n\
            \x20                      to ~/.claude/projects/*/memory/ (estate records kept forever).\n\
            \n\
            OPTIONS:\n\
            \x20 -y, --yes            Skip confirmation prompts.\n\
            \x20 --restore-all        Restore all harness memories to disk without per-project prompts.\n\
            \x20 --no-restore         Skip the restore offer entirely.".into(),
        "hook-capture" => "Claude Code PreToolUse hook entry point (not for direct use).\n\
            \n\
            USAGE: mootx01 hook-capture\n\
            \n\
            Reads a Claude Code PreToolUse JSON payload from stdin, intercepts writes\n\
            targeting ~/.claude/projects/*/memory/, posts the content to the MOOTx01\n\
            estate, then outputs an allow/deny JSON decision to stdout.\n\
            \n\
            Called automatically by the hook script installed at\n\
            ~/.mootx01/hooks/capture-harness-memory.sh when Harness Memory Mode is\n\
            enabled. Daemon-down fallback: ALLOW (estate write is preferred, but a\n\
            stray disk file is recoverable via the next ingest sweep).".into(),
        "codex-memory" => "Codex memory diagnostics and Chronicle import.\n\
            \n\
            USAGE: mootx01 codex-memory <subcommand>\n\
            \n\
            SUBCOMMANDS:\n\
            \x20 doctor               Report Codex/MOOT ownership, native memory settings, Chronicle, and estate posture.\n\
            \x20 import-chronicle     Import Codex Chronicle Markdown files as unconfirmed MOOT memories.\n\
            \n\
            OPTIONS (import-chronicle):\n\
            \x20 -y, --yes            Skip the confirmation prompt.".into(),
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

    // MARK: - resolve_argv0_dispatch (Wave 6 addendum)

    fn dispatch(argv0: &str, args: &[&str]) -> Vec<String> {
        let v: Vec<String> = args.iter().map(|x| x.to_string()).collect();
        resolve_argv0_dispatch(argv0, &v)
    }

    #[test]
    fn argv0_proxy_basename_with_no_args_injects_proxy() {
        assert_eq!(dispatch("/usr/local/bin/mootx01-proxy", &[]), vec!["proxy".to_string()]);
        assert_eq!(dispatch("mootx01-proxy", &[]), vec!["proxy".to_string()]);
        // Windows-style separator.
        assert_eq!(dispatch(r"C:\Users\dev\mootx01-proxy.exe", &[]), Vec::<String>::new(),
            "a .exe suffix does not match the exact basename — documents the current exact-match behavior");
    }

    #[test]
    fn argv0_proxy_basename_with_explicit_args_untouched() {
        assert_eq!(dispatch("mootx01-proxy", &["install", "--yes"]), vec!["install".to_string(), "--yes".to_string()]);
    }

    #[test]
    fn bare_invocation_with_non_proxy_argv0_is_untouched() {
        assert_eq!(dispatch("mootx01", &[]), Vec::<String>::new());
        // Still reaches parse()'s unconditional usage-error path (§2).
        assert!(parse(&dispatch("mootx01", &[])).is_err());
    }

    #[test]
    fn only_exact_basename_triggers_dispatch() {
        assert_eq!(dispatch("mootx01-proxy-dev", &[]), Vec::<String>::new());
        assert_eq!(dispatch("not-mootx01-proxy", &[]), Vec::<String>::new());
    }

    #[test]
    fn version_flag() {
        assert_eq!(p(&["--version"]).unwrap(), Command::Version);
    }

    #[test]
    fn serve_defaults() {
        assert_eq!(p(&["serve"]).unwrap(), Command::Serve { db: None, http: None, frozen: false, in_memory: false });
        assert_eq!(p(&["serve", "--in-memory"]).unwrap(), Command::Serve { db: None, http: None, frozen: false, in_memory: true });
    }

    #[test]
    fn serve_flags() {
        assert_eq!(
            p(&["serve", "--db", "work", "--http", "4242"]).unwrap(),
            Command::Serve { db: Some("work".into()), http: Some(HttpMode::Port(4242)), frozen: false, in_memory: false }
        );
        assert_eq!(
            p(&["serve", "--http", "auto"]).unwrap(),
            Command::Serve { db: None, http: Some(HttpMode::Auto), frozen: false, in_memory: false }
        );
        assert_eq!(
            p(&["serve", "--frozen", "--db", "clone"]).unwrap(),
            Command::Serve { db: Some("clone".into()), http: None, frozen: true, in_memory: false }
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
                db: None,      // default when --reuse-db/--replace-db is not passed
                no_encrypt: false, // default when --no-encrypt is not passed
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
                db: None,
                no_encrypt: false,
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
                    db: None,
                    no_encrypt: false,
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
                db: None,
                no_encrypt: false,
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
                db: None,
                no_encrypt: false,
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
                db: None,
                no_encrypt: false,
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
    fn install_no_encrypt_flag() {
        // --no-encrypt flips the opt-out on; absent, encrypted is the default.
        assert!(matches!(
            p(&["install", "--no-encrypt"]).unwrap(),
            Command::Install { no_encrypt: true, .. }
        ));
        assert!(matches!(
            p(&["install"]).unwrap(),
            Command::Install { no_encrypt: false, .. }
        ));
    }

    #[test]
    fn db_surface() {
        assert_eq!(p(&["db", "create", "work"]).unwrap(),
                   Command::Db(DbCommand::Create { value: "work".into(), no_encrypt: false }));
        // Same opt-out shape as install --no-encrypt: the two estate-creating
        // surfaces must not disagree about the default.
        assert_eq!(p(&["db", "create", "work", "--no-encrypt"]).unwrap(),
                   Command::Db(DbCommand::Create { value: "work".into(), no_encrypt: true }));
        assert_eq!(p(&["db", "register", "/tmp/x/work"]).unwrap(),
                   Command::Db(DbCommand::Register { value: "/tmp/x/work".into() }));
        assert_eq!(p(&["db", "unregister", "work"]).unwrap(),
                   Command::Db(DbCommand::Unregister { name: "work".into() }));
        assert!(p(&["db", "create", "work", "--bogus"]).is_err());
        assert_eq!(p(&["db", "list"]).unwrap(), Command::Db(DbCommand::List));
        assert_eq!(p(&["db", "open", "work"]).unwrap(),
                   Command::Db(DbCommand::Open { name: "work".into() }));
        assert_eq!(p(&["db", "delete", "work", "-y"]).unwrap(),
                   Command::Db(DbCommand::Delete { name: "work".into(), yes: true }));
        // --force/-f is gone (I2-2); it must now be rejected.
        assert!(p(&["db", "delete", "work", "-f"]).is_err());
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
            Command::Upgrade {
                from: None,
                db: None,
                check: true,
                yes: false,
                no_restart: false,
                converge_only: false,
                backfill_only: false,
            }
        );
    }

    /// `--converge-only` is internal (absent from `upgrade --help`) but must
    /// still parse: the upgrade re-executes the installed binary with it.
    #[test]
    fn upgrade_converge_only_parses() {
        assert_eq!(
            p(&["upgrade", "--converge-only", "--yes"]).unwrap(),
            Command::Upgrade {
                from: None,
                db: None,
                check: false,
                yes: true,
                no_restart: false,
                converge_only: true,
                backfill_only: false,
            }
        );
    }

    /// Help text for `upgrade` must document `--backfill-only` so operators
    /// and scripts can discover the flag.
    #[test]
    fn upgrade_help_mentions_backfill_only() {
        let help = subcommand_usage("upgrade");
        assert!(
            help.contains("--backfill-only"),
            "upgrade help must document --backfill-only; got: {help}"
        );
    }

    /// `--backfill-only` runs only the data-dir migration steps
    /// (kg_facts identity, shared-content reclaim, dense pooling convergence,
    /// distilled representation convergence); no network, no service manager, no prompts.
    /// Exits non-zero when any step fails. Used by scripted and benchmark estates.
    #[test]
    fn upgrade_backfill_only_parses() {
        assert_eq!(
            p(&["upgrade", "--backfill-only"]).unwrap(),
            Command::Upgrade {
                from: None,
                db: None,
                check: false,
                yes: false,
                no_restart: false,
                converge_only: false,
                backfill_only: true,
            }
        );
        // Unknown flags still rejected.
        assert!(p(&["upgrade", "--backfill-only", "--unknown"]).is_err());
    }

    #[test]
    fn unknown_subcommand_is_usage_error() {
        assert!(p(&["frobnicate"]).is_err());
    }

    // out-of-band sensitivity grants unlock / lock

    #[test]
    fn unlock_private_parses() {
        assert_eq!(
            p(&["unlock", "private"]).unwrap(),
            Command::Unlock { tier: "private".into() }
        );
    }

    #[test]
    fn unlock_secret_parses() {
        assert_eq!(
            p(&["unlock", "secret"]).unwrap(),
            Command::Unlock { tier: "secret".into() }
        );
    }

    #[test]
    fn unlock_db_flag_rejected() {
        // --db has no spec entry for unlock (R5); the parser must reject it.
        assert!(p(&["unlock", "private", "--db", "work"]).is_err());
    }

    #[test]
    fn unlock_restricted_alias_normalises() {
        // "restricted" is the internal name; the CLI also accepts it.
        assert_eq!(
            p(&["unlock", "restricted"]).unwrap(),
            Command::Unlock { tier: "restricted".into() }
        );
    }

    #[test]
    fn unlock_unknown_tier_is_usage_error() {
        assert!(p(&["unlock", "public"]).is_err());
    }

    #[test]
    fn unlock_no_tier_is_usage_error() {
        assert!(p(&["unlock"]).is_err());
    }

    #[test]
    fn lock_parses() {
        assert_eq!(p(&["lock"]).unwrap(), Command::Lock);
    }

    #[test]
    fn lock_with_trailing_args_is_usage_error() {
        assert!(p(&["lock", "extra"]).is_err());
    }

    // enable / disable / hook-capture

    #[test]
    fn enable_harness_memory_parses() {
        assert_eq!(
            p(&["enable", "harness-memory"]).unwrap(),
            Command::Enable { feature: "harness-memory".into(), yes: false, ingest_all: false }
        );
    }

    #[test]
    fn enable_harness_memory_with_flags() {
        assert_eq!(
            p(&["enable", "harness-memory", "--yes", "--ingest-all"]).unwrap(),
            Command::Enable { feature: "harness-memory".into(), yes: true, ingest_all: true }
        );
    }

    #[test]
    fn enable_memory_tool_parses() {
        assert_eq!(
            p(&["enable", "memory-tool"]).unwrap(),
            Command::Enable { feature: "memory-tool".into(), yes: false, ingest_all: false }
        );
    }

    #[test]
    fn enable_without_feature_is_usage_error() {
        assert!(p(&["enable"]).is_err());
    }

    #[test]
    fn disable_harness_memory_parses() {
        assert_eq!(
            p(&["disable", "harness-memory"]).unwrap(),
            Command::Disable {
                feature: "harness-memory".into(),
                yes: false,
                restore_all: false,
                no_restore: false,
            }
        );
    }

    #[test]
    fn disable_harness_memory_with_restore_all() {
        assert_eq!(
            p(&["disable", "harness-memory", "--yes", "--restore-all"]).unwrap(),
            Command::Disable {
                feature: "harness-memory".into(),
                yes: true,
                restore_all: true,
                no_restore: false,
            }
        );
    }

    #[test]
    fn disable_harness_memory_with_no_restore() {
        assert_eq!(
            p(&["disable", "harness-memory", "--no-restore"]).unwrap(),
            Command::Disable {
                feature: "harness-memory".into(),
                yes: false,
                restore_all: false,
                no_restore: true,
            }
        );
    }

    #[test]
    fn disable_restore_all_and_no_restore_mutually_exclusive() {
        assert!(p(&["disable", "harness-memory", "--restore-all", "--no-restore"]).is_err());
        assert!(p(&["disable", "harness-memory", "--no-restore", "--restore-all"]).is_err());
    }

    #[test]
    fn disable_without_feature_is_usage_error() {
        assert!(p(&["disable"]).is_err());
    }

    #[test]
    fn hook_capture_parses() {
        assert_eq!(p(&["hook-capture"]).unwrap(), Command::HookCapture);
    }

    #[test]
    fn hook_capture_with_trailing_args_is_usage_error() {
        assert!(p(&["hook-capture", "extra"]).is_err());
    }

    // MARK: - botlink subcommand (BL-2)

    #[test]
    fn botlink_ping_parses() {
        assert_eq!(
            p(&["botlink", "ping"]).unwrap(),
            Command::BotLink { sub: BotLinkSub::Ping, http: None, db: None }
        );
    }

    #[test]
    fn botlink_list_parses() {
        assert_eq!(
            p(&["botlink", "list"]).unwrap(),
            Command::BotLink { sub: BotLinkSub::List, http: None, db: None }
        );
    }

    #[test]
    fn botlink_ping_with_http_and_db() {
        assert_eq!(
            p(&["botlink", "ping", "--http", "http://127.0.0.1:9", "--db", "work"]).unwrap(),
            Command::BotLink {
                sub: BotLinkSub::Ping,
                http: Some("http://127.0.0.1:9".into()),
                db: Some("work".into()),
            }
        );
    }

    #[test]
    fn botlink_ping_unknown_flag_is_usage_error() {
        assert!(p(&["botlink", "ping", "--unknown"]).is_err());
    }

    #[test]
    fn botlink_list_unknown_flag_is_usage_error() {
        assert!(p(&["botlink", "list", "--bogus"]).is_err());
    }

    #[test]
    fn botlink_bare_no_subcommand_is_usage_error() {
        assert!(p(&["botlink"]).is_err());
    }

    #[test]
    fn botlink_help_flag_returns_help_for() {
        // Bare "botlink --help" returns the top-level botlink page (unchanged).
        assert_eq!(p(&["botlink", "--help"]).unwrap(), Command::HelpFor("botlink"));
    }

    // MARK: - F-1: unknown subcommand with --help returns HelpFor("botlink")

    #[test]
    fn botlink_unknown_sub_with_help_returns_help_for_botlink() {
        // Mirrors Swift ArgumentParser: --help is honoured ahead of unknown-subcommand
        // validation (reviewer finding F-1, measured cross-port).
        assert_eq!(p(&["botlink", "install", "--help"]).unwrap(), Command::HelpFor("botlink"));
        assert_eq!(p(&["botlink", "install", "-h"]).unwrap(), Command::HelpFor("botlink"));
        // --help anywhere in the remaining tokens triggers help.
        assert_eq!(p(&["botlink", "frobnicate", "--db", "x", "--help"]).unwrap(), Command::HelpFor("botlink"));
    }

    #[test]
    fn botlink_unknown_sub_without_help_is_usage_error() {
        // Unknown subcommand with no --help still errors (exit 64).
        let err = p(&["botlink", "install"]).unwrap_err();
        assert!(err.0.contains("install"), "error must name the bad subcommand");
    }

    // MARK: - F-3: per-subcommand --help returns scoped HelpFor

    #[test]
    fn botlink_ping_help_returns_scoped_help_for() {
        assert_eq!(p(&["botlink", "ping", "--help"]).unwrap(), Command::HelpFor("botlink ping"));
        assert_eq!(p(&["botlink", "ping", "-h"]).unwrap(), Command::HelpFor("botlink ping"));
    }

    #[test]
    fn botlink_list_help_returns_scoped_help_for() {
        assert_eq!(p(&["botlink", "list", "--help"]).unwrap(), Command::HelpFor("botlink list"));
    }

    #[test]
    fn botlink_call_help_returns_scoped_help_for() {
        // --help before the verb (first token position).
        assert_eq!(p(&["botlink", "call", "--help"]).unwrap(), Command::HelpFor("botlink call"));
        // --help after the verb (inside the kv loop).
        assert_eq!(p(&["botlink", "call", "my_verb", "--help"]).unwrap(), Command::HelpFor("botlink call"));
    }

    #[test]
    fn botlink_rpc_help_returns_scoped_help_for() {
        assert_eq!(p(&["botlink", "rpc", "--help"]).unwrap(), Command::HelpFor("botlink rpc"));
    }

    #[test]
    fn botlink_call_parses_verb_and_kv() {
        let cmd = p(&["botlink", "call", "memory_search", "--limit", "5", "--query", "foo"]).unwrap();
        match cmd {
            Command::BotLink { sub: BotLinkSub::Call { verb, args_json, kv }, http, db } => {
                assert_eq!(verb, "memory_search");
                assert!(args_json.is_none());
                assert!(http.is_none());
                assert!(db.is_none());
                // --limit 5 --query foo collected in kv in order.
                assert_eq!(kv, vec!["--limit", "5", "--query", "foo"]);
            }
            other => panic!("expected BotLink Call, got {other:?}"),
        }
    }

    #[test]
    fn botlink_call_with_args_flag() {
        let cmd = p(&["botlink", "call", "foo", "--args", r#"{"k":1}"#]).unwrap();
        match cmd {
            Command::BotLink { sub: BotLinkSub::Call { verb, args_json, kv }, .. } => {
                assert_eq!(verb, "foo");
                assert_eq!(args_json.as_deref(), Some(r#"{"k":1}"#));
                assert!(kv.is_empty());
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn botlink_call_missing_verb_is_usage_error() {
        assert!(p(&["botlink", "call"]).is_err());
    }

    #[test]
    fn botlink_call_kv_tokens_captured_in_order() {
        // Unrecognized flags + positionals go into kv verbatim.
        let cmd = p(&["botlink", "call", "verb", "--z", "last", "--a", "first"]).unwrap();
        match cmd {
            Command::BotLink { sub: BotLinkSub::Call { kv, .. }, .. } => {
                assert_eq!(kv, vec!["--z", "last", "--a", "first"]);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn botlink_rpc_no_frame_parses() {
        assert_eq!(
            p(&["botlink", "rpc"]).unwrap(),
            Command::BotLink { sub: BotLinkSub::Rpc { frame: None }, http: None, db: None }
        );
    }

    #[test]
    fn botlink_rpc_with_frame() {
        let cmd = p(&["botlink", "rpc", r#"{"jsonrpc":"2.0","id":1,"method":"x","params":{}}"#]).unwrap();
        match cmd {
            Command::BotLink { sub: BotLinkSub::Rpc { frame: Some(f) }, .. } => {
                assert!(f.contains("jsonrpc"));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn botlink_rpc_two_positionals_is_usage_error() {
        assert!(p(&["botlink", "rpc", "frame1", "frame2"]).is_err());
    }

    #[test]
    fn botlink_rpc_unknown_flag_is_usage_error() {
        assert!(p(&["botlink", "rpc", "--bogus"]).is_err());
    }

    // MARK: - resolve_argv0_dispatch botLink routes (BL-2)

    #[test]
    fn argv0_botlink_bare_injects_botlink() {
        // (mootx01-botLink, []) -> ["botlink"]
        assert_eq!(
            dispatch("mootx01-botLink", &[]),
            vec!["botlink".to_string()]
        );
    }

    #[test]
    fn argv0_botlink_with_ping_prepends() {
        // (mootx01-botLink, ["ping"]) -> ["botlink", "ping"]
        assert_eq!(
            dispatch("mootx01-botLink", &["ping"]),
            vec!["botlink".to_string(), "ping".to_string()]
        );
    }

    #[test]
    fn argv0_botlink_no_double_prepend() {
        // (mootx01-botLink, ["botlink", "ping"]) -> unchanged
        assert_eq!(
            dispatch("mootx01-botLink", &["botlink", "ping"]),
            vec!["botlink".to_string(), "ping".to_string()]
        );
    }

    #[test]
    fn argv0_botlink_help_flag_prepended() {
        // (mootx01-botLink, ["--help"]) -> ["botlink", "--help"]
        assert_eq!(
            dispatch("mootx01-botLink", &["--help"]),
            vec!["botlink".to_string(), "--help".to_string()]
        );
    }

    #[test]
    fn argv0_botlink_absolute_path_prepends() {
        // (/abs/path/mootx01-botLink, ["ping"]) -> ["botlink", "ping"]
        assert_eq!(
            dispatch("/usr/local/bin/mootx01-botLink", &["ping"]),
            vec!["botlink".to_string(), "ping".to_string()]
        );
    }

    #[test]
    fn argv0_proxy_routes_unchanged_when_botlink_invoked() {
        // Proxy route unchanged: mootx01-proxy bare still injects proxy.
        assert_eq!(
            dispatch("mootx01-proxy", &[]),
            vec!["proxy".to_string()]
        );
        // Proxy with args: unchanged.
        assert_eq!(
            dispatch("mootx01-proxy", &["install"]),
            vec!["install".to_string()]
        );
    }
}
