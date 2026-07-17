// CKRecordMapping.swift
//
// Generic mapper between PersistenceKit rows ([String: TypedValue])
// and CKRecord objects. Driven by SyncManifest; no per-entity
// hardcoded mapping. Each table contributes one record type
// (CKRecord.recordType = manifest.kitID + "_" + table.name).

import Foundation
import CloudKit
import ConvergenceKit
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes

public enum CKRecordMapping {

    /// Build a CKRecord.recordType from kitID + table name.
    /// Format: kitID + "_" + tableName. Both must be CloudKit-safe
    /// (alphanumeric and underscore); callers are responsible.
    public static func recordType(kitID: String, table: String) -> String {
        "\(kitID)_\(table)"
    }

    /// Build a CKRecord.ID for a row in the given zone.
    public static func recordID(rowKey: UUID, zone: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: rowKey.uuidString, zoneID: zone)
    }

    /// Build a tombstone CKRecord for a delete event.
    ///
    /// WHY a tombstone CKRecord instead of CKRecord.ID deletion:
    /// CKRecord.ID deletions carry no record type, so the pull path cannot
    /// route them to the correct manifest table — they fan out to every
    /// non-pushOnly table (D1 defect). A typed tombstone CKRecord encodes
    /// the table name in its `recordType` (`kitID_tableName`), giving the
    /// pull path the routing information it needs. The delete HLC is stored
    /// in `_syncHLC` so the receiver applies the same LWW gate as for
    /// upserts (D2 fix) and persists the HLC in `_ck_sync_meta` after
    /// hard-deleting the row (A6 adjudication, stale-resurrect guard).
    public static func tombstoneRecord(
        rowKey: UUID,
        table: String,
        kitID: String,
        deleteHLC: HLC,
        schemaVersion: Int,
        zone: CKRecordZone.ID
    ) -> CKRecord {
        let id = recordID(rowKey: rowKey, zone: zone)
        let record = CKRecord(recordType: recordType(kitID: kitID, table: table), recordID: id)
        // Tombstone marker: receiver detects _syncDeleted == 1 and routes through
        // the tombstone apply path rather than a normal upsert.
        record[SyncTombstone.deletedFieldKey] = NSNumber(value: 1)
        // Delete HLC: lets the receiver gate against stale resurrections via the
        // standard LWW comparison and persist the HLC in _ck_sync_meta after delete.
        record["_syncHLC"] = packed(deleteHLC) as NSNumber
        record["_syncSchemaVersion"] = NSNumber(value: schemaVersion)
        record["_syncKitID"] = kitID as NSString
        return record
    }

    /// Convert a row to a CKRecord. Reserved field names
    /// (_syncHLC, _syncSchemaVersion, _syncKitID, _syncColumnHLCs) carry
    /// sync metadata so the receiver can apply conflict policy and schema check.
    ///
    /// - Parameters:
    ///   - columnHLCs: Per-column HLC map for `fieldLevelLWW` records. When
    ///     non-nil and non-empty, encoded as a JSON blob in `_syncColumnHLCs`.
    ///     Nil or empty for non-fieldLevelLWW records — field is omitted.
    public static func record(
        from values: [String: TypedValue],
        table: String,
        rowKey: UUID,
        hlc: HLC,
        schemaVersion: Int,
        kitID: String,
        zone: CKRecordZone.ID,
        columnHLCs: ColumnHLCMap? = nil
    ) throws -> CKRecord {
        let recordID = recordID(rowKey: rowKey, zone: zone)
        let record = CKRecord(recordType: recordType(kitID: kitID, table: table), recordID: recordID)
        for (key, value) in values {
            try assign(value: value, to: record, forKey: key)
        }
        // Sync metadata fields (reserved names start with _sync).
        record["_syncHLC"] = packed(hlc) as NSNumber
        record["_syncSchemaVersion"] = NSNumber(value: schemaVersion)
        record["_syncKitID"] = kitID as NSString
        // _syncColumnHLCs: present only for fieldLevelLWW records (B-8, v1.2-draft).
        // JSON-encoded ColumnHLCMap blob. Omitted when nil or empty so non-fieldLevelLWW
        // records stay compact on the wire.
        if let map = columnHLCs, !map.isEmpty,
           let data = try? JSONEncoder().encode(map) {
            record["_syncColumnHLCs"] = data as NSData
        }
        return record
    }

    /// Decode sync metadata + values from a CKRecord.
    ///
    /// Sets `DecodedRecord.isTombstone = true` when the record carries
    /// `_syncDeleted == 1`. Tombstone records are applied through the
    /// standard LWW gate; on a win the row is hard-deleted and the HLC
    /// persists in `_ck_sync_meta` (A6 adjudication).
    public static func decode(_ record: CKRecord) throws -> DecodedRecord {
        guard let hlcPacked = (record["_syncHLC"] as? NSNumber)?.int64Value else {
            throw SyncError.decodingFailure(detail: "missing _syncHLC on \(record.recordID.recordName)")
        }
        guard let schemaVersion = (record["_syncSchemaVersion"] as? NSNumber)?.intValue else {
            throw SyncError.decodingFailure(detail: "missing _syncSchemaVersion")
        }
        let kitID = (record["_syncKitID"] as? String) ?? ""
        let hlc = unpacked(hlcPacked)
        let parts = record.recordType.split(separator: "_", maxSplits: 1)
        let tableName = parts.count > 1 ? String(parts[1]) : record.recordType
        // Reject fabrication: a corrupt recordName must never become a fresh
        // random UUID. A fabricated identity would create a phantom local row
        // that desynchronises on every subsequent sync round — each pull would
        // upsert the same corrupt remote record under a different UUID, growing
        // the local database unboundedly. The caller (pull loop) quarantines the
        // record as a conflict and continues to the next one.
        guard let rowKey = UUID(uuidString: record.recordID.recordName) else {
            throw SyncError.corruptRemoteIdentity(recordName: record.recordID.recordName)
        }

        // Detect tombstone marker. _syncDeleted is filtered from values below
        // (all _sync* keys are excluded) so it does not leak into the app schema.
        let isTombstone = (record[SyncTombstone.deletedFieldKey] as? NSNumber)?.intValue == 1

        // Decode per-column HLC map for fieldLevelLWW records (B-8, v1.2-draft).
        // Absent on non-fieldLevelLWW records and on records from older peers.
        let columnHLCs: ColumnHLCMap?
        if let data = record["_syncColumnHLCs"] as? Data {
            columnHLCs = try? JSONDecoder().decode(ColumnHLCMap.self, from: data)
        } else {
            columnHLCs = nil
        }

        var values: [String: TypedValue] = [:]
        for key in record.allKeys() {
            if key.hasPrefix("_sync") { continue }
            if let any = record[key] {
                values[key] = try typedValue(from: any)
            } else {
                values[key] = .null
            }
        }
        return DecodedRecord(
            table: tableName,
            rowKey: rowKey,
            values: values,
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: schemaVersion, kitID: kitID),
            isTombstone: isTombstone,
            columnHLCs: columnHLCs
        )
    }

    private static func assign(value: TypedValue, to record: CKRecord, forKey key: String) throws {
        switch value {
        case .null:
            record[key] = nil
        case .bool(let b):
            record[key] = NSNumber(value: b)
        case .int(let i):
            record[key] = NSNumber(value: i)
        case .bitmap(let i):
            record[key] = NSNumber(value: i)
        case .float(let f):
            record[key] = NSNumber(value: f)
        case .text(let s):
            record[key] = s as NSString
        case .blob(let d):
            record[key] = d as NSData
        case .uuid(let u):
            record[key] = u.uuidString as NSString
        case .timestamp(let d):
            record[key] = d as NSDate
        case .json(let d):
            // Store as text for queryability; decoder maps the CloudKit string
            // back to .text, not .json — the .json discriminator is not carried.
            if let s = String(data: d, encoding: .utf8) {
                record[key] = s as NSString
            } else {
                record[key] = d as NSData
            }
        case .hlc(let h):
            record[key] = packed(h) as NSNumber
        case .fingerprint(let fp):
            // 32 bytes (4 x UInt64 little-endian).
            var data = Data(capacity: 32)
            withUnsafeBytes(of: fp.block0.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: fp.block1.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: fp.block2.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: fp.block3.littleEndian) { data.append(contentsOf: $0) }
            record[key] = data as NSData
        case .array:
            // Arrays are not supported in CKRecord encoding.
            throw SyncError.encodingFailure(detail: "array TypedValue not supported in CKRecord yet")
        }
    }

    private static func typedValue(from any: __CKRecordObjCValue) throws -> TypedValue {
        // CKRecord values are NS-bridged Objective-C objects.
        if let n = any as? NSNumber {
            // Distinguish bool / int / float by ObjC type encoding.
            let t = String(cString: n.objCType)
            switch t {
            case "c", "B": return .bool(n.boolValue)
            case "f", "d": return .float(n.doubleValue)
            default: return .int(n.int64Value)
            }
        }
        if let s = any as? String {
            return .text(s)
        }
        if let d = any as? Date {
            return .timestamp(d)
        }
        if let data = any as? Data {
            return .blob(data)
        }
        return .null
    }

    /// Pack an HLC into Int64 (sortable, fits in CKRecord NSNumber).
    /// Layout: 48 bits physical, 12 bits logical, 4 bits node.
    static func packed(_ hlc: HLC) -> Int64 {
        let p = UInt64(bitPattern: hlc.physicalTime) & 0xFFFF_FFFF_FFFF
        let l = UInt64(UInt32(bitPattern: hlc.logicalCount) & 0xFFF)
        let n = UInt64(UInt32(bitPattern: hlc.nodeID) & 0xF)
        return Int64(bitPattern: (p << 16) | (l << 4) | n)
    }

    static func unpacked(_ i: Int64) -> HLC {
        let packed = UInt64(bitPattern: i)
        let physical = Int64(packed >> 16)
        let logical = Int32(truncatingIfNeeded: (packed >> 4) & 0xFFF)
        let node = Int32(truncatingIfNeeded: packed & 0xF)
        return HLC(physicalTime: physical, logicalCount: logical, nodeID: node)
    }
}

