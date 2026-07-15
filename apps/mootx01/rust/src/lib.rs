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

/// Bare semver for the installed binary. Compared numerically by the online
/// upgrade path against the latest release tag, so it stays a pure semver;
/// `--version` prints it alongside `RELEASE_DATE`. The Swift equivalent is
/// `Mootx01.currentVersion` in the Swift CLI entrypoint.
///
/// Derived from Cargo.toml at compile time — Cargo.toml is the single source
/// (CI's candidate/release meta reads it too). A hand-bumped literal here once
/// lagged a release bump and shipped a binary reporting the prior version.
pub const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Release date stamp printed next to the version by `--version`. Must match
/// the Swift port's `Mootx01.releaseDate` so both binaries print an identical
/// `--version` line.
pub const RELEASE_DATE: &str = "2026-07-14";

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
