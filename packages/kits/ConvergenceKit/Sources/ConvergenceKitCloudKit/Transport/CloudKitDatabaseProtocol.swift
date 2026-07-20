// CloudKitDatabaseProtocol.swift
//
// Minimal protocol seam over the CKDatabase operations used by
// CloudKitStateActor's push, pull, slot-claim, and epoch-fence paths.
// Enables test injection without requiring a live CloudKit container.
//
// WHY A SEAM:
// CKDatabase cannot be constructed or subclassed in tests. Every call site
// that reaches container.privateCloudDatabase directly is opaque to unit
// tests. This protocol makes each operation injectable so tests can script
// slot registry snapshots, CAS outcomes, and zone-change payloads without
// network access or an iCloud account.
//
// P4-M1 FOUNDATION: this seam is the injection point the P4 integration-test
// series will use for full engine tests against a scripted database.
//
// CKDatabase CONFORMANCE:
// CKDatabase (from CloudKit framework) is declared to conform to
// CloudKitDatabaseProtocol within this module. No @retroactive annotation is
// needed because CloudKitDatabaseProtocol is a first-party protocol declared
// in ConvergenceKitCloudKit — only external-type conformances to EXTERNAL protocols
// require @retroactive. CKDatabase is Sendable in the CloudKit framework,
// satisfying the protocol's Sendable constraint.
//
// Compare-and-swap support is required for atomic device-slot claims.

import Foundation
import CloudKit
import ConvergenceKit

// MARK: - CloudKitZoneChanges
//
// Mirror of CKDatabase.RecordZoneChanges that can be constructed in tests.
// CKDatabase.RecordZoneChanges has no public initializer; tests cannot build one
// without a live CloudKit container. CloudKitZoneChanges is our constructible
// mirror. PullCycle uses this type as the result of fetchZoneChanges(inZoneWith:since:).

/// Constructible mirror of CKDatabase.RecordZoneChanges.
///
/// PullCycle receives this from `CloudKitDatabaseProtocol.fetchZoneChanges` rather
/// than from `CKDatabase.recordZoneChanges` directly. This lets test fakes script
/// pull-cycle responses without a live container.
public struct CloudKitZoneChanges: Sendable {

    /// Records modified or inserted on the server since the last change token.
    public let modifiedRecords: [CKRecord]

    /// IDs of records deleted on the server since the last change token.
    /// These carry no record type; PullCycle routes them via the legacy
    /// fan-out path (D1 fallback for external deletions not produced by
    /// our engine's tombstone path).
    public let deletedRecordIDs: [CKRecord.ID]

    /// New server change token to persist after this batch applies.
    /// Nil on a fresh pull (no prior token → zone history start).
    public let changeToken: CKServerChangeToken?

    public init(
        modifiedRecords: [CKRecord],
        deletedRecordIDs: [CKRecord.ID],
        changeToken: CKServerChangeToken?
    ) {
        self.modifiedRecords = modifiedRecords
        self.deletedRecordIDs = deletedRecordIDs
        self.changeToken = changeToken
    }
}

// MARK: - CloudKitDatabaseProtocol

/// Seam over the CKDatabase operations used by the ConvergenceKit CloudKit engine.
///
/// Production conforming type: `CKDatabase` via the retroactive extension below.
/// Test conforming types: actors or structs that script responses.
/// All methods are `async throws` matching the CloudKit async API.
public protocol CloudKitDatabaseProtocol: Sendable {

    /// Upsert or delete records.
    ///
    /// Used by:
    /// - `PushCycle` with `savePolicy: .changedKeys` — unconditional push
    /// - `SlotClaimOperation` with `savePolicy: .ifServerRecordUnchanged` — CAS claim
    /// - `EpochFence` with `savePolicy: .ifServerRecordUnchanged` — heartbeat CAS
    ///
    /// Returns per-record results; P1-M6 will wire partial-success handling in PushCycle.
    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> (saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
                       deleteResults: [CKRecord.ID: Result<Void, any Error>])

    /// Fetch individual records by ID.
    ///
    /// Used by:
    /// - `SlotClaimOperation`: fetches all 15 well-known slot record IDs to build
    ///   the current registry snapshot before running a claim decision
    /// - `EpochFence`: fetches this device's own slot record to verify epoch and
    ///   get the change tag for the subsequent conditional heartbeat save
    func fetch(
        withRecordIDs recordIDs: [CKRecord.ID]
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>]

