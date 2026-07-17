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

    /// Optional fault queue. Set before a test phase to script errors on
    /// specific operation targets; leave nil for the normal (no-fault) path.
    var faults: FaultInjector?

    // MARK: - Test helpers

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
        if let fault = await faults?.nextFault(for: .modifyRecords) {
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
}
