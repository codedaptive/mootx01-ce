// SyncRecord.swift
//
// Wire format for replicated row mutations.
//
// SyncRecord wraps a PersistenceKit TableChange with sync metadata
// (schema version, kit ID, HLC). The receiver decodes, validates
// schema and kit, and applies the change through its local
// PersistenceKit. Schema or kit mismatch causes the record to be
// rejected (SyncError.kitMismatch / .schemaMismatch); no retry queue
// is present in this layer.

import Foundation
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
import PersistenceKit

public struct SyncRecord: Sendable, Codable {
    public let table: String
    public let event: SyncEventKind
    public let rowKey: UUID
    public let values: SyncValueMap?
    public let hlc: PackedHLC
    public let schemaVersion: Int
    public let kitID: String
    /// Set to `true` when this record represents a delete tombstone.
    ///
    /// WHY a separate field instead of relying solely on `event == .delete`:
    /// the tombstone concept is distinct from the event kind in that it
    /// also signals that the deletion HLC must persist in the side table
    /// after the row is hard-deleted (A6 adjudication). Explicit flag
    /// keeps the semantics clear and matches the Rust wire format
    /// (`sync_deleted: Option<bool>`, omitted when nil — C-8 parity).
    ///
    /// Omitted (nil) in JSON when not a tombstone; decoded as nil when
    /// absent (Rust `#[serde(default)]` provides the same null default).
    public let syncDeleted: Bool?

    /// Per-column HLC map for the `fieldLevelLWW` conflict policy (B-8).
    ///
    /// WHY wire-carried (not receiver-derived — A7):
    /// The sender knows exactly which columns were written and at which
    /// HLC. The receiver does not: it sees only the full row snapshot.
    /// Receivers must not fabricate column HLCs from the row-grain HLC —
    /// that would treat all columns as written simultaneously, erasing the
    /// finer-grained write ordering the protocol is designed to preserve.
    ///
    /// Nil when `conflictPolicy != .fieldLevelLWW` or when the sender does
    /// not support field-level LWW (backward-compat: treat as row-grain LWW).
    /// Omitted from JSON when nil (C-8 parity with Rust `skip_serializing_if`).
    public let columnHLCs: ColumnHLCMap?

    /// Explicit CodingKeys documenting the cross-port JSON contract.
    /// Rust serde renames match these exact strings (`rename_all = "camelCase"`
    /// plus explicit `rename = "kitID"` for the ID suffix convention).
    private enum CodingKeys: String, CodingKey {
        case table, event, rowKey, values, hlc, schemaVersion, kitID, syncDeleted, columnHLCs
    }

    public init(
        table: String,
        event: SyncEventKind,
        rowKey: UUID,
        values: SyncValueMap?,
        hlc: PackedHLC,
        schemaVersion: Int,
        kitID: String,
        syncDeleted: Bool? = nil,
        columnHLCs: ColumnHLCMap? = nil
    ) {
        self.table = table
        self.event = event
        self.rowKey = rowKey
        self.values = values
        self.hlc = hlc
        self.schemaVersion = schemaVersion
        self.kitID = kitID
        self.syncDeleted = syncDeleted
        self.columnHLCs = columnHLCs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(table, forKey: .table)
        try container.encode(event, forKey: .event)
        try container.encode(rowKey, forKey: .rowKey)
        try container.encodeIfPresent(values, forKey: .values)
        try container.encode(hlc, forKey: .hlc)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kitID, forKey: .kitID)
        // Omit syncDeleted when nil — Rust serde `skip_serializing_if = "Option::is_none"` parity.
        try container.encodeIfPresent(syncDeleted, forKey: .syncDeleted)
        // Omit columnHLCs when nil — present only for fieldLevelLWW records.
        try container.encodeIfPresent(columnHLCs, forKey: .columnHLCs)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        table = try container.decode(String.self, forKey: .table)
        event = try container.decode(SyncEventKind.self, forKey: .event)
        rowKey = try container.decode(UUID.self, forKey: .rowKey)
        values = try container.decodeIfPresent(SyncValueMap.self, forKey: .values)
        hlc = try container.decode(PackedHLC.self, forKey: .hlc)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        kitID = try container.decode(String.self, forKey: .kitID)
        // Absent in JSON from older peers — defaults to nil (not a tombstone).
        syncDeleted = try container.decodeIfPresent(Bool.self, forKey: .syncDeleted)
        // Absent when sender does not support fieldLevelLWW — backward compat.
        columnHLCs = try container.decodeIfPresent(ColumnHLCMap.self, forKey: .columnHLCs)
    }
}

