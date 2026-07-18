// SyncPolicy.swift
// Persisted user preference for iCloud sync (CVK-WB2).
//
// Pattern: pure-function enum with a UserDefaults key, matching MenuBarPolicy
// for menu-bar headless mode (M-MXA-7). The SwiftUI layer binds via
// @AppStorage(SyncPolicy.defaultsKey); app startup calls configure() directly.
//
// Default: false — sync is administratively off until the user enables it in
// the Engine tab. This matches the MootSyncDriver.disabled default and avoids
// iCloud calls (and entitlement requirement) on builds without a provisioned
// container.

import Foundation

/// Persisted user preference for iCloud sync.
///
/// One UserDefaults key gates whether `MootSyncDriver` starts configured for
/// CloudKit or stays in its `disabled` default. The setting is consulted at
/// app launch and on every toggle change.
///
/// ## Pattern
///
/// Same shape as `MenuBarPolicy` (M-MXA-7): a pure-function enum with a
/// `defaultsKey` constant and an `isEnabled(defaults:)` reader, testable
/// with a custom `UserDefaults` suite. The SwiftUI toggle binds via
/// `@AppStorage(SyncPolicy.defaultsKey)`.
///
/// ## Default
///
/// `false` — sync is off until the user explicitly enables it. A first-run
/// device that has never seen this key behaves identically to a build that
/// has never been configured for sync: no CloudKit calls, no entitlement
/// requirement, no iCloud account check.
public enum SyncPolicy {

    /// UserDefaults key for the iCloud sync user setting.
    ///
    /// Used by `@AppStorage(SyncPolicy.defaultsKey)` in the toggle view
    /// and by `isEnabled(defaults:)` at app launch.
    public static let defaultsKey = "iCloudSyncEnabled"

    /// Reads the current setting. Returns `false` when the key is absent
    /// (first run or cleared defaults).
    ///
    /// - Parameter defaults: The `UserDefaults` suite to query. Defaults to
    ///   `.standard`; pass a custom suite in tests.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? false
    }

    /// Returns the `SyncConfig` corresponding to `enabled`.
    ///
    /// - `true` → `SyncConfig.cloudKitDefault` (production container, ceiling `.elevated`)
    /// - `false` → `SyncConfig.disabled` (no CloudKit calls)
    ///
    /// Pass the result directly to `MootSyncDriver.shared.configure(_:)`.
    public static func config(enabled: Bool) -> SyncConfig {
        enabled ? .cloudKitDefault : .disabled
    }
}
