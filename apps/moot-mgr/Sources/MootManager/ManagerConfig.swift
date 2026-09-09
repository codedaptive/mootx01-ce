// ManagerConfig.swift
//
// Configuration for the moot-mgr manager process: the stats-store path and
// the retention window. The store path resolves from the product settings file
// (`daemon.stats_store` in `<config-dir>/config.json`) with a computed default
// fallback. The retention window and cadence resolve from environment variables.
//
// Design (MANAGER_1.0_PLAN.md §1, §4, §5):
//   - Store path: `daemon.stats_store` in config.json (R6, 2026-09-09) overrides;
//     computed default `<config-dir>/moot-mgr/stats.sqlite`. No env override.
//   - Retention window: env MOOT_MGR_RETENTION_SECONDS overrides; default 7 days.
//   - Retention cadence: env MOOT_MGR_RETENTION_CADENCE_SECONDS overrides;
//     default 1 hour. This is how often the retention loop wakes (Phase 1 runs
//     a one-shot pass via the CLI; the cadence is carried for the resident loop).

import Foundation
import GeniusLocusKit
import MootProductIdentity

// MARK: - ManagerConfig

/// Resolved configuration for a `MootManager` instance.
///
/// Construct with `ManagerConfig.fromEnvironment()` to apply the documented
/// env overrides and defaults, or call the memberwise initialiser directly
/// in tests for full control.
public struct ManagerConfig: Sendable, Equatable {

    // MARK: - Environment variable names

    /// Env var overriding the retention window, in whole seconds.
    public static let retentionWindowEnvKey = "MOOT_MGR_RETENTION_SECONDS"

    /// Env var overriding the retention-loop cadence, in whole seconds.
    public static let retentionCadenceEnvKey = "MOOT_MGR_RETENTION_CADENCE_SECONDS"

    // MARK: - Defaults

    /// Default retention window: 7 days. Samples older than `now - window`
    /// are rolled off by a retention pass. Seven days keeps a week of
    /// operational history for the dashboard without unbounded growth.
    public static let defaultRetentionWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Default retention cadence: 1 hour. The resident retention loop wakes
    /// this often; the Phase-1 CLI runs a single pass on demand.
    public static let defaultRetentionCadence: TimeInterval = 60 * 60

    /// The configuration-directory subdirectory name and the SQLite file name.
    /// The manager owns exactly one store file:
    /// `<configuration>/moot-mgr/stats.sqlite`, beside the estate catalog.
    public static let storeSubdirectory = "moot-mgr"
    public static let storeFileName = "stats.sqlite"

    // MARK: - Resolved values

    /// Filesystem URL of the SQLite stats store the manager owns.
    public let storeURL: URL

    /// Retention window. A retention pass deletes samples with `ts < now - window`.
    public let retentionWindow: TimeInterval

    /// Retention-loop cadence (how often the resident loop wakes).
    public let retentionCadence: TimeInterval

    // MARK: - Initialisation

    /// Memberwise initialiser for explicit configuration (used by tests).
    ///
    /// - Parameters:
    ///   - storeURL:         Path to the SQLite stats store file.
    ///   - retentionWindow:  Samples older than `now - window` are rolled off.
    ///   - retentionCadence: How often the resident retention loop wakes.
    public init(
        storeURL: URL,
        retentionWindow: TimeInterval = ManagerConfig.defaultRetentionWindow,
        retentionCadence: TimeInterval = ManagerConfig.defaultRetentionCadence
    ) {
        self.storeURL = storeURL
        self.retentionWindow = retentionWindow
        self.retentionCadence = retentionCadence
    }

    // MARK: - Environment resolution

    /// Resolve configuration from the process environment, applying defaults.
    ///
    /// - Store path: `daemon.stats_store` in `config.json` (R6 setting); otherwise
    ///   `<config-dir>/moot-mgr/stats.sqlite`. No environment override for the store
    ///   path — the setting is the variable.
    /// - `MOOT_MGR_RETENTION_SECONDS` (parseable positive integer) → that window;
    ///   otherwise `defaultRetentionWindow` (7 days). A non-parseable or
    ///   non-positive value falls back to the default (no silent zero window —
    ///   a zero window would roll off everything immediately).
    /// - `MOOT_MGR_RETENTION_CADENCE_SECONDS` → likewise, default 1 hour.
    ///
    /// - Parameters:
    ///   - environment:          The environment map (injectable for tests).
    ///   - configurationDirectory: The directory that contains `config.json`.
    ///                             Defaults to `EstateCatalog.configurationDirectory`.
    ///                             Inject a scratch directory in tests.
    /// - Returns: A resolved `ManagerConfig`.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        configurationDirectory: URL = EstateCatalog.configurationDirectory
    ) -> ManagerConfig {
        let storeURL = resolveStoreURL(configurationDirectory: configurationDirectory)
        let window = resolvePositiveInterval(
            environment[retentionWindowEnvKey],
            default: defaultRetentionWindow
        )
        let cadence = resolvePositiveInterval(
            environment[retentionCadenceEnvKey],
            default: defaultRetentionCadence
        )
        return ManagerConfig(
            storeURL: storeURL,
            retentionWindow: window,
            retentionCadence: cadence
        )
    }

    /// Resolve the store URL: `config.json` setting, else the computed default.
    ///
    /// Precedence (highest to lowest):
    ///   1. `daemon.stats_store` key in `<config-dir>/config.json` (R6 setting,
    ///      2026-09-09): a changeable setting so the daemon and moot-mgr can be
    ///      redirected to a non-default store without rebuilding.
    ///   2. The computed default: `<config-dir>/moot-mgr/stats.sqlite`.
    ///
    /// Twin of the Rust `resolve_store_path`. No environment override —
    /// the setting is the variable (W-6 ruling, 2026-09-09). The
    /// `configurationDirectory` parameter makes the settings read testable
    /// without touching the developer's real file.
    private static func resolveStoreURL(
        configurationDirectory: URL = EstateCatalog.configurationDirectory
    ) -> URL {
        // R6: check the product settings file before falling back to the default.
        // Reading through the injected directory makes this testable.
        if let configured = MootProductIdentity.Settings.load(
            configurationDirectory: configurationDirectory
        ).daemonStatsStore {
            return URL(fileURLWithPath: configured)
        }
        // Default: <configuration>/moot-mgr/stats.sqlite, the same path
        // AriaResident.statsStorePath computes when the setting is absent,
        // so the daemon and moot-mgr open the same file out of the box.
        return configurationDirectory
            .appendingPathComponent(storeSubdirectory, isDirectory: true)
            .appendingPathComponent(storeFileName, isDirectory: false)
    }

    /// Parse a positive whole-second interval, falling back to `default` on
    /// absent / non-numeric / non-positive input. A non-positive window or
    /// cadence is rejected because zero would roll off all data instantly and
    /// negative is meaningless — fall back rather than silently misbehave.
    private static func resolvePositiveInterval(
        _ raw: String?,
        default fallback: TimeInterval
    ) -> TimeInterval {
        guard let raw, let seconds = Int(raw), seconds > 0 else { return fallback }
        return TimeInterval(seconds)
    }
}
