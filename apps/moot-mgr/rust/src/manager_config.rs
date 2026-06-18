// manager_config.rs — Rust twin of the Swift ManagerConfig.swift.
//
// Configuration for the moot-mgr manager process: the stats-store path and the
// retention window/cadence. All resolve from the environment with documented
// defaults so the manager is zero-config out of the box but overridable for
// tests and alternate deployments.
//
//   - Store path: env MOOT_MGR_STORE overrides; default under the app-support
//     data dir at <data-dir>/com.mootx01.ce/moot-mgr/stats.sqlite.
//   - Retention window: env MOOT_MGR_RETENTION_SECONDS overrides; default 7 days.
//   - Retention cadence: env MOOT_MGR_RETENTION_CADENCE_SECONDS overrides;
//     default 1 hour.

use std::collections::HashMap;
use std::path::PathBuf;

/// Env var overriding the stats-store file path.
pub const STORE_PATH_ENV_KEY: &str = "MOOT_MGR_STORE";
/// Env var overriding the retention window, in whole seconds.
pub const RETENTION_WINDOW_ENV_KEY: &str = "MOOT_MGR_RETENTION_SECONDS";
/// Env var overriding the retention-loop cadence, in whole seconds.
pub const RETENTION_CADENCE_ENV_KEY: &str = "MOOT_MGR_RETENTION_CADENCE_SECONDS";

/// Default retention window: 7 days (in whole seconds). Samples older than
/// `now - window` are rolled off by a retention pass. Mirrors Swift
/// `ManagerConfig.defaultRetentionWindow`.
pub const DEFAULT_RETENTION_WINDOW_SECS: i64 = 7 * 24 * 60 * 60;
/// Default retention cadence: 1 hour. The resident retention loop wakes this
/// often. Mirrors Swift `ManagerConfig.defaultRetentionCadence`.
pub const DEFAULT_RETENTION_CADENCE_SECS: i64 = 60 * 60;

/// The app-support subdirectory name and SQLite file name. The manager owns
/// exactly one store file: <data-dir>/com.mootx01.ce/moot-mgr/stats.sqlite.
pub const STORE_SUBDIRECTORY: &str = "moot-mgr";
pub const STORE_FILE_NAME: &str = "stats.sqlite";
/// The bundle-style data-dir convention reused for the manager's store location.
/// Matches the `com.mootx01.ce` convention so the manager's data sits alongside
/// other MOOTx01 CE data. Mirrors Swift `ManagerConfig.dataDirBundleID`.
pub const DATA_DIR_BUNDLE_ID: &str = "com.mootx01.ce";

/// Resolved configuration for a `MootManager` instance. Mirrors Swift
/// `ManagerConfig`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagerConfig {
    /// Filesystem path of the SQLite stats store the manager owns.
    pub store_path: String,
    /// Retention window in whole seconds. A retention pass deletes samples with
    /// `ts < now - window`.
    pub retention_window_secs: i64,
    /// Retention-loop cadence in whole seconds (how often the resident loop wakes).
    pub retention_cadence_secs: i64,
}

impl ManagerConfig {
    /// Memberwise constructor for explicit configuration (used by tests). Mirrors
    /// the Swift memberwise initialiser.
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
        Self::from_environment_map(&env)
    }

    /// Resolve configuration from an injected environment map (testable seam).
    /// Mirrors the Swift `ManagerConfig.fromEnvironment(_:)` injectable overload.
    pub fn from_environment_map(env: &HashMap<String, String>) -> Self {
        let store_path = resolve_store_path(env);
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

/// Resolve the store path: explicit env override, else the app-support default.
///
/// Default: `<app-support>/com.mootx01.ce/moot-mgr/stats.sqlite`. The
/// per-platform app-support base MUST match `AriaMcpKit`'s
/// `stats_store_path_from_env` so the resident MCP server and this manager
/// resolve the SAME store file and the SAME estates directory:
///   - macOS:   `$HOME/Library/Application Support`
///   - Windows: `%LOCALAPPDATA%` (`%USERPROFILE%\AppData\Local` fallback, `.` last resort)
///   - Linux:   `$XDG_DATA_HOME` or `$HOME/.local/share`
/// A previous Linux-only resolution fell back to the temp dir on Windows, so
/// moot-mgr looked under `%TEMP%` while the MCP server created estates under
/// `%LOCALAPPDATA%` — moot-mgr then "couldn't connect to the databases".
/// Reads from the injected env map so the resolution stays unit-testable.
fn resolve_store_path(env: &HashMap<String, String>) -> String {
    if let Some(raw) = env.get(STORE_PATH_ENV_KEY) {
        if !raw.is_empty() {
            return raw.clone();
        }
    }
    #[cfg(target_os = "macos")]
    let base: PathBuf = env
        .get("HOME")
        .filter(|s| !s.is_empty())
        .map(|h| PathBuf::from(h).join("Library").join("Application Support"))
        .unwrap_or_else(std::env::temp_dir);
    #[cfg(target_os = "windows")]
    let base: PathBuf = env
        .get("LOCALAPPDATA")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env.get("USERPROFILE")
                .filter(|s| !s.is_empty())
                .map(|h| PathBuf::from(h).join("AppData").join("Local"))
        })
        .unwrap_or_else(|| PathBuf::from("."));
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let base: PathBuf = env
        .get("XDG_DATA_HOME")
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env.get("HOME")
                .filter(|s| !s.is_empty())
                .map(|h| PathBuf::from(h).join(".local").join("share"))
        })
        .unwrap_or_else(std::env::temp_dir);
    base.join(DATA_DIR_BUNDLE_ID)
        .join(STORE_SUBDIRECTORY)
        .join(STORE_FILE_NAME)
        .to_string_lossy()
        .into_owned()
}

/// Parse a positive whole-second interval, falling back to `default` on absent /
/// non-numeric / non-positive input. A non-positive window or cadence is
/// rejected because zero would roll off all data instantly and negative is
/// meaningless. Mirrors Swift `ManagerConfig.resolvePositiveInterval`.
fn resolve_positive_secs(raw: Option<&String>, default: i64) -> i64 {
    match raw.and_then(|s| s.parse::<i64>().ok()) {
        Some(secs) if secs > 0 => secs,
        _ => default,
    }
}
