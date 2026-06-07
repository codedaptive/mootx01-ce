// ManagerConfig.swift
//
// Configuration for the moot-mgr manager process: the stats-store path and
// the retention window. Both resolve from the environment with documented
// defaults so the manager is zero-config out of the box but overridable for
// tests and alternate deployments.
//
// Design (MANAGER_1.0_PLAN.md §1, §4, §5):
//   - Store path: env MOOT_MGR_STORE overrides; default under the app-support
//     data dir at <data-dir>/moot-mgr/stats.sqlite, reusing the com.mootx01.ce
//     bundle convention for the data directory.
//   - Retention window: env MOOT_MGR_RETENTION_SECONDS overrides; default 7 days.
//   - Retention cadence: env MOOT_MGR_RETENTION_CADENCE_SECONDS overrides;
//     default 1 hour. This is how often the retention loop wakes (Phase 1 runs
//     a one-shot pass via the CLI; the cadence is carried for the resident loop).

import Foundation

// MARK: - ManagerConfig

/// Resolved configuration for a `MootManager` instance.
///
/// Construct with `ManagerConfig.fromEnvironment()` to apply the documented
/// env overrides and defaults, or call the memberwise initialiser directly
/// in tests for full control.
public struct ManagerConfig: Sendable, Equatable {

    // MARK: - Environment variable names

    /// Env var overriding the stats-store file path.
    public static let storePathEnvKey = "MOOT_MGR_STORE"

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

    /// The app-support subdirectory name and the SQLite file name. The manager
    /// owns exactly one store file: <data-dir>/moot-mgr/stats.sqlite.
    public static let storeSubdirectory = "moot-mgr"
    public static let storeFileName = "stats.sqlite"

    /// The bundle-style data-dir convention reused for the manager's store
    /// location. Matches the `com.mootx01.ce` convention so the manager's
    /// data sits alongside other MOOTx01 CE data.
    public static let dataDirBundleID = "com.mootx01.ce"

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
    /// - `MOOT_MGR_STORE` (non-empty) → that exact path; otherwise
    ///   `<app-support>/moot-mgr/stats.sqlite`.
    /// - `MOOT_MGR_RETENTION_SECONDS` (parseable positive integer) → that window;
    ///   otherwise `defaultRetentionWindow` (7 days). A non-parseable or
    ///   non-positive value falls back to the default (no silent zero window —
    ///   a zero window would roll off everything immediately).
    /// - `MOOT_MGR_RETENTION_CADENCE_SECONDS` → likewise, default 1 hour.
    ///
    /// - Parameter environment: The environment map (injectable for tests).
    /// - Returns: A resolved `ManagerConfig`.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ManagerConfig {
        let storeURL = resolveStoreURL(environment)
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

    /// Resolve the store URL: explicit env override, else the app-support default.
    private static func resolveStoreURL(_ environment: [String: String]) -> URL {
        if let raw = environment[storePathEnvKey], !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }
        // Default: <app-support>/com.mootx01.ce/moot-mgr/stats.sqlite.
        // FileManager resolves the platform app-support directory (macOS:
        // ~/Library/Application Support; Linux Swift: ~/.local/share via the
        // same API). Falling back to the temporary directory keeps the manager
        // functional even if app-support is unavailable (headless CI).
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(dataDirBundleID, isDirectory: true)
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
