// VectorStoreDecodeGuardTests.swift
//
// Guard tests for the integer-narrowing safety checks added to
// VectorStore.decodePayload and VectorStore.storedVector.
//
// SECURITY FIX (planned hardening 2026-06-28): SQLite columns are Int64,
// so a malformed or hand-crafted row can carry any Int64 value in `kind`,
// `dim`, or `vector_index`. The old code used UInt8(kindRaw), UInt32(dim),
// and UInt32(vectorIndex) without range guards — these trap in Swift when
// the value is out of the target type's range. The fix rejects malformed
// rows (returns nil) rather than crashing.

import Testing
import Foundation
@testable import VectorKit
import PersistenceKit

@Suite("VectorStoreDecodeGuard")
struct VectorStoreDecodeGuardTests {

    // MARK: - decodePayload: kindRaw out-of-range

    /// A negative kind value cannot be narrowed to UInt8 — must return nil,
    /// not trap.
    @Test func decodePayload_negativeKind_returnsNil() {
        let row = StorageRow(values: [
            "kind":    .int(-1),  // negative: was UInt8(-1) → trap
            "dim":     .int(32),
            "payload": .blob(Data(repeating: 0, count: 32)),
        ])
        let result = VectorStore.decodePayload(from: row)
        #expect(result == nil,
                "decodePayload must return nil for kind=-1, not trap on UInt8(-1)")
    }

    /// A kind value above 255 cannot be narrowed to UInt8 — must return nil.
    @Test func decodePayload_kindAbove255_returnsNil() {
        let row = StorageRow(values: [
            "kind":    .int(256),  // > UInt8.max
            "dim":     .int(32),
            "payload": .blob(Data(repeating: 0, count: 32)),
        ])
        let result = VectorStore.decodePayload(from: row)
        #expect(result == nil,
                "decodePayload must return nil for kind=256, not trap on UInt8(256)")
    }

    /// A very large kind value (Int64.max) must also be rejected safely.
    @Test func decodePayload_kindInt64Max_returnsNil() {
        let row = StorageRow(values: [
            "kind":    .int(Int64.max),
            "dim":     .int(32),
            "payload": .blob(Data(repeating: 0, count: 32)),
        ])
        let result = VectorStore.decodePayload(from: row)
        #expect(result == nil,
                "decodePayload must return nil for kind=Int64.max")
    }

    // MARK: - decodePayload: dim out-of-range

    /// A negative dim cannot be narrowed to UInt32 — must return nil.
    @Test func decodePayload_negativeDim_returnsNil() {
        let row = StorageRow(values: [
            "kind":    .int(Int64(VectorKind.binary.rawValue)),
            "dim":     .int(-1),   // negative: was UInt32(-1) → trap
            "payload": .blob(Data(repeating: 0, count: 32)),
        ])
        let result = VectorStore.decodePayload(from: row)
        #expect(result == nil,
                "decodePayload must return nil for dim=-1, not trap on UInt32(-1)")
    }

    // MARK: - storedVector: vectorIndex out-of-range

    /// A negative vector_index cannot be narrowed to UInt32 — must return nil.
    @Test func storedVector_negativeVectorIndex_returnsNil() {
        let row = StorageRow(values: [
            "id":            .uuid(UUID()),
            "item_id":       .text("drawer-A"),
            "vector_index":  .int(-1),   // negative: was UInt32(-1) → trap
            "model_id":      .text("minilm-v6"),
            "model_version": .text("1.0.0"),
            "filed_at":      .timestamp(Date()),
            // decodePayload also needs kind/dim/payload:
            "kind":          .int(Int64(VectorKind.binary.rawValue)),
            "dim":           .int(256),
            "payload":       .blob(Data(repeating: 0, count: 32)),
        ])
        let result = VectorStore.storedVector(from: row)
        #expect(result == nil,
                "storedVector must return nil for vector_index=-1, not trap on UInt32(-1)")
    }

    // MARK: - Non-regression: valid rows still decode

    /// A valid binary row with non-negative kindRaw/dim/vectorIndex must decode.
    @Test func decodePayload_validBinaryRow_decodes() {
        let row = StorageRow(values: [
            "kind":    .int(Int64(VectorKind.binary.rawValue)),
            "dim":     .int(256),
            "payload": .blob(Data(repeating: 0xAB, count: 32)),
        ])
        let result = VectorStore.decodePayload(from: row)
        #expect(result != nil, "valid binary row must decode")
        #expect(result?.kind == .binary)
        #expect(result?.dim == 256)
    }

    /// A valid float32 row must decode.
    @Test func decodePayload_validFloat32Row_decodes() {
        let row = StorageRow(values: [
            "kind":    .int(Int64(VectorKind.float32.rawValue)),
            "dim":     .int(4),
            "payload": .blob(Data(repeating: 0, count: 16)),
        ])
        let result = VectorStore.decodePayload(from: row)
        #expect(result != nil, "valid float32 row must decode")
        #expect(result?.kind == .float32)
    }
}
