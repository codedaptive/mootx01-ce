// CloudZoneFake.swift
//
// Shared in-process CloudKit fake for two-estate convergence tests (CVK-ICLOUD P4-M1).
// Both estate engines inject one CloudZoneFake instance as their CloudKitDatabaseProtocol,
// giving them a common "cloud" without a network or iCloud container.
//
// CAS semantics (ifServerRecordUnchanged):
//   Uses ObjectIdentifier to proxy the CloudKit server change tag. A fetched CKRecord
//   is the same object returned from the store; saving it (mutated in-place) passes the
//   check. A freshly-created CKRecord (different object) fails with serverRecordChanged.
//   This faithfully models CloudKit CAS: the change tag is embedded in the fetched
//   instance; fresh instances carry no tag.
//
// HLC-aware merge (changedKeys, data records):
//   Only updates the stored record when incoming _syncHLC >= existing _syncHLC
//   (compared as UInt64 with bitPattern reinterpret). Stale pushes lose silently,
//   matching real CloudKit LWW semantics in the convergence engine.
//
// fetchZoneChanges:
//   Always returns ALL data records for the requested zone (full re-pull), with
//   changeToken: nil. Filters out _ck_device_slot records so the pull path never
//   routes slot-registry entries as application data.
//
// Fault injection:
//   Assign a FaultInjector to the `faults` property to script failures on specific
//   operations. Used by scenario (d) and P4-M2/M3 fault-tolerance tests.

import Foundation
import CloudKit
import ConvergenceKitCloudKit

// MARK: - CloudZoneFake