/// Sync metadata extracted from the `_sync*` fields of a CKRecord.
/// Carried separately from `values` so `values` remains clean
/// (no `_sync*` keys) while the engine retains the metadata needed
/// for conflict resolution and durable HLC persistence.
public struct SyncMeta: Sendable {
    public let hlc: HLC
    public let schemaVersion: Int
    public let kitID: String
}

public struct DecodedRecord: Sendable {
    public let table: String
    public let rowKey: UUID
    /// App-data values. Contains no `_sync*` keys.
    public let values: [String: TypedValue]
    /// Sync metadata extracted during decode.
    public let syncMeta: SyncMeta
    /// True when this record represents a delete tombstone (`_syncDeleted == 1`).
    ///
    /// WHY: the tombstone flag routes this record to the tombstone apply path
    /// in `applyInbound` — LWW gate → hard-delete row → persist delete HLC in
    /// `_ck_sync_meta` (A6 adjudication). Without the flag the receiver would
    /// attempt a normal upsert on an empty values map, creating a phantom row.
    /// Defaults to false for normal (non-delete) records.
    public var isTombstone: Bool = false

    /// Per-column HLC map decoded from `_syncColumnHLCs` (B-8, v1.2-draft).
    ///
    /// Non-nil only for `fieldLevelLWW` records where the sender populated
    /// the column HLC map. Nil on non-fieldLevelLWW records and on records
    /// from older peers that do not support the field (backward-compat).
    /// ApplyInbound uses this map for the `.fieldLevelLWW` policy arm.
    public var columnHLCs: ColumnHLCMap?

    public init(
        table: String,
        rowKey: UUID,
        values: [String: TypedValue],
        syncMeta: SyncMeta,
        isTombstone: Bool = false,
        columnHLCs: ColumnHLCMap? = nil
    ) {
        self.table = table
        self.rowKey = rowKey
        self.values = values
        self.syncMeta = syncMeta
        self.isTombstone = isTombstone
        self.columnHLCs = columnHLCs
    }

    /// HLC of the record — convenience accessor backed by `syncMeta`.
    public var hlc: HLC { syncMeta.hlc }
    /// Schema version — convenience accessor backed by `syncMeta`.
    public var schemaVersion: Int { syncMeta.schemaVersion }
    /// Kit identifier — convenience accessor backed by `syncMeta`.
    public var kitID: String { syncMeta.kitID }
}
