// SyncPolicy.swift
// Persisted user preference for iCloud sync (CVK-WB2, FAB5-SM).
//
// Pattern: pure-function enum with UserDefaults keys, matching MenuBarPolicy
// for menu-bar headless mode (M-MXA-7). The SwiftUI master switch in
// SettingsView binds via @AppStorage(SyncPolicy.masterEnabledKey); app startup
// calls migrateIfNeeded() then configure() via isEnabled().
//
// Default: false — sync is administratively off until the user enables it in
// Settings. This matches the MootSyncDriver.disabled default and avoids
// iCloud calls (and entitlement requirement) on builds without a provisioned
// container.
//
// Migration: the WB2 toggle key ("iCloudSyncEnabled") migrates once to the
// master key ("iCloudMasterEnabled") on first launch after FAB5-SM ships.
// Call migrateIfNeeded() before isEnabled() at app startup.

import Foundation
import LocusKit

/// Persisted user preference for iCloud sync.
///
/// `masterEnabledKey` is the authoritative gate consumed by the sync driver
/// (FAB5-SM). `defaultsKey` is the legacy CVK-WB2 key retained as the
/// migration source — migrated once by `migrateIfNeeded(defaults:)`.
///
/// ## Pattern
///
/// Same shape as `MenuBarPolicy` (M-MXA-7): a pure-function enum with key
/// constants and an `isEnabled(defaults:)` reader, testable with a custom
/// `UserDefaults` suite. The SwiftUI master switch binds via
/// `@AppStorage(SyncPolicy.masterEnabledKey)`.
///
/// ## Default
///
/// `false` — sync is off until the user explicitly enables it in Settings.
/// A first-run device that has never seen this key makes no CloudKit calls
/// and requires no iCloud container entitlement.
public enum SyncPolicy {

    /// Authoritative UserDefaults key for the iCloud sync master gate (FAB5-SM).
    ///
    /// Used by `@AppStorage(SyncPolicy.masterEnabledKey)` in SettingsView and
    /// SyncTileView, and by `isEnabled(defaults:)` at app launch. This is the
    /// single source of truth — all sync-enabling logic reads this key.
    public static let masterEnabledKey = "iCloudMasterEnabled"

    /// Legacy CVK-WB2 toggle key — retained as migration source only.
    ///
    /// Not used for new reads. `migrateIfNeeded(defaults:)` copies its value to
    /// `masterEnabledKey` once, then clears it. Kept public so existing test
    /// suites can reference it during migration verification.
    public static let defaultsKey = "iCloudSyncEnabled"

    /// One-time migration from the CVK-WB2 toggle key to the master gate key.
    ///
    /// Call this at app startup before `isEnabled(defaults:)`. Safe to call
    /// repeatedly: a no-op when `masterEnabledKey` is already present (migration
    /// already ran) or when both keys are absent (fresh install, stays false).
    ///
    /// - Parameter defaults: The `UserDefaults` suite to migrate. Defaults to
    ///   `.standard`; pass a custom suite in tests.
    public static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        // Skip if master key already exists — migration already ran.
        guard defaults.object(forKey: masterEnabledKey) == nil else { return }
        // Carry forward the WB2 value if one was stored; otherwise leave absent
        // (first run stays false via the ?? false in isEnabled).
        if let legacy = defaults.object(forKey: defaultsKey) as? Bool {
            defaults.set(legacy, forKey: masterEnabledKey)
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// Reads the master sync gate. Returns `false` when the key is absent
    /// (first run or cleared defaults — safe default, no CloudKit calls).
    ///
    /// Call `migrateIfNeeded(defaults:)` before this at app startup to ensure
    /// any legacy WB2 value is already in place.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to query. Defaults to
    ///   `.standard`; pass a custom suite in tests.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: masterEnabledKey) as? Bool ?? false
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

    /// Returns the set of sensitivity tiers currently authorized for sync.
    ///
    /// Normal and elevated are always included (the always-on base tiers that sync
    /// whenever master sync is enabled). Restricted and secret are included only when
    /// the user has granted per-tier authorization via `TierAuthorizationStore` (FAB5-ST).
    ///
    /// - Parameter store: The authorization store to query. Defaults to `.shared`.
    public static func authorizedTiers(store: TierAuthorizationStore = .shared) async -> Set<AdjectiveSensitivity> {
        var tiers: Set<AdjectiveSensitivity> = [.normal, .elevated]
        if await store.isAuthorized(.restricted) { tiers.insert(.restricted) }
        if await store.isAuthorized(.secret) { tiers.insert(.secret) }
        return tiers
    }
}
