// RemoteWake.swift
//
// Handles CloudKit silent-push notification payloads (remote-wake accelerator).
//
// DESIGN:
// Host apps call handleRemoteNotification(userInfo:) from their AppDelegate's
// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
// The method parses the notification, verifies it targets this engine's zone,
// emits SyncEvent.remoteWakeReceived, and calls nudge() to fire an immediate
// pull and reset the poll tier to fast.
//
// NOTIFICATION PARSING:
// CloudKit zone-subscription silent-push payloads carry the zone name at:
//   userInfo["ck"]["met"]["zid"]
// where "ck" is the CloudKit APS namespace, "met" is the metadata sub-dict,
// and "zid" is the zone identifier string. This path is stable for
// CKRecordZoneSubscription silent-push (shouldSendContentAvailable: true)
// as documented in Apple's CloudKit push payload contract.
//
// Dict-based parsing (rather than CKNotification(fromRemoteNotificationDictionary:))
// is intentional: CKNotification's initializer cannot be constructed from mock
// dicts in unit tests, but the underlying dict format is stable and documented.
// Both paths read the same information; the dict path is testable.
//
// NO APP-ONLY IMPORTS:
// This file imports only Foundation and CloudKit. UIKit, AppKit, and SwiftUI
// are the host app's domain. The kit does not touch UIApplication/NSApplication.
//
// SPEC: CONVERGENCEKIT_SPEC.md § 5 B-3 (event stream), B-11 (convergence loop).
// INTERFACE: CONVERGENCEKIT_INTERFACE.md §2 CloudKit — handleRemoteNotification,
//            Host-app subscription contract.

import Foundation
import CloudKit
import ConvergenceKit

// MARK: - CloudKitSyncEngine extension

extension CloudKitSyncEngine {

    // MARK: - Notification handler

    /// Handle a CloudKit silent-push remote notification.
    ///
    /// Call from:
    /// ```swift
    /// func application(_ application: UIApplication,
    ///                  didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    ///                  fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    ///     Task {
    ///         let consumed = await engine.handleRemoteNotification(userInfo: userInfo)
    ///         completionHandler(consumed ? .newData : .noData)
    ///     }
    /// }
    /// ```
    ///
    /// Returns `true` if the notification was consumed by this engine (it
    /// targeted this engine's zone); `false` if unrelated (wrong zone,
    /// unparseable payload, or engine not enabled). Returning `false` does
    /// NOT mean an error occurred — it means the notification was not for
    /// this engine and the host app can pass it to other handlers.
    ///
    /// On match: emits `SyncEvent.remoteWakeReceived` then calls `nudge()`
    /// to fire an immediate pull and reset the poll tier to fast.
    public func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        // Extract the CloudKit zone name from the push payload.
        // See module comment for the payload dict format.
        guard let zoneName = Self.cloudKitZoneName(from: userInfo) else { return false }

        // Verify the notification targets this engine's zone.
        guard let manifest = await stateActor.manifest,
              zoneName == manifest.zoneIdentifier else { return false }

        // Emit the event BEFORE nudging so subscribers can observe the
        // cause (remote wake) separately from the effect (a pull that
        // follows shortly after).
        await stateActor.emit(.remoteWakeReceived)

        // Nudge: interrupt the poll sleep and fire an immediate pull.
        // If no scheduler is running (enablePolling: false), nudge() fires
        // a one-shot pull directly — the accelerator works in both modes.
        await nudge()

        return true
    }

    // MARK: - Notification payload parser

    /// Extract the CloudKit zone name from a remote notification userInfo dict.
    ///
    /// CloudKit zone-subscription notifications carry zone metadata at:
    ///   `userInfo["ck"]["met"]["zid"]`
    ///
    /// Returns nil for:
    /// - Non-CloudKit push payloads (no "ck" key).
    /// - Non-zone notifications (no "met" sub-dict or no "zid" key).
    /// - Payloads with unexpected key types.
    ///
    /// `internal` (not `private`) so unit tests can drive the parser directly
    /// without constructing a full engine.
    internal static func cloudKitZoneName(from userInfo: [AnyHashable: Any]) -> String? {
        guard let ckDict = userInfo["ck"] as? [String: Any],
              let metDict = ckDict["met"] as? [String: Any],
              let zoneName = metDict["zid"] as? String,
              !zoneName.isEmpty else { return nil }
        return zoneName
    }
}
