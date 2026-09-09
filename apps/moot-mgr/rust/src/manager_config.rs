// manager_config.rs — Rust twin of the Swift ManagerConfig.swift.
//
// Configuration for the moot-mgr manager process: the stats-store path and the
// retention window/cadence. The store path resolves from the product settings
// file (`daemon.stats_store` in `<config-dir>/config.json`) with a computed
// default fallback. The retention window and cadence resolve from environment
// variables.
//
//   - Store path: `daemon.stats_store` in config.json (R6, 2026-09-09) overrides;
//     computed default `<configuration>/moot-mgr/stats.sqlite`. No env override.
//   - Retention window: env MOOT_MGR_RETENTION_SECONDS overrides; default 7 days.
//   - Retention cadence: env MOOT_MGR_RETENTION_CADENCE_SECONDS overrides;
//     default 1 hour.

use std::collections::HashMap;
use std::path::Path;

/// Env var overriding the retention window, in whole seconds.
pub const RETENTION_WINDOW_ENV_KEY: &str = "MOOT_MGR_RETENTION_SECONDS";
/// Env var overriding the retention-loop cadence, in whole seconds.
pub const RETENTION_CADENCE_ENV_KEY: &str = "MOOT_MGR_RETENTION_CADENCE_SECONDS";

/// Default retention window: 7 days (in whole seconds). Mirrors Swift
/// `ManagerConfig.defaultRetentionWindow`.
pub const DEFAULT_RETENTION_WINDOW_SECS: i64 = 7 * 24 * 60 * 60;
/// Default retention cadence: 1 hour. Mirrors Swift
/// `ManagerConfig.defaultRetentionCadence`.
pub const DEFAULT_RETENTION_CADENCE_SECS: i64 = 60 * 60;

/// The configuration-directory subdirectory name and the SQLite file name.
pub const STORE_SUBDIRECTORY: &str = "moot-mgr";
pub const STORE_FILE_NAME: &str = "stats.sqlite";

/// Resolved configuration for a `MootManager` instance. Mirrors Swift
/// `ManagerConfig`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagerConfig {
    /// Filesystem path of the SQLite stats store the manager owns.
    pub store_path: String,
    /// Retention window in whole seconds.
    pub retention_window_secs: i64,
    /// Retention-loop cadence in whole seconds.
    pub retention_cadence_secs: i64,
}

impl ManagerConfig {
    /// Memberwise constructor for explicit configuration (used by tests).
    pub fn new(
        store_path: impl Into<String>,
        retention_window_secs: i64,
        retention_cadence_secs: i64,
    ) -> Self {
        ManagerConfig {
            store_path: store_path.into(),
            retention_window_secs,
            retention_cadence_secs,
        }
    }

    /// Resolve configuration from the process environment, applying defaults.
    /// Mirrors Swift `ManagerConfig.fromEnvironment()`.
    pub fn from_environment() -> Self {
        let env: HashMap<String, String> = std::env::vars().collect();
        Self::from_environment_map(&env, None)
    }

    /// Resolve configuration from an injected environment map and an optional
    /// configuration directory. Mirrors Swift
    /// `ManagerConfig.fromEnvironment(_:configurationDirectory:)`.
    ///
    /// - `env`: the environment map (injectable for tests).
    /// - `config_dir`: the directory that contains `config.json`. Pass `None`
    ///   in production (uses the product default). Pass `Some(dir)` in tests
    ///   to inject a scratch directory without touching the real config file.
    pub fn from_environment_map(
        env: &HashMap<String, String>,
        config_dir: Option<&Path>,
    ) -> Self {
        let store_path = resolve_store_path(config_dir);
        let window = resolve_positive_secs(
            env.get(RETENTION_WINDOW_ENV_KEY),
            DEFAULT_RETENTION_WINDOW_SECS,
        );
        let cadence = resolve_positive_secs(
            env.get(RETENTION_CADENCE_ENV_KEY),
            DEFAULT_RETENTION_CADENCE_SECS,
        );
        ManagerConfig {
            store_path,
            retention_window_secs: window,
            retention_cadence_secs: cadence,
        }
    }
}

/// Resolve the store path: `config.json` setting, else the computed default.
///
/// Precedence (highest to lowest):
///   1. `daemon.stats_store` key in `<config-dir>/config.json` (R6 setting,
///      2026-09-09): a changeable setting that `mootx01 install` seeds and
///      operators can edit. Mirrors Swift `ManagerConfig.resolveStoreURL`.
///   2. `<configuration>/moot-mgr/stats.sqlite` — the same file the resident
///      daemon's `stats_store_path` resolves when the setting is absent.
///
/// The `config_dir` parameter is the directory containing `config.json`.
/// Pass `None` in production. Pass `Some(dir)` in tests to inject a scratch
/// directory without touching the developer's real configuration file.
fn resolve_store_path(config_dir: Option<&Path>) -> String {
    // No env tier: the setting is the variable (W-6 ruling, 2026-09-09).
    let owned;
    let dir: &Path = match config_dir {
        Some(p) => p,
        None => {
            owned = moot_product_identity::storage::configuration_directory();
            &owned
        }
    };
    // R6: check config.json for an operator-defined path before the default.
    // Reading through the injected directory makes this testable without
    // touching the developer's real configuration file.
    if let Some(p) = moot_product_identity::settings::load(dir).daemon_stats_store {
        return p;
    }
    // Default: <configuration>/moot-mgr/stats.sqlite, the same path the
    // resident daemon's stats_store_path resolves when the setting is absent,
    // so both processes open the same store out of the box.
    moot_product_identity::paths::daemon_stats_store_default(dir)
}

/// Parse a positive whole-second interval, falling back to `default` on absent /
/// non-numeric / non-positive input. Mirrors Swift
/// `ManagerConfig.resolvePositiveInterval`.
fn resolve_positive_secs(raw: Option<&String>, default: i64) -> i64 {
    match raw.and_then(|s| s.parse::<i64>().ok()) {
        Some(secs) if secs > 0 => secs,
        _ => default,
    }
}
