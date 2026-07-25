// SlotRecordMapping.swift
//
// Mapping between the 15 well-known CloudKit slot records and DeviceSlot values.
//
// SLOT REGISTRY SCHEMA:
// Each of the 15 assignable HLC node-ID slots (1–15) maps to one CKRecord in
// the manifest's sync zone. Records are named "_slot_1" through "_slot_15"
// with recordType "_ck_device_slot". Fields:
//
//   device_uuid   String  — the claiming device's stable UUID (UUID.uuidString)
//   epoch         Int64   — bumped by evictors; enables fenced re-enrollment (N2)
//   last_active_hlc Int64 — packed HLC (UInt64 reinterpreted as Int64) from the
//                           most recent heartbeat; HLC.zero packed (== 0) means
//                           the slot was claimed but never heartbeated (ghost)
//   claimed_at    String  — ISO8601 wall-clock when this slot was claimed in its
//                           current epoch; stored as TEXT per schema-invariants.md
//
// Zone: the manifest's own private zone. The slot records share the zone with
// application data records to avoid creating a second zone and adding a second
// quota bucket per user.
//
// Maps durable device-slot claims to their CloudKit representation.
// Adjudications: A4 (ghost fast-path), A5 (CAS retry)

import Foundation
import CloudKit
import ConvergenceKit
import SubstrateTypes

// MARK: - SlotRecordMapping

/// Factory and decoder for the 15 well-known CloudKit slot records.
///
/// All methods are static; this is a pure mapping layer with no state.
/// The CloudKit zone is always the manifest's own sync zone (one zone, one
/// registry — N2).
public enum SlotRecordMapping {

    // MARK: - Constants

    /// CloudKit record type for all 15 slot records.
    ///
    /// Prefixed with `_ck_` to avoid collision with application record types
    /// and to follow the ConvergenceKit side-table naming convention.
    public static let recordType = "_ck_device_slot"

    // ISO 8601 formatter shared across encode/decode. Formatter is configured
    // once (thread-safe after configuration) and never mutated after init.
    // nonisolated(unsafe) satisfies Swift 6 strict concurrency without hiding
    // the true thread-safety contract: formatters are safe to read concurrently
    // once initialised.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Record ID factory

    /// CKRecord.ID for slot number `slot` in `zoneID`.
    ///
    /// Record names are "_slot_1" through "_slot_15" — stable, human-readable
    /// identifiers that do not depend on UUIDs so they can be hard-coded in
    /// both claim and fetch operations.
    ///
    /// - Precondition: `slot` must be in `1...15`.
    public static func recordID(slot: Int, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        precondition((1...15).contains(slot), "SlotRecordMapping: slot must be 1–15")
        return CKRecord.ID(recordName: "_slot_\(slot)", zoneID: zoneID)
    }

    /// The full set of 15 record IDs for `zoneID`.
    ///
    /// Passed to `CloudKitDatabaseProtocol.fetch(withRecordIDs:)` to build a
    /// complete registry snapshot in one round-trip.
    public static func allRecordIDs(zoneID: CKRecordZone.ID) -> [CKRecord.ID] {
        (1...15).map { recordID(slot: $0, zoneID: zoneID) }
    }

    // MARK: - DeviceSlot → CKRecord

    /// Encode `deviceSlot` as a CKRecord ready for a CloudKit save.
    ///
    /// - Parameter deviceSlot: The slot to encode.
    /// - Parameter zoneID: The manifest's sync zone.
    /// - Returns: A `CKRecord` with `recordType == "_ck_device_slot"` and all
    ///   four fields populated. The record has no change tag — callers that need
    ///   a conditional save (CAS) must first `fetch` the existing record and
    ///   update its fields rather than constructing a new record.
    public static func record(from deviceSlot: DeviceSlot, zoneID: CKRecordZone.ID) -> CKRecord {
        let id = recordID(slot: deviceSlot.slot, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: id)
        populate(record: record, from: deviceSlot)
        return record
    }

    /// Populate an existing CKRecord's fields from `deviceSlot`.
    ///
    /// Used when updating a fetched record (which already has a change tag) for
    /// a conditional save. Mutates `record` in place.
    public static func populate(record: CKRecord, from deviceSlot: DeviceSlot) {
        record["device_uuid"]     = deviceSlot.deviceUUID.uuidString as CKRecordValue
        record["epoch"]           = deviceSlot.epoch as CKRecordValue
        // last_active_hlc: packed HLC as Int64 (bitPattern preserves all bits of UInt64).
        // HLC.zero.packed == 0 → ghost slot sentinel (never heartbeated).
        record["last_active_hlc"] = Int64(bitPattern: deviceSlot.lastActiveHLC.packed) as CKRecordValue
        // DATE STORAGE: ISO8601 text — never REAL/unix timestamp (schema-invariants.md).
        record["claimed_at"]      = iso8601.string(from: deviceSlot.claimedAt) as CKRecordValue
    }

    // MARK: - CKRecord → DeviceSlot

    /// Decode a CKRecord into a DeviceSlot.
    ///
    /// - Parameter record: A CloudKit record with `recordType == "_ck_device_slot"`.
    /// - Returns: The decoded `DeviceSlot`.
    /// - Throws: `SyncError.decodingFailure` when any required field is missing or
    ///   cannot be converted to the expected type.
    public static func slot(from record: CKRecord) throws -> DeviceSlot {
        // Extract slot number from the well-known record name "_slot_N".
        let recordName = record.recordID.recordName
        guard recordName.hasPrefix("_slot_"),
              let slotNumber = Int(recordName.dropFirst("_slot_".count)),
              (1...15).contains(slotNumber)
        else {
            throw SyncError.decodingFailure(
                detail: "SlotRecordMapping: unexpected recordName '\(recordName)'"
            )
        }

        guard
            let uuidStr = record["device_uuid"] as? String,
            let deviceUUID = UUID(uuidString: uuidStr),
            let epoch = record["epoch"] as? Int64,
            let lastActiveRaw = record["last_active_hlc"] as? Int64,
            let claimedAtStr = record["claimed_at"] as? String,
            let claimedAt = iso8601.date(from: claimedAtStr)
        else {
            throw SyncError.decodingFailure(
                detail: "SlotRecordMapping: required field missing or wrong type in '\(recordName)'"
            )
        }

        let lastActiveHLC = HLC(packed: UInt64(bitPattern: lastActiveRaw))

        return DeviceSlot(
            slot: slotNumber,
            epoch: epoch,
            deviceUUID: deviceUUID,
            lastActiveHLC: lastActiveHLC,
            claimedAt: claimedAt
        )
    }
}