/// Codable mirror of PersistenceKit.StorageEvent.
public enum SyncEventKind: String, Sendable, Codable {
    case insert
    case update
    case delete

    public init(from event: StorageEvent) {
        switch event {
        case .insert: self = .insert
        case .update: self = .update
        case .delete: self = .delete
        }
    }

    public var asStorageEvent: StorageEvent {
        switch self {
        case .insert: return .insert
        case .update: return .update
        case .delete: return .delete
        }
    }
}

/// Codable wrapper for SubstrateTypes.HLC. The packed form is
/// stable across encoders.
public struct PackedHLC: Sendable, Codable, Hashable {
    public let physicalTime: Int64
    public let logicalCount: Int32
    public let nodeID: Int32

    /// Explicit CodingKeys documenting the cross-port JSON contract.
    /// Rust serde renames match these exact strings.
    private enum CodingKeys: String, CodingKey {
        case physicalTime, logicalCount, nodeID
    }

    public init(_ hlc: HLC) {
        self.physicalTime = hlc.physicalTime
        self.logicalCount = hlc.logicalCount
        self.nodeID = hlc.nodeID
    }

    public var asHLC: HLC {
        HLC(physicalTime: physicalTime, logicalCount: logicalCount, nodeID: nodeID)
    }
}

/// Codable wrapper for [String: TypedValue]. TypedValue's cases
/// don't all map cleanly to JSON natives so each value is encoded
/// with a discriminator tag.
public struct SyncValueMap: Sendable, Codable {
    public let entries: [String: SyncValueBox]

    public init(_ raw: [String: TypedValue]) {
        var out: [String: SyncValueBox] = [:]
        for (k, v) in raw {
            out[k] = SyncValueBox(v)
        }
        self.entries = out
    }

    public var asTypedValues: [String: TypedValue] {
        var out: [String: TypedValue] = [:]
        for (k, v) in entries {
            out[k] = v.asTypedValue
        }
        return out
    }
}

/// One TypedValue case, encoded with a discriminator.
///
/// JSON contract: adjacently-tagged encoding matching Rust's
/// `#[serde(tag = "kind", content = "payload")]`. The `kind` field
/// carries the type discriminator; `payload` carries the raw value.
/// For the `null` kind, `payload` is omitted (Rust serde omits
/// content for unit variants).
///
/// Timestamp payload is epoch seconds (Int64), matching Rust's
/// `TypedValue::Timestamp(i64)`. Binary data (blob, json) is
/// encoded as a JSON array of UInt8, matching Rust's `Vec<u8>`
/// serde default.
public struct SyncValueBox: Sendable {
    public let kind: String
    public let payload: Payload

    public enum Payload: Sendable {
        case null
        case bool(Bool)
        case int(Int64)
        case bitmap(Int64)
        case float(Double)
        case text(String)
        case bytes(Data)
        case uuid(UUID)
        case timestamp(Date)
        case hlc(PackedHLC)
        case fingerprint(FingerprintWire)
        case array([SyncValueBox])
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    public init(_ v: TypedValue) {
        switch v {
        case .null: self.kind = "null"; self.payload = .null
        case .bool(let b): self.kind = "bool"; self.payload = .bool(b)
        case .int(let i): self.kind = "int"; self.payload = .int(i)
        case .bitmap(let i): self.kind = "bitmap"; self.payload = .bitmap(i)
        case .float(let f): self.kind = "float"; self.payload = .float(f)
        case .text(let s): self.kind = "text"; self.payload = .text(s)
        case .blob(let d): self.kind = "blob"; self.payload = .bytes(d)
        case .uuid(let u): self.kind = "uuid"; self.payload = .uuid(u)
        case .timestamp(let d): self.kind = "timestamp"; self.payload = .timestamp(d)
        case .json(let d): self.kind = "json"; self.payload = .bytes(d)
        case .hlc(let h): self.kind = "hlc"; self.payload = .hlc(PackedHLC(h))
        case .fingerprint(let f): self.kind = "fingerprint"; self.payload = .fingerprint(FingerprintWire(f))
        case .array(let arr): self.kind = "array"; self.payload = .array(arr.map { SyncValueBox($0) })
        }
    }

