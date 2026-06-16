// TypedValue.swift
//
// Typed value carrier for PersistenceKit. Every value crossing the
// kit boundary is wrapped in TypedValue; backends pattern-match
// on the case and emit backend-native wire format.
//
// The case set is closed. Adding cases requires updating every
// backend; that's the right cost for backend portability.

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

public enum TypedValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case bitmap(Int64)          // semantically distinct from int; backends may apply bitmap-specific storage hints
    case float(Double)
    case text(String)
    case blob(Data)
    case uuid(UUID)
    case timestamp(Date)        // stored as ISO-8601 UTC text or backend-native timestamp
    case json(Data)             // pre-encoded JSON bytes; backends with native JSON columns can use them
    case hlc(HLC)               // packed UInt64 via HLC.packed
    case fingerprint(Fingerprint256)  // 32-byte representation
    case array([TypedValue])    // homogeneous; backends emit as JSON array or native array
}

public extension TypedValue {
    var typeDescription: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .bitmap: return "bitmap"
        case .float: return "float"
        case .text: return "text"
        case .blob: return "blob"
        case .uuid: return "uuid"
        case .timestamp: return "timestamp"
        case .json: return "json"
        case .hlc: return "hlc"
        case .fingerprint: return "fingerprint"
        case .array: return "array"
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
