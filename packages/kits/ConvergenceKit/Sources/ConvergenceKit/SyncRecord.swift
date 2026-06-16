// SyncRecord.swift
//
// Wire format for replicated row mutations.
//
// SyncRecord wraps a PersistenceKit TableChange with sync metadata
// (schema version, kit ID, HLC). The receiver decodes, validates
// schema and kit, and applies the change through its local
// PersistenceKit. Schema or kit mismatch causes the record to be
// rejected (queued for retry post-app-update).

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

    public init(
        table: String,
        event: SyncEventKind,
        rowKey: UUID,
        values: SyncValueMap?,
        hlc: PackedHLC,
        schemaVersion: Int,
        kitID: String
    ) {
        self.table = table
        self.event = event
        self.rowKey = rowKey
        self.values = values
        self.hlc = hlc
        self.schemaVersion = schemaVersion
        self.kitID = kitID
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

/// Codable wrapper for SubstrateLib.HLC. The packed form is
/// stable across encoders.
public struct PackedHLC: Sendable, Codable, Hashable {
    public let physicalTime: Int64
    public let logicalCount: Int32
    public let nodeID: Int32

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
public struct SyncValueBox: Sendable, Codable {
    public let kind: String
    public let payload: Payload

    public enum Payload: Sendable, Codable {
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