    public var asTypedValue: TypedValue {
        switch payload {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i):
            return kind == "bitmap" ? .bitmap(i) : .int(i)
        case .bitmap(let i): return .bitmap(i)
        case .float(let f): return .float(f)
        case .text(let s): return .text(s)
        case .bytes(let d):
            return kind == "json" ? .json(d) : .blob(d)
        case .uuid(let u): return .uuid(u)
        case .timestamp(let d): return .timestamp(d)
        case .hlc(let h): return .hlc(h.asHLC)
        case .fingerprint(let f): return .fingerprint(f.asFingerprint)
        case .array(let arr): return .array(arr.map { $0.asTypedValue })
        }
    }
}

extension SyncValueBox: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch payload {
        case .null:
            // Rust serde omits content for unit variants; we do the same.
            break
        case .bool(let v):
            try container.encode(v, forKey: .payload)
        case .int(let v), .bitmap(let v):
            try container.encode(v, forKey: .payload)
        case .float(let v):
            try container.encode(v, forKey: .payload)
        case .text(let v):
            try container.encode(v, forKey: .payload)
        case .bytes(let d):
            // Encode as [UInt8] array matching Rust's Vec<u8> serde default.
            try container.encode(Array(d), forKey: .payload)
        case .uuid(let v):
            try container.encode(v, forKey: .payload)
        case .timestamp(let d):
            // Epoch seconds as Int64, matching Rust's Timestamp(i64).
            // Guard against non-finite or out-of-range intervals before the
            // narrowing cast — Int64(_:) traps on NaN, ±infinity, or any
            // Double whose magnitude exceeds Int64.max (~9.2e18 seconds,
            // year 292 billion). Corrupt inbound sync data can produce such
            // values; we surface a clear encode error rather than a crash.
            let interval = d.timeIntervalSince1970
            guard interval.isFinite,
                  interval >= Double(Int64.min),
                  interval <= Double(Int64.max) else {
                throw EncodingError.invalidValue(
                    interval,
                    EncodingError.Context(
                        codingPath: container.codingPath + [CodingKeys.payload],
                        debugDescription:
                            "timestamp interval \(interval) is non-finite or out of Int64 range"
                    )
                )
            }
            try container.encode(Int64(interval), forKey: .payload)
        case .hlc(let v):
            try container.encode(v, forKey: .payload)
        case .fingerprint(let v):
            try container.encode(v, forKey: .payload)
        case .array(let v):
            try container.encode(v, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "null":
            payload = .null
        case "bool":
            payload = .bool(try container.decode(Bool.self, forKey: .payload))
        case "int":
            payload = .int(try container.decode(Int64.self, forKey: .payload))
        case "bitmap":
            payload = .bitmap(try container.decode(Int64.self, forKey: .payload))
        case "float":
            payload = .float(try container.decode(Double.self, forKey: .payload))
        case "text":
            payload = .text(try container.decode(String.self, forKey: .payload))
        case "blob", "json":
            let bytes = try container.decode([UInt8].self, forKey: .payload)
            payload = .bytes(Data(bytes))
        case "uuid":
            payload = .uuid(try container.decode(UUID.self, forKey: .payload))
        case "timestamp":
            let secs = try container.decode(Int64.self, forKey: .payload)
            payload = .timestamp(Date(timeIntervalSince1970: TimeInterval(secs)))
        case "hlc":
            payload = .hlc(try container.decode(PackedHLC.self, forKey: .payload))
        case "fingerprint":
            payload = .fingerprint(try container.decode(FingerprintWire.self, forKey: .payload))
        case "array":
            payload = .array(try container.decode([SyncValueBox].self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown SyncValueBox kind: \(kind)"
            )
        }
    }
}

public struct FingerprintWire: Sendable, Codable, Hashable {
    public let block0: UInt64
    public let block1: UInt64
    public let block2: UInt64
    public let block3: UInt64

    public init(_ fp: Fingerprint256) {
        self.block0 = fp.block0
        self.block1 = fp.block1
        self.block2 = fp.block2
        self.block3 = fp.block3
    }

    public var asFingerprint: Fingerprint256 {
        Fingerprint256(block0: block0, block1: block1, block2: block2, block3: block3)
    }
}
