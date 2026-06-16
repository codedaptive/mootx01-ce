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

    /// Convert a row to a CKRecord. Reserved field names
    /// (_syncHLC, _syncSchemaVersion) carry sync metadata so the
    /// receiver can apply conflict policy and schema check.
    public static func record(
        from values: [String: TypedValue],
        table: String,
        rowKey: UUID,
        hlc: HLC,
        schemaVersion: Int,
        kitID: String,
        zone: CKRecordZone.ID
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
        return record
    }

    /// Decode sync metadata + values from a CKRecord.
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
            syncMeta: SyncMeta(hlc: hlc, schemaVersion: schemaVersion, kitID: kitID)
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
            // Store as text so it's queryable; receiver re-parses.
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
            // Arrays are encoded as JSON.
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

    /// HLC of the record — convenience accessor backed by `syncMeta`.
    public var hlc: HLC { syncMeta.hlc }
    /// Schema version — convenience accessor backed by `syncMeta`.
    public var schemaVersion: Int { syncMeta.schemaVersion }
    /// Kit identifier — convenience accessor backed by `syncMeta`.
    public var kitID: String { syncMeta.kitID }
}
