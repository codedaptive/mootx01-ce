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
    /// in `moot_sync_hlc` so the receiver applies the same LWW gate as for
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
        // Tombstone marker: receiver detects moot_sync_deleted == 1 and routes through
        // the tombstone apply path rather than a normal upsert.
        record[SyncTombstone.deletedFieldKey] = NSNumber(value: 1)
        // Delete HLC: lets the receiver gate against stale resurrections via the
        // standard LWW comparison and persist the HLC in _ck_sync_meta after delete.
        record[SyncMetadataField.hlc] = packed(deleteHLC) as NSNumber
        record[SyncMetadataField.schemaVersion] = NSNumber(value: schemaVersion)
        record[SyncMetadataField.kitID] = kitID as NSString
        return record
    }

    /// Convert a row to a CKRecord. Reserved field names
    /// (`SyncMetadataField.all`)
    /// carry sync metadata so the receiver can apply conflict policy, schema check,
    /// and restore exact TypedValue discriminators after CKRecord round-trip.
    ///
    /// - Parameters:
    ///   - columnHLCs: Per-column HLC map for `fieldLevelLWW` records. When
    ///     non-nil and non-empty, encoded as a JSON blob in `moot_sync_column_hlcs`.
    ///     Nil or empty for non-fieldLevelLWW records — field is omitted.
    public static func record(
        from values: [String: TypedValue],
        table: String,
        rowKey: UUID,
        hlc: HLC,
        schemaVersion: Int,
        kitID: String,
        zone: CKRecordZone.ID,
        columnHLCs: ColumnHLCMap? = nil,
        encryptedColumns: Set<String> = []
    ) throws -> CKRecord {
        let recordID = recordID(rowKey: rowKey, zone: zone)
        let record = CKRecord(recordType: recordType(kitID: kitID, table: table), recordID: recordID)

        if let reservedKey = values.keys.first(where: SyncMetadataField.isReserved) {
            throw SyncError.encodingFailure(
                detail: "application column '\(reservedKey)' uses reserved CloudKit metadata namespace \(SyncMetadataField.namespacePrefix)"
            )
        }

        // Collect type tags for CKRecord-lossy discriminators BEFORE assigning values.
        // CKRecord does not carry Swift type metadata, so certain discriminators collapse
        // to coarser types on the wire:
        //   .uuid        → NSString → decoded as .text (uuidString value preserved)
        //   .bitmap      → NSNumber(Int64) → decoded as .int (same ObjC type as .int)
        //   .hlc         → NSNumber(Int64, packed) → decoded as .int (packed value)
        //   .json        → NSString or NSData → decoded as .text or .blob
        //   .fingerprint → NSData (32 bytes) → decoded as .blob
        // The moot_sync_type_tags map restores exact discriminators at decode time without
        // guessing. Non-lossy cases (.null, .bool, .int, .float, .text, .blob,
        // .timestamp) round-trip with the correct discriminator and need no tag.
        var typeTags: [String: String] = [:]
        for (key, value) in values {
            switch value {
            case .uuid:        typeTags[key] = "uuid"
            case .bitmap:      typeTags[key] = "bitmap"
            case .hlc:         typeTags[key] = "hlc"
            case .json:        typeTags[key] = "json"
            case .fingerprint: typeTags[key] = "fingerprint"
            default:           break
            }
        }

        for (key, value) in values {
            // Declared columns go through the encrypted channel; all others stay plaintext.
            // encryptedValues is itself a CKRecord, so assign() works unchanged.
            let target = encryptedColumns.contains(key) ? record.encryptedValues : record
            try assign(value: value, to: target, forKey: key)
        }
        // Sync metadata fields use client-writable names from one canonical vocabulary.
        record[SyncMetadataField.hlc] = packed(hlc) as NSNumber
        record[SyncMetadataField.schemaVersion] = NSNumber(value: schemaVersion)
        record[SyncMetadataField.kitID] = kitID as NSString
        // moot_sync_column_hlcs: present only for fieldLevelLWW records (B-8).
        // JSON-encoded ColumnHLCMap blob. Omitted when nil or empty so non-fieldLevelLWW
        // records stay compact on the wire.
        if let map = columnHLCs, !map.isEmpty,
           let data = try? JSONEncoder().encode(map) {
            record[SyncMetadataField.columnHLCs] = data as NSData
        }
        // moot_sync_type_tags: compact JSON map from column name → discriminator string.
        // Carries only the lossy discriminators listed above; omitted when all present
        // column discriminators round-trip cleanly so non-lossy records stay compact.
        // The canonical metadata set ensures decode() filters this field from app data
        // without treating unrelated application columns as reserved by prefix.
        if !typeTags.isEmpty,
           let tagsData = try? JSONEncoder().encode(typeTags),
           let tagsString = String(data: tagsData, encoding: .utf8) {
            record[SyncMetadataField.typeTags] = tagsString as NSString
        }
        return record
    }

    /// Decode sync metadata + values from a CKRecord.
    ///
    /// Sets `DecodedRecord.isTombstone = true` when the record carries
    /// `moot_sync_deleted == 1`. Tombstone records are applied through the
    /// standard LWW gate; on a win the row is hard-deleted and the HLC
    /// persists in `_ck_sync_meta` (A6 adjudication).
    public static func decode(_ record: CKRecord) throws -> DecodedRecord {
        guard let hlcPacked = (record[SyncMetadataField.hlc] as? NSNumber)?.int64Value else {
            throw SyncError.decodingFailure(
                detail: "missing \(SyncMetadataField.hlc) on \(record.recordID.recordName)"
            )
        }
        guard let schemaVersion = (record[SyncMetadataField.schemaVersion] as? NSNumber)?.intValue else {
            throw SyncError.decodingFailure(detail: "missing \(SyncMetadataField.schemaVersion)")
        }
        let kitID = (record[SyncMetadataField.kitID] as? String) ?? ""
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

        // Detect the tombstone marker. Every canonical metadata key is filtered
        // below so the marker cannot leak into the application schema.
        let isTombstone = (record[SyncTombstone.deletedFieldKey] as? NSNumber)?.intValue == 1

        // Decode per-column HLC map for fieldLevelLWW records (B-8).
        // Absent on non-fieldLevelLWW records and on records from older peers.
        let columnHLCs: ColumnHLCMap?
        if let data = record[SyncMetadataField.columnHLCs] as? Data {
            columnHLCs = try? JSONDecoder().decode(ColumnHLCMap.self, from: data)
        } else {
            columnHLCs = nil
        }

        var values: [String: TypedValue] = [:]
        // Union both channels: encrypted (post-migration) and plaintext (pre-migration).
        // Dual-read: encrypted channel wins when a key appears in both, enabling
        // the server-side transition where plaintext rows coexist with encrypted ones.
        let allDataKeys = Set(record.allKeys()).union(record.encryptedValues.allKeys())
        for key in allDataKeys {
            if SyncMetadataField.isReserved(key) { continue }
            if let any = record.encryptedValues[key] {
                values[key] = try typedValue(from: any)
            } else if let any = record[key] {
                values[key] = try typedValue(from: any)
            } else {
                values[key] = .null
            }
        }

        // Restore lossy TypedValue discriminators from the type-tag map (P4-M2).
        // CKRecord collapses certain discriminators to coarser types on the wire
        // (see record(from:) for the full list). The tag map written at encode time
        // restores the exact discriminator without guessing from runtime value shape.
        // Absent on records from older peers; decoded values remain in their coarser
        // form (backward-compat: existing callers that tolerated .text for uuid columns
        // continue to work).
        if let tagsString = record[SyncMetadataField.typeTags] as? String,
           let tagsData = tagsString.data(using: .utf8),
           let typeTags = try? JSONDecoder().decode([String: String].self, from: tagsData) {
            for (col, tag) in typeTags {
                guard let v = values[col] else { continue }
                switch tag {
                case "uuid":
                    // .uuid was stored as u.uuidString (NSString), decoded as .text(s).
                    // Restore to .uuid(u) using the canonical uuidString round-trip.
                    if case .text(let s) = v, let u = UUID(uuidString: s) {
                        values[col] = .uuid(u)
                    }
                case "bitmap":
                    // .bitmap was stored as NSNumber(Int64), decoded as .int(i).
                    // Restore to .bitmap(i); the numeric value is identical.
                    if case .int(let i) = v {
                        values[col] = .bitmap(i)
                    }
                case "hlc":
                    // .hlc was stored as packed(h) (Int64 NSNumber), decoded as .int(packed).
                    // Restore by unpacking the Int64 back to the HLC struct.
                    if case .int(let packed) = v {
                        values[col] = .hlc(unpacked(packed))
                    }
                case "json":
                    // .json was stored as NSString (UTF-8) or NSData (non-UTF-8 blob).
                    // Restore .text(s) → .json(s.data) or .blob(d) → .json(d).
                    if case .text(let s) = v, let d = s.data(using: .utf8) {
                        values[col] = .json(d)
                    } else if case .blob(let d) = v {
                        values[col] = .json(d)
                    }
                case "fingerprint":
                    // .fingerprint was stored as 32 bytes of NSData (4 x UInt64 LE).
                    // Restore by reading back the four little-endian UInt64 words.
                    if case .blob(let d) = v, d.count == 32 {
                        let fp = d.withUnsafeBytes { ptr -> Fingerprint256 in
                            func readLE(at byteOffset: Int) -> UInt64 {
                                var raw: UInt64 = 0
                                withUnsafeMutableBytes(of: &raw) { dst in
                                    dst.copyBytes(from: ptr[byteOffset ..< byteOffset + 8])
                                }
                                return UInt64(littleEndian: raw)
                            }
                            return Fingerprint256(
                                block0: readLE(at: 0),
                                block1: readLE(at: 8),
                                block2: readLE(at: 16),
                                block3: readLE(at: 24)
                            )
                        }
                        values[col] = .fingerprint(fp)
                    }
                default:
                    // Unknown tag from a future encoder version. Leave the coarser
                    // discriminator in place (forward-compat: do not crash).
                    break
                }
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

    private static func assign(value: TypedValue, to record: any CKRecordKeyValueSetting, forKey key: String) throws {
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

// MARK: - SecretSync v1 transport mapping

public extension CKRecordMapping {
    private static var secretSyncCanonicalBytesKey: String { "ss_canonical_bytes" }
    private static var secretSyncRecordDigestKey: String { "ss_record_digest" }
    private static var secretSyncScopeIDKey: String { "ss_scope_id" }
    private static var secretSyncPolicyEpochKey: String { "ss_policy_epoch" }
    private static var secretSyncHeadCommitDigestKey: String { "ss_head_commit_digest" }
    private static var secretSyncPolicyDigestKey: String { "ss_policy_digest" }

    /// Map a validated immutable value to its content-addressed CloudKit record.
    static func secretSyncRecord(
        _ value: SecretSyncCloudKitImmutableRecord
    ) throws -> CKRecord {
        let zoneID = SecretSyncCloudKitZones.zoneID(for: value.type)
        let recordID = CKRecord.ID(
            recordName: value.digest.bytes.secretSyncLowercaseHex,
            zoneID: zoneID
        )
        let record = CKRecord(recordType: value.type.rawValue, recordID: recordID)
        // These are opaque canonical/ciphertext bytes, never decomposed into
        // searchable CloudKit fields. The digest is repeated only to make a
        // closed identity check possible before canonical validation.
        record[secretSyncCanonicalBytesKey] = value.canonicalBytes as NSData
        record[secretSyncRecordDigestKey] = value.digest.bytes as NSData
        return record
    }

    /// Decode and fully validate one immutable SecretSync CloudKit record.
    static func decodeSecretSyncImmutableRecord(
        _ record: CKRecord,
        digester: any SecretSyncDigesting
    ) throws -> SecretSyncCloudKitImmutableRecord {
        guard let type = SecretSyncCloudKitRecordType(rawValue: record.recordType),
              type.isImmutable else {
            throw SecretSyncCloudKitError.unsupportedRecordType
        }
        try validateSecretSyncImmutableTransportShape(record, type: type)
        guard let canonicalBytes = record[secretSyncCanonicalBytesKey] as? Data,
              let digestBytes = record[secretSyncRecordDigestKey] as? Data else {
            throw SecretSyncCloudKitError.invalidFieldSchema
        }
        let digest: SecretRecordDigest
        do {
            digest = try SecretRecordDigest(bytes: digestBytes)
        } catch {
            throw SecretSyncCloudKitError.invalidFieldSchema
        }
        guard record.recordID.recordName == digestBytes.secretSyncLowercaseHex else {
            throw SecretSyncCloudKitError.invalidRecordIdentity
        }
        return try SecretSyncCloudKitImmutableRecord(
            type: type,
            digest: digest,
            canonicalBytes: canonicalBytes,
            digester: digester
        )
    }

    /// Accept a content-addressed retry only when the existing and retry
    /// records have exactly the same type, identity, digest, and canonical
    /// bytes. A same-name/different-bytes collision always fails closed.
    static func validateSecretSyncImmutableIdempotency(
        existing: CKRecord,
        retry: CKRecord,
        digester: any SecretSyncDigesting
    ) throws {
        let existingValue = try decodeSecretSyncImmutableRecord(existing, digester: digester)
        let retryValue = try decodeSecretSyncImmutableRecord(retry, digester: digester)
        guard existing.recordID == retry.recordID,
              existingValue == retryValue else {
            throw SecretSyncCloudKitError.immutableCollision
        }
    }

    /// Construct the initial mutable scope head. Subsequent updates must use
    /// `applyingSecretSyncScopeHead(_:to:)` with a fetched record.
    static func secretSyncScopeHeadRecord(
        _ value: SecretSyncCloudKitScopeHead
    ) throws -> CKRecord {
        let scopeBytes = secretSyncUUIDBytes(value.scopeID.rawValue)
        let recordID = CKRecord.ID(
            recordName: scopeBytes.secretSyncLowercaseHex,
            zoneID: SecretSyncCloudKitZones.controlZoneID
        )
        let record = CKRecord(
            recordType: SecretSyncCloudKitRecordType.scopeHead.rawValue,
            recordID: recordID
        )
        try writeSecretSyncScopeHead(value, to: record)
        return record
    }

    /// Decode the fixed-width mutable scope-head fields without treating their
    /// presence as authorization or freshness proof.
    static func decodeSecretSyncScopeHead(
        _ record: CKRecord
    ) throws -> SecretSyncCloudKitScopeHead {
        try validateSecretSyncScopeHeadTransportShape(record)
        guard let scopeBytes = record[secretSyncScopeIDKey] as? Data,
              let scopeUUID = secretSyncUUID(from: scopeBytes),
              let epochBytes = record[secretSyncPolicyEpochKey] as? Data,
              let policyEpoch = secretSyncUInt64(from: epochBytes),
              let headBytes = record[secretSyncHeadCommitDigestKey] as? Data,
              let policyBytes = record[secretSyncPolicyDigestKey] as? Data else {
            throw SecretSyncCloudKitError.invalidFieldSchema
        }
        guard record.recordID.recordName == scopeBytes.secretSyncLowercaseHex else {
            throw SecretSyncCloudKitError.invalidRecordIdentity
        }
        do {
            return try SecretSyncCloudKitScopeHead(
                scopeID: SecretScopeID(scopeUUID),
                policyEpoch: policyEpoch,
                headCommitDigest: SecretRecordDigest(bytes: headBytes),
                policyDigest: SecretRecordDigest(bytes: policyBytes)
            )
        } catch {
            throw SecretSyncCloudKitError.invalidFieldSchema
        }
    }

    /// Apply a validated head update to the fetched record instance, preserving
    /// CloudKit system fields and its server change tag for compare-and-swap.
    static func applyingSecretSyncScopeHead(
        _ value: SecretSyncCloudKitScopeHead,
        to fetchedRecord: CKRecord
    ) throws -> CKRecord {
        let current = try decodeSecretSyncScopeHead(fetchedRecord)
        guard current.scopeID == value.scopeID else {
            throw SecretSyncCloudKitError.invalidRecordIdentity
        }
        try writeSecretSyncScopeHead(value, to: fetchedRecord)
        return fetchedRecord
    }

    internal static func validateSecretSyncRecordForWrite(
        _ record: CKRecord,
        digester: any SecretSyncDigesting
    ) throws
        -> SecretSyncCloudKitRecordType
    {
        guard let type = SecretSyncCloudKitRecordType(rawValue: record.recordType) else {
            throw SecretSyncCloudKitError.unsupportedRecordType
        }
        if type == .scopeHead {
            _ = try decodeSecretSyncScopeHead(record)
        } else {
            // Raw CKRecord callers cannot bypass content addressing: admission
            // re-runs the injected digest and exact canonical schema checks.
            _ = try decodeSecretSyncImmutableRecord(record, digester: digester)
        }
        return type
    }

    private static func validateSecretSyncImmutableTransportShape(
        _ record: CKRecord,
        type: SecretSyncCloudKitRecordType
    ) throws {
        let allowed = Set([secretSyncCanonicalBytesKey, secretSyncRecordDigestKey])
        guard record.recordID.zoneID == SecretSyncCloudKitZones.zoneID(for: type),
              let digest = record[secretSyncRecordDigestKey] as? Data,
              digest.count == SecretRecordDigest.byteCount else {
            throw SecretSyncCloudKitError.invalidFieldSchema
        }
        guard record.recordID.recordName == digest.secretSyncLowercaseHex else {
            throw SecretSyncCloudKitError.invalidRecordIdentity
        }
        guard Set(record.allKeys()) == allowed,
              record.encryptedValues.allKeys().isEmpty,
              record[secretSyncCanonicalBytesKey] is Data else {
            throw SecretSyncCloudKitError.invalidFieldSchema
        }
    }

    private static func validateSecretSyncScopeHeadTransportShape(_ record: CKRecord) throws {
        let allowed = Set([
            secretSyncScopeIDKey,
            secretSyncPolicyEpochKey,
            secretSyncHeadCommitDigestKey,
            secretSyncPolicyDigestKey,
        ])
        guard record.recordType == SecretSyncCloudKitRecordType.scopeHead.rawValue,
              record.recordID.zoneID == SecretSyncCloudKitZones.controlZoneID,
              Set(record.allKeys()) == allowed,
              record.encryptedValues.allKeys().isEmpty else {
            throw SecretSyncCloudKitError.invalidFieldSchema
        }
    }

    private static func writeSecretSyncScopeHead(
        _ value: SecretSyncCloudKitScopeHead,
        to record: CKRecord
    ) throws {
        let scopeBytes = secretSyncUUIDBytes(value.scopeID.rawValue)
        guard record.recordType == SecretSyncCloudKitRecordType.scopeHead.rawValue,
              record.recordID.zoneID == SecretSyncCloudKitZones.controlZoneID,
              record.recordID.recordName == scopeBytes.secretSyncLowercaseHex else {
            throw SecretSyncCloudKitError.invalidRecordIdentity
        }
        record[secretSyncScopeIDKey] = scopeBytes as NSData
        record[secretSyncPolicyEpochKey] = secretSyncUInt64Bytes(value.policyEpoch) as NSData
        record[secretSyncHeadCommitDigestKey] = value.headCommitDigest.bytes as NSData
        record[secretSyncPolicyDigestKey] = value.policyDigest.bytes as NSData
    }

    private static func secretSyncUUIDBytes(_ value: UUID) -> Data {
        var raw = value.uuid
        return withUnsafeBytes(of: &raw) { Data($0) }
    }

    private static func secretSyncUUID(from bytes: Data) -> UUID? {
        guard bytes.count == 16 else { return nil }
        let value = [UInt8](bytes)
        return UUID(uuid: (
            value[0], value[1], value[2], value[3],
            value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11],
            value[12], value[13], value[14], value[15]
        ))
    }

    private static func secretSyncUInt64Bytes(_ value: UInt64) -> Data {
        Data((0..<8).map { offset in
            UInt8(truncatingIfNeeded: value >> UInt64((7 - offset) * 8))
        })
    }

    private static func secretSyncUInt64(from bytes: Data) -> UInt64? {
        guard bytes.count == 8 else { return nil }
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

/// Sync metadata extracted from the `moot_sync_*` fields of a CKRecord.
/// Carried separately from `values` so `values` remains clean
/// (no `moot_sync_*` keys) while the engine retains the metadata needed
/// for conflict resolution and durable HLC persistence.
public struct SyncMeta: Sendable {
    public let hlc: HLC
    public let schemaVersion: Int
    public let kitID: String
}

public struct DecodedRecord: Sendable {
    public let table: String
    public let rowKey: UUID
    /// App-data values. Contains no `moot_sync_*` keys.
    public let values: [String: TypedValue]
    /// Sync metadata extracted during decode.
    public let syncMeta: SyncMeta
    /// True when this record represents a delete tombstone (`moot_sync_deleted == 1`).
    ///
    /// WHY: the tombstone flag routes this record to the tombstone apply path
    /// in `applyInbound` — LWW gate → hard-delete row → persist delete HLC in
    /// `_ck_sync_meta` (A6 adjudication). Without the flag the receiver would
    /// attempt a normal upsert on an empty values map, creating a phantom row.
    /// Defaults to false for normal (non-delete) records.
    public var isTombstone: Bool = false

    /// Per-column HLC map decoded from `moot_sync_column_hlcs` (B-8).
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