/// In-process fake CloudKit database. Shared by both estates in TwoEstateFixture.
/// Handles slot-registry records (_ck_device_slot) and application data records
/// in a single in-memory store.
actor CloudZoneFake: CloudKitDatabaseProtocol {

    // MARK: - Storage

    /// All records, keyed by CKRecord.ID.
    private var store: [CKRecord.ID: CKRecord] = [:]

    /// ObjectIdentifier for each stored record; used for CAS semantics.
    private var storedIdentifiers: [CKRecord.ID: ObjectIdentifier] = [:]

    /// Saved subscriptions, keyed by subscription ID.
    /// ZoneSubscription tests use this to assert idempotency and deregistration.
    private var savedSubscriptions: [CKSubscription.ID: CKSubscription] = [:]

    /// Optional fault queue. Set before a test phase to script errors on
    /// specific operation targets; leave nil for the normal (no-fault) path.
    var faults: FaultInjector?

    // MARK: - Test helpers

    /// Set (or clear) the fault injector. Tests call this to script failures
    /// on specific operations. Must be called via `await` from outside the actor.
    func setFaults(_ newFaults: FaultInjector?) {
        faults = newFaults
    }

    /// Pre-populate the store with a record, bypassing HLC-aware merge and CAS.
    /// Used to set up initial estate state in tests.
    func seed(record: CKRecord) {
        store[record.recordID] = record
        storedIdentifiers[record.recordID] = ObjectIdentifier(record)
    }

    /// Remove a record by ID (simulates external deletion for tombstone setup).
    func removeRecord(id: CKRecord.ID) {
        store.removeValue(forKey: id)
        storedIdentifiers.removeValue(forKey: id)
    }

    /// All data records across all zones (excludes _ck_device_slot records).
    func allDataRecords() -> [CKRecord] {
        store.values.filter { $0.recordType != "_ck_device_slot" }
    }

    // MARK: - Subscription test helpers

    /// Number of subscriptions currently saved.
    var subscriptionCount: Int { savedSubscriptions.count }

    /// Return the saved subscription for a given ID, or nil.
    func subscription(withID id: CKSubscription.ID) -> CKSubscription? {
        savedSubscriptions[id]
    }

    // MARK: - Data record test helpers

    /// Data records filtered to a specific zone.
    func dataRecords(in zoneID: CKRecordZone.ID) -> [CKRecord] {
        store.values.filter {
            $0.recordID.zoneID == zoneID && $0.recordType != "_ck_device_slot"
        }
    }

    /// Number of data records in the store (for convergence assertions).
    func dataRecordCount(in zoneID: CKRecordZone.ID) -> Int {
        store.values.filter {
            $0.recordID.zoneID == zoneID && $0.recordType != "_ck_device_slot"
        }.count
    }

    // MARK: - CloudKitDatabaseProtocol

    func fetch(
        withRecordIDs recordIDs: [CKRecord.ID]
    ) async throws -> [CKRecord.ID: Result<CKRecord, any Error>] {
        if let fault = await faults?.nextFault(for: .fetch) {
            throw FaultInjector.makeError(for: fault)
        }
        var results: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
        for id in recordIDs {
            if let record = store[id] {
                results[id] = .success(record)
            } else {
                // Absent record: slot is free or data record not yet pushed.
                let err = NSError(
                    domain: CKErrorDomain,
                    code: CKError.Code.unknownItem.rawValue,
                    userInfo: nil
                )
                results[id] = .failure(err)
            }
        }
        return results
    }

    func modifyRecords(
        saving recordsToSave: [CKRecord],
        deleting recordIDsToDelete: [CKRecord.ID],
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
        atomically: Bool
    ) async throws -> (
        saveResults: [CKRecord.ID: Result<CKRecord, any Error>],
        deleteResults: [CKRecord.ID: Result<Void, any Error>]
    ) {
        // Fault injection: only applies to batches that contain at least one data record.
        // Slot-registry heartbeat calls (all records have type "_ck_device_slot") are
        // transparent to data-push faults — they must not consume a queued fault that
        // was intended for the subsequent data modifyRecords call. Without this guard,
        // a .partialBatchFailure injected for a data push would be consumed by the slot
        // heartbeat and the data push would receive no fault, causing the test to fail.
        let hasDataRecords = recordsToSave.contains { $0.recordType != "_ck_device_slot" }

        if hasDataRecords, let fault = await faults?.nextFault(for: .modifyRecords) {
            // .partialBatchFailure: do NOT throw. Fall through to normal processing
            // but mark the first `count` DATA records as per-record failures without
            // updating the store. PushResults.process sees individual failure Results
            // in saveResults and increments retry_count for those outbox entries.
            if case .partialBatchFailure(let failCount) = fault {
                var partialResults: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
                let perRecordError = NSError(
                    domain: CKErrorDomain,
                    code: CKError.Code.networkUnavailable.rawValue,
                    userInfo: nil
                )
                // Count only DATA records against the failure budget; slot records
                // always succeed regardless of the fault count.
                var dataFailIdx = 0
                for record in recordsToSave {
                    let id = record.recordID
                    let isSlot = record.recordType == "_ck_device_slot"
                    if !isSlot && dataFailIdx < failCount {
                        // Fail this data record at per-record level; do not update store.
                        partialResults[id] = .failure(perRecordError)
                        dataFailIdx += 1
                    } else {
                        // Normal HLC-aware merge for slot records and non-failing data records.
                        if !isSlot, let existing = store[id] {
                            let inHLC = UInt64(bitPattern: (record["_syncHLC"] as? NSNumber)?.int64Value ?? 0)
                            let exHLC = UInt64(bitPattern: (existing["_syncHLC"] as? NSNumber)?.int64Value ?? 0)
                            if inHLC < exHLC {
                                partialResults[id] = .success(existing)
                                continue
                            }
                        }
                        store[id] = record
                        storedIdentifiers[id] = ObjectIdentifier(record)
                        partialResults[id] = .success(record)
                    }
                }
                return (partialResults, [:])
            }
            throw FaultInjector.makeError(for: fault)
        }

        var saveResults: [CKRecord.ID: Result<CKRecord, any Error>] = [:]

        for record in recordsToSave {
            let id = record.recordID

            if savePolicy == .ifServerRecordUnchanged {
                // CAS: the fetched-and-mutated instance (same ObjectIdentifier) passes;
                // a freshly-constructed instance (different ObjectIdentifier) fails.
                if let existingIdent = storedIdentifiers[id],
                   existingIdent != ObjectIdentifier(record) {
                    let casError = NSError(
                        domain: CKErrorDomain,
                        code: CKError.Code.serverRecordChanged.rawValue,
                        userInfo: nil
                    )
                    throw casError
                }
            } else {
                // .changedKeys: HLC-aware merge for data records.
                // Slot-registry records (_ck_device_slot) have no _syncHLC field;
                // allow them to overwrite unconditionally.
                if record.recordType != "_ck_device_slot", let existing = store[id] {
                    let inHLC  = UInt64(bitPattern: (record["_syncHLC"]   as? NSNumber)?.int64Value ?? 0)
                    let exHLC  = UInt64(bitPattern: (existing["_syncHLC"] as? NSNumber)?.int64Value ?? 0)
                    if inHLC < exHLC {
                        // Stale push: existing record wins; acknowledge without updating.
                        saveResults[id] = .success(existing)
                        continue
                    }
                }
            }

            store[id] = record
            storedIdentifiers[id] = ObjectIdentifier(record)
            saveResults[id] = .success(record)
        }

        // Engine uses typed tombstone CKRecords rather than CKRecord.ID deletions
        // (D1 fix in P1-M7). Record-ID deletions are handled here for completeness
        // in case any test drives them directly.
        var deleteResults: [CKRecord.ID: Result<Void, any Error>] = [:]
        for id in recordIDsToDelete {
            store.removeValue(forKey: id)
            storedIdentifiers.removeValue(forKey: id)
            deleteResults[id] = .success(())
        }

        return (saveResults, deleteResults)
    }

    func fetchZoneChanges(
        inZoneWith zoneID: CKRecordZone.ID,
        since token: CKServerChangeToken?
    ) async throws -> CloudKitZoneChanges {
        if let fault = await faults?.nextFault(for: .fetchZoneChanges) {
            throw FaultInjector.makeError(for: fault)
        }
        // Full re-pull: return all data records for this zone.
        // changeToken is always nil — the fake does not track incremental changes;
        // every pull fetches the current full zone state. The pull path handles
        // re-applying previously-seen records correctly: the LWW gate (localHLC
        // >= incomingHLC → skip) makes re-application idempotent, and all writes
        // use upsertSync (.syncApply origin) so they never re-enter the outbox.
        let records = store.values.filter {
            $0.recordID.zoneID == zoneID && $0.recordType != "_ck_device_slot"
        }
        return CloudKitZoneChanges(
            modifiedRecords: Array(records),
            deletedRecordIDs: [],
            changeToken: nil
        )
    }

    func modifyRecordZones(
        saving recordZonesToSave: [CKRecordZone],
        deleting recordZoneIDsToDelete: [CKRecordZone.ID]
    ) async throws -> (
        saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>],
        deleteResults: [CKRecordZone.ID: Result<Void, any Error>]
    ) {
        if let fault = await faults?.nextFault(for: .modifyRecordZones) {
            throw FaultInjector.makeError(for: fault)
        }
        // Zones are not tracked in the fake; always succeed.
        var saveResults: [CKRecordZone.ID: Result<CKRecordZone, any Error>] = [:]
        for zone in recordZonesToSave {
            saveResults[zone.zoneID] = .success(zone)
        }
        return (saveResults, [:])
    }

    func modifySubscriptions(
        saving subscriptionsToSave: [CKSubscription],
        deleting subscriptionIDsToDelete: [CKSubscription.ID]
    ) async throws -> (
        saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>],
        deleteResults: [CKSubscription.ID: Result<Void, any Error>]
    ) {
        // Record saves — idempotent: saving the same subscription ID again
        // overwrites the existing entry, matching real CloudKit semantics.
        var saveResults: [CKSubscription.ID: Result<CKSubscription, any Error>] = [:]
        for sub in subscriptionsToSave {
            savedSubscriptions[sub.subscriptionID] = sub
            saveResults[sub.subscriptionID] = .success(sub)
        }
        // Record deletes.
        var deleteResults: [CKSubscription.ID: Result<Void, any Error>] = [:]
        for id in subscriptionIDsToDelete {
            savedSubscriptions.removeValue(forKey: id)
            deleteResults[id] = .success(())
        }
        return (saveResults, deleteResults)
    }
}
