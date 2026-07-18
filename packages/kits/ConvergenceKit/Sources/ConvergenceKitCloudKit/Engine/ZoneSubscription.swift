// ZoneSubscription.swift
//
// Opt-in CKRecordZoneSubscription registration for the CloudKit engine.
//
// WHY OPT-IN (NOT AUTOMATIC):
// The resident launchd process cannot hold APNs entitlements; silent-push
// zone wakeups only reach host-app processes (moot-mgr, Mootx01-App).
// Zone subscriptions are therefore an OPTIONAL latency accelerator, not
// part of the correctness path. Polling (AdaptivePollScheduler, P3-M2)
// remains the guarantee. See CONVERGENCEKIT_SPEC.md § 5 B-11.
//
// IDEMPOTENCY:
// The subscription ID is deterministically derived from the zone name:
//   "ck-zone-wake-<zoneIdentifier>"
// Calling registerZoneSubscription() more than once saves the same
// subscription ID; CloudKit returns success (the server deduplicates by ID),
// so the call is safe to repeat (e.g. on every app launch without tracking
// whether subscription was already registered).
//
// HOST APP CONTRACT:
// 1. Declare the `com.apple.developer.icloud-services` → CloudKit entitlement.
// 2. Register for remote notifications with UIApplication/NSApplication (host
//    app responsibility — the kit does NOT touch UIApplication/NSApplication).
// 3. Call engine.registerZoneSubscription() after engine.enable() succeeds.
// 4. Forward notification payloads via engine.handleRemoteNotification(userInfo:)
//    from AppDelegate.application(_:didReceiveRemoteNotification:fetchCompletionHandler:).
// See CONVERGENCEKIT_INTERFACE.md §2 CloudKit — Host-app subscription contract.
//
// NO APP-ONLY IMPORTS:
// This file imports only Foundation and CloudKit so the ConvergenceKitCloudKit
// target builds unchanged for the resident (no UIKit, no AppKit, no SwiftUI).
// The host app owns UIApplication/NSApplication registration; the kit owns
// only the CKSubscription lifecycle.
//
// SPEC: CONVERGENCEKIT_SPEC.md § 5 B-11 (convergence loop — zone subscription accelerator).
// INTERFACE: CONVERGENCEKIT_INTERFACE.md §2 CloudKit — ZoneSubscription.

import Foundation
import CloudKit
import ConvergenceKit

// MARK: - CloudKitStateActor extension

extension CloudKitStateActor {

    // MARK: - Subscription ID derivation

    /// Fixed subscription ID derived from the zone name.
    ///
    /// Using a deterministic ID makes registration idempotent: saving the same
    /// ID to CloudKit a second time is a no-op on the server, so the host app
    /// can call `registerZoneSubscription()` on every launch without checking
    /// whether it was already registered.
    static func zoneSubscriptionID(for zoneName: String) -> CKSubscription.ID {
        "ck-zone-wake-\(zoneName)"
    }

    // MARK: - Register

    /// Create (or confirm) a silent-push `CKRecordZoneSubscription` for the
    /// manifest's zone.
    ///
    /// - The subscription uses `shouldSendContentAvailable: true` (silent push,
    ///   no user-visible alert, no badge, no sound). The host app's notification
    ///   registration must include the background-fetch capability.
    /// - The subscription ID is fixed (`ck-zone-wake-<zoneIdentifier>`) so
    ///   repeated calls are idempotent.
    /// - Routes through the `CloudKitDatabaseProtocol` seam so tests can verify
    ///   subscription saves without a live CloudKit container.
    ///
    /// Throws `SyncError.notEnabled` if the engine has not been enabled.
    func registerZoneSubscription() async throws {
        guard isEnabled, let manifest, let database else { throw SyncError.notEnabled }

        let zoneID = CKRecordZone.ID(
            zoneName: manifest.zoneIdentifier,
            ownerName: CKCurrentUserDefaultName
        )
        let subscriptionID = Self.zoneSubscriptionID(for: manifest.zoneIdentifier)

        let subscription = CKRecordZoneSubscription(
            zoneID: zoneID,
            subscriptionID: subscriptionID
        )

        // Silent push: no alert, no badge, no sound.
        // shouldSendContentAvailable = true wakes the app in background when
        // CloudKit detects a zone change. The host app forwards the payload
        // to handleRemoteNotification(userInfo:).
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        // Explicitly clear user-facing notification fields so this subscription
        // never produces an alert even if the subscription is misconfigured or
        // CloudKit's defaults change.
        notificationInfo.shouldBadge = false
        subscription.notificationInfo = notificationInfo

        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
    }

    // MARK: - Deregister

    /// Remove the zone subscription for the manifest's zone.
    ///
    /// Safe to call even if no subscription exists — CloudKit returns success
    /// for deletes of absent subscription IDs. Routes through the
    /// `CloudKitDatabaseProtocol` seam.
    ///
    /// Throws `SyncError.notEnabled` if the engine has not been enabled.
    func deregisterZoneSubscription() async throws {
        guard isEnabled, let manifest, let database else { throw SyncError.notEnabled }

        let subscriptionID = Self.zoneSubscriptionID(for: manifest.zoneIdentifier)
        _ = try await database.modifySubscriptions(saving: [], deleting: [subscriptionID])
    }
}

// MARK: - CloudKitSyncEngine public surface

extension CloudKitSyncEngine {

    /// Register a silent-push `CKRecordZoneSubscription` for this engine's zone.
    ///
    /// Call after `enable()` succeeds. Idempotent: repeated calls save the
    /// same subscription ID — safe to call on every app launch.
    ///
    /// **Host app responsibilities before calling:**
    /// 1. Declare the `com.apple.developer.icloud-services` → CloudKit entitlement.
    /// 2. Register for remote notifications (UIApplication.registerForRemoteNotifications()
    ///    or equivalent). The kit does not call UIApplication/NSApplication.
    /// 3. Forward notification payloads via `handleRemoteNotification(userInfo:)`.
    ///
    /// **Degradation guarantee:** if the subscription is never registered,
    /// or if APNs delivery is delayed or dropped, polling continues unchanged.
    /// All correctness guarantees of the engine rely solely on polling (B-11).
    public func registerZoneSubscription() async throws {
        try await stateActor.registerZoneSubscription()
    }

    /// Remove the zone subscription for this engine's zone.
    ///
    /// Safe to call even if no subscription is currently registered.
    /// After this returns, no further silent-push notifications will arrive
    /// for this zone until `registerZoneSubscription()` is called again.
    public func deregisterZoneSubscription() async throws {
        try await stateActor.deregisterZoneSubscription()
    }
}