    /// Fetch zone changes since a server change token.
    ///
    /// Returns `CloudKitZoneChanges` (constructible mirror) rather than
    /// `CKDatabase.RecordZoneChanges` (non-constructible) so PullCycle tests
    /// can script the response. The `CKDatabase` conformance bridges faithfully.
    func fetchZoneChanges(
        inZoneWith zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges

    /// Modify record zones.
    ///
    /// Used by `CloudKitStateActor.enable()` to create or confirm the sync zone.
    /// Errors are swallowed by the engine when the zone already exists.
    func modifyRecordZones(
        saving recordZonesToSave: [CKRecordZone],
        deleting recordZoneIDsToDelete: [CKRecordZone.ID]
    ) async throws -> (saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
                       deleteResults: [CKRecordZone.ID: Result<Void, any Error>])

    /// Modify subscriptions.
    ///
    /// Used by `ZoneSubscription` to register and deregister
    /// `CKRecordZoneSubscription`s idempotently. The subscription ID is
    /// derived from the zone name (fixed, deterministic), so saving an
    /// already-existing subscription is a no-op on the CloudKit server.
    func modifySubscriptions(
        saving subscriptionsToSave: [CKSubscription],
        deleting subscriptionIDsToDelete: [CKSubscription.ID]
    ) async throws -> (saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>],
                       deleteResults: [CKSubscription.ID: Result<Void, any Error>])
}

// MARK: - CKDatabase conformance
//
// CKDatabase (from CloudKit framework) conforming to CloudKitDatabaseProtocol
// (in this module). No @retroactive annotation needed: @retroactive is required
// only when BOTH the type and the protocol come from external modules. Since
// CloudKitDatabaseProtocol is declared in this module (ConvergenceKitCloudKit),
// the conformance is not retroactive — it is a first-party conformance of an
// external type to our own protocol.
//
// Two requirements — modifyRecords(saving:deleting:savePolicy:atomically:) and
// modifyRecordZones(saving:deleting:) — are already present on CKDatabase with
// matching async signatures and are satisfied automatically by the compiler.
//
// Two requirements need explicit implementations:
//   fetch(withRecordIDs:) — bridges from CKDatabase's completion-handler form
//     to the async protocol form via withCheckedThrowingContinuation.
//   fetchZoneChanges(inZoneWith:since:) — bridges from CKDatabase's
//     recordZoneChanges(inZoneWith:since:) and translates the non-constructible
//     CKDatabase.RecordZoneChanges into our CloudKitZoneChanges mirror.

extension CKDatabase: CloudKitDatabaseProtocol {

    /// Bridge from the protocol's async `fetch(withRecordIDs:)` to CKDatabase's
    /// `fetch(withRecordIDs:desiredKeys:completionHandler:)`.
    ///
    /// Fetches all fields (desiredKeys: nil) — the slot registry reads every field.
    /// Uses withCheckedThrowingContinuation because only the callback form of this
    /// API exists on CKDatabase in this SDK version; the structured-concurrency
    /// compiler-generated version is not exposed here.
    public func fetch(
        withRecordIDs recordIDs: [CKRecord.ID]
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        try await withCheckedThrowingContinuation { continuation in
            self.fetch(withRecordIDs: recordIDs, desiredKeys: nil) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Bridge from CKDatabase.recordZoneChanges(inZoneWith:since:) to CloudKitZoneChanges.
    ///
    /// Conversion is faithful: successful modification results become `modifiedRecords`;
    /// per-record failure entries (throttle or partial CloudKit errors) are dropped —
    /// they remain on the server and arrive on the next pull cycle. All deletions
    /// are forwarded without filtering.
    public func fetchZoneChanges(
        inZoneWith zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        let changes = try await self.recordZoneChanges(inZoneWith: zoneID, since: token)
        var modifiedRecords: [CKRecord] = []
        for (_, result) in changes.modificationResultsByID {
            if case .success(let mod) = result {
                modifiedRecords.append(mod.record)
            }
        }
        let deletedIDs = changes.deletions.map { $0.recordID }
        return CloudKitZoneChanges(
            modifiedRecords: modifiedRecords,
            deletedRecordIDs: deletedIDs,
            changeToken: changes.changeToken
        )
    }
}
