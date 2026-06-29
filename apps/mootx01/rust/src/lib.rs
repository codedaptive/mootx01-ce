//! mootx01_cli — library root for the Rust `mootx01` binary.
//!
//! Everything lives in the library (the binary is a thin shell) so tests can
//! exercise the full parse→dispatch path without spawning a process — the
//! same discipline as moot-mgr's manager_cli.rs.
//!
//! Module map:
//!   cli       — argv → typed Command, help text, exit-code policy (§2, §4, §5)
//!   commands  — one module per subcommand (§4.1–§4.8)
//!   core      — installer-core: paths, client registry, config merge,
//!               backups, permissions, database manager, service backends
//!               (ported from Swift MootInstallerCore against shared
//!               conformance vectors)

pub mod cli;
pub mod commands;
pub mod core;

/// Semver for the installed binary. Reported by `--version`; compared by the
/// online upgrade path against the latest release tag. The Swift equivalent
/// is `Mootx01.currentVersion` in the Swift CLI entrypoint.
pub const CURRENT_VERSION: &str = "1.0.5";

/// Exit codes per spec §5.
pub mod exit {
    /// Success (including "Already up to date").
    pub const OK: u8 = 0;
    /// Operational failure: bad estate name, daemon unreachable, checksum
    /// mismatch, malformed config.
    pub const FAILURE: u8 = 1;
    /// Usage error: unknown subcommand, bad flag, missing argument.
    pub const USAGE: u8 = 64;
}
