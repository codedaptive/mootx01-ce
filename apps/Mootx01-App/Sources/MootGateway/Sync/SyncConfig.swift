// SyncConfig.swift
//
// Runtime sync configuration for the Moot estate.
//
// DISABLED BY DEFAULT: the static `.disabled` factory is the production
// default. Sync only activates when an operator explicitly passes
// `.cloudKitDefault` (or a custom `SyncConfig`) to the app's lifecycle.
// This default was chosen because:
//   - The CloudKit container is not yet provisioned in the default build;
//     a misconfigured enabled-by-default would throw at every launch.
//   - iCloud sync should be an explicit opt-in for a first release; a
//     "works correctly but does nothing" default is easier to ship safely
//     than "tries to sync to a container that doesn't exist."
//
// Sensitivity ceiling (syncCeiling):
//   Rows with an `adjective_bitmap` sensitivity tier ABOVE syncCeiling
//   are suppressed from outbound sync and rejected on inbound applies.
//   The default ceiling (`.elevated`) means normal and elevated rows sync
//   freely; restricted and secret rows are gated by SensitivityFilteredStorage.
//
//   This satisfies the ADR-025 privacy guarantee at the sync boundary:
//   restricted and secret content does not cross device boundaries via
//   iCloud without the operator explicitly raising the ceiling.
//
// Playground Rules note:
//   Rule 2 requires one SyncManifest per estate. The manifest is compiled
//   at enable time (MootEstateSyncManifest.standard()) — SyncConfig carries
//   the ceiling and backend choice, not the manifest itself. The manifest
//   is constructed in SyncController.enable() from MootEstateSyncManifest.

import Foundation
import LocusKit

/// Runtime sync configuration for a Moot estate.
///
/// Build a `SyncConfig` and pass it to `MootSyncDriver.configure(_:)` at
/// app launch (or in test setup) to activate iCloud sync. Omitting
/// configuration leaves the driver in the `disabled` default.
///
/// ## Default
///
/// `SyncConfig.disabled` — no sync, no CloudKit account check, no entitlement
/// requirement. Safe to ship without a provisioned iCloud container.
///
/// ## CloudKit
///
/// ```swift
/// let config = SyncConfig.cloudKitDefault
/// await MootSyncDriver.shared.configure(config)
/// ```
///
/// Raises the `enabled` flag, sets `backend` to `.cloudKit` with the
/// production container identifier, and leaves `syncCeiling` at `.elevated`
/// (restricted and secret rows are not synced).
public struct SyncConfig: Sendable {

    /// The sync transport backend.
    ///
    /// - `none`: Sync is administratively disabled. No CloudKit calls are made.
    /// - `cloudKit(containerIdentifier:)`: Use `CloudKitSyncEngine` with the
    ///   named container. The container must be declared in entitlements.
    public enum Backend: Sendable {
        /// No backend — sync is disabled. SyncController.enable() is not called.
        case none
        /// CloudKit backend. The container identifier must match the entitlement.
        case cloudKit(containerIdentifier: String)
    }

    /// The transport backend for this configuration.
    public let backend: Backend

    /// The sensitivity ceiling applied to both outbound and inbound sync.
    ///
    /// Rows whose `adjective_bitmap` sensitivity tier is ABOVE this value are:
    ///   - Outbound: suppressed from the sync outbox (never pushed to CloudKit)
    ///   - Inbound: rejected via `SensitivityCeilingError` (counted as conflict)
    ///
    /// Default: `.elevated` — normal and elevated rows sync; restricted and
    /// secret rows do not.
    ///
    /// Operators targeting a high-trust device scope (e.g. end-to-end-encrypted
    /// enterprise deployment) may raise the ceiling to `.restricted` or even
    /// `.secret`, but this requires corresponding CloudKit encrypted-values
    /// support (tracked follow-up, CVK-ICLOUD P5-M1 Discoveries).
    public let syncCeiling: AdjectiveSensitivity

    /// Whether sync is administratively enabled. False causes MootSyncDriver
    /// to skip enable entirely, regardless of `backend`.
    public let enabled: Bool

    public init(
        backend: Backend,
        syncCeiling: AdjectiveSensitivity = .elevated,
        enabled: Bool
    ) {
        self.backend = backend
        self.syncCeiling = syncCeiling
        self.enabled = enabled
    }

    // MARK: - Factory configurations

    /// No sync. This is the production default.
    ///
    /// MootSyncDriver starts with this configuration and never activates
    /// unless the app explicitly calls `configure(_:)` with a different value.
    /// Safe to ship without any iCloud entitlement or container.
    public static let disabled = SyncConfig(
        backend: .none,
        syncCeiling: .elevated,
        enabled: false
    )

    /// CloudKit sync with the production container, ceiling at `.elevated`.
    ///
    /// Requires:
    ///   - `iCloud.com.codedaptive.mootx01` declared in entitlements
    ///   - CloudKit container provisioned in the Apple Developer portal
    ///   - iCloud account signed in on device
    ///
    /// When any of the above is missing, `MootSyncDriver.syncNow()` degrades
    /// gracefully: the engine throws at `enable()`, the driver logs the error,
    /// stays disabled, and retries on the next beat.
    public static let cloudKitDefault = SyncConfig(
        backend: .cloudKit(containerIdentifier: MootSyncDriver.containerIdentifier),
        syncCeiling: .elevated,
        enabled: true
    )
}
