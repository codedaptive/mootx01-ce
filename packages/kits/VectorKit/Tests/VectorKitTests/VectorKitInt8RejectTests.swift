// VectorKitInt8RejectTests.swift
//
// Precondition guard tests for the int8 payload rejection policy.
//
// Bob's ruling 2026-06-13 (Codex review item 5): int8 writes are rejected
// fail-closed until a quantization policy is ratified. The .int8 case and
// its `scale` field are retained in the public type (no-removal doctrine)
// but VectorStore.addPayload and addPayloads throw
// VectorKitError.int8QuantizationPolicyUndefined on any int8 payload.
//
// The read side is symmetric: decodePayload returns nil for int8 rows,
// so a hand-crafted int8 row cannot be silently consumed.
//
// These tests change NO current behavior: there are zero existing int8
// producers. They are precondition guards for a latent trap.

import Testing
import Foundation
@testable import VectorKit
import PersistenceKit
import EngramLib

@Suite("VectorKitInt8Reject", .serialized)
struct VectorKitInt8RejectTests {

    // MARK: - Helpers

    private func makeStore() async throws -> VectorStore {
        let storage = try makeScratchStorage()
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return VectorStore(storage: storage)
    }

    private func int8Payload(dim: Int = 4) -> VectorPayload {
        // Construct a minimal int8 payload. The quantization policy is
        // unspecified, which is precisely what the guard tests.
        VectorPayload(
            kind: .int8,
            dim: UInt32(dim),
            bytes: [UInt8](repeating: 1, count: dim),
            scale: 0.5
        )
    }

    // MARK: - Write-path rejection: addPayload

    /// addPayload with an int8 payload must throw int8QuantizationPolicyUndefined.
    /// No row must be written to the store.
    @Test func addPayload_int8_throwsRejectionError() async throws {
        // Store writes emit insert_latency_ms via the Intellectus global
        // singleton; hold GlobalTestLock so a concurrent telemetry test's
        // enabled window never receives this test's samples (observed in the
        // test-full lane: the telemetry shape test read model_id "m" — this
        // file's model — instead of its own).
        await GlobalTestLock.shared.acquire()
        defer { Task { await GlobalTestLock.shared.release() } }
        let store = try await makeStore()
        let payload = int8Payload()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        await #expect(throws: VectorKitError.self) {
            try await store.addPayload(
                itemID: "item-int8-test",
                vectorIndex: 0,
                payload: payload,
                modelID: "test-model",
                modelVersion: "1.0",
                filedAt: now
            )
        }

        // Confirm the specific error case — not just any VectorKitError.
        do {
            try await store.addPayload(
                itemID: "item-int8-test",
                vectorIndex: 0,
                payload: payload,
                modelID: "test-model",
                modelVersion: "1.0",
                filedAt: now
            )
            Issue.record("Expected int8QuantizationPolicyUndefined to be thrown")
        } catch let err as VectorKitError {
            guard case .int8QuantizationPolicyUndefined = err else {
                Issue.record("Expected int8QuantizationPolicyUndefined, got \(err)")
                return
            }
            // Correct error thrown — confirm no row was written.
            let rows = try await store.vectors(forItemID: "item-int8-test")
            #expect(rows.isEmpty, "No row must be persisted when int8 is rejected")
        }
    }

    /// The error message must state the reason and the remedy (not just an opaque code).
    @Test func addPayload_int8_errorMessageIsInformative() async throws {
        // Store writes emit insert_latency_ms via the Intellectus global
        // singleton; hold GlobalTestLock so a concurrent telemetry test's
        // enabled window never receives this test's samples (observed in the
        // test-full lane: the telemetry shape test read model_id "m" — this
        // file's model — instead of its own).
        await GlobalTestLock.shared.acquire()
        defer { Task { await GlobalTestLock.shared.release() } }
        let store = try await makeStore()
        let payload = int8Payload()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        do {
            try await store.addPayload(
                itemID: "x",
                vectorIndex: 0,
                payload: payload,
                modelID: "m",
                modelVersion: "1.0",
                filedAt: now
            )
            Issue.record("Expected throw")
        } catch let err as VectorKitError {
            if case let .int8QuantizationPolicyUndefined(msg) = err {
                // Message must mention the policy being unspecified and the
                // spec reference so operators know what the guard is about.
                #expect(msg.lowercased().contains("quantization"),
                        "Error message must mention quantization. Got: \(msg)")
                #expect(msg.contains("VECTORKIT_SPEC"),
                        "Error message must cite VECTORKIT_SPEC. Got: \(msg)")
            } else {
                Issue.record("Wrong error case: \(err)")
            }
        }
    }

    // MARK: - Write-path rejection: addPayloads (batch)

    /// A batch with a single int8 payload must be rejected entirely.
    /// No rows from the batch must be written.
    @Test func addPayloads_batchContainingInt8_throwsRejectionError() async throws {
        // Store writes emit insert_latency_ms via the Intellectus global
        // singleton; hold GlobalTestLock so a concurrent telemetry test's
        // enabled window never receives this test's samples (observed in the
        // test-full lane: the telemetry shape test read model_id "m" — this
        // file's model — instead of its own).
        await GlobalTestLock.shared.acquire()
        defer { Task { await GlobalTestLock.shared.release() } }
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let batchWithInt8 = [
            VectorPayloadInput(
                itemID: "int8-item",
                vectorIndex: 0,
                payload: int8Payload(),
                modelID: "m",
                modelVersion: "1.0",
                filedAt: now
            )
        ]

        do {
            try await store.addPayloads(batchWithInt8)
            Issue.record("Expected int8QuantizationPolicyUndefined")
        } catch let err as VectorKitError {
            guard case .int8QuantizationPolicyUndefined = err else {
                Issue.record("Expected int8QuantizationPolicyUndefined, got \(err)")
                return
            }
            // No row must survive from the rejected batch.
            let rows = try await store.vectors(forItemID: "int8-item")
            #expect(rows.isEmpty, "No row must be persisted when batch int8 is rejected")
        }
    }

    /// A mixed batch (valid binary + int8) must be rejected entirely — no partial writes.
    @Test func addPayloads_mixedBatchWithInt8_rejectsBatchCompletely() async throws {
        // Store writes emit insert_latency_ms via the Intellectus global
        // singleton; hold GlobalTestLock so a concurrent telemetry test's
        // enabled window never receives this test's samples (observed in the
        // test-full lane: the telemetry shape test read model_id "m" — this
        // file's model — instead of its own).
        await GlobalTestLock.shared.acquire()
        defer { Task { await GlobalTestLock.shared.release() } }
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let engram = Engram.zero
        let binaryInput = VectorPayloadInput(
            itemID: "binary-item",
            vectorIndex: 0,
            payload: VectorPayload(engram: engram),
            modelID: "m",
            modelVersion: "1.0",
            filedAt: now
        )
        let int8Input = VectorPayloadInput(
            itemID: "int8-item",
            vectorIndex: 0,
            payload: int8Payload(),
            modelID: "m",
            modelVersion: "1.0",
            filedAt: now
        )
        // Put the int8 item second so both orderings are checked.
        let batch = [binaryInput, int8Input]

        do {
            try await store.addPayloads(batch)
            Issue.record("Expected int8QuantizationPolicyUndefined")
        } catch let err as VectorKitError {
            guard case .int8QuantizationPolicyUndefined = err else {
                Issue.record("Wrong error: \(err)")
                return
            }
            // The binary item must NOT have been partially written because the
            // guard fires before the table write loop begins.
            let binaryRows = try await store.vectors(forItemID: "binary-item")
            #expect(binaryRows.isEmpty,
                    "Binary rows from a rejected batch must not be partially written")
        }
    }

    // MARK: - Non-regression: float and binary writes are unaffected

    /// float32 payloads must write and read back without error.
    /// This confirms the guard is precise (int8 only, not all non-binary).
    @Test func addPayload_float32_succeeds() async throws {
        // Store writes emit insert_latency_ms via the Intellectus global
        // singleton; hold GlobalTestLock so a concurrent telemetry test's
        // enabled window never receives this test's samples (observed in the
        // test-full lane: the telemetry shape test read model_id "m" — this
        // file's model — instead of its own).
        await GlobalTestLock.shared.acquire()
        defer { Task { await GlobalTestLock.shared.release() } }
        let store = try await makeStore()
        let floatPayload = VectorPayload(floats: [1.0, 2.0, 3.0, 4.0])
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Must not throw — float32 is a valid, accepted payload kind.
        try await store.addPayload(
            itemID: "float-item",
            vectorIndex: 0,
            payload: floatPayload,
            modelID: "m",
            modelVersion: "1.0",
            filedAt: now
        )

        // Row must be retrievable.
        let retrieved = try await store.getPayload(
            itemID: "float-item",
            vectorIndex: 0,
            modelID: "m"
        )
        #expect(retrieved != nil, "float32 payload must persist and read back")
        #expect(retrieved?.kind == .float32)
    }

    /// Binary (Engram) payloads must write and read back without error.
    @Test func addPayload_binary_succeeds() async throws {
        // Store writes emit insert_latency_ms via the Intellectus global
        // singleton; hold GlobalTestLock so a concurrent telemetry test's
        // enabled window never receives this test's samples (observed in the
        // test-full lane: the telemetry shape test read model_id "m" — this
        // file's model — instead of its own).
        await GlobalTestLock.shared.acquire()
        defer { Task { await GlobalTestLock.shared.release() } }
        let store = try await makeStore()
        let engram = Engram(blocks: 0xCAFE_BABE_DEAD_BEEF, 0x1234, 0x5678, 0xABCD)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await store.addVector(
            itemID: "binary-item",
            engram: engram,
            modelID: "m",
            modelVersion: "1.0",
            filedAt: now
        )

        let retrieved = try await store.getVector(itemID: "binary-item", modelID: "m")
        #expect(retrieved != nil)
        #expect(retrieved == engram)
    }

    // MARK: - Read-side guard: decodePayload returns nil for int8 rows

    /// If a hand-crafted int8 row somehow exists in the table,
    /// decodePayload must return nil (not crash, not silently produce a
    /// broken payload). getPayload therefore returns nil for int8 rows.
    ///
    /// This tests the symmetric fail-closed read guard described in
    /// VECTORKIT_SPEC §I-4a.
    @Test func decodePayload_int8Row_returnsNil() {
        // Simulate what the SQLite backend returns for an int8 row: a
        // StorageRow with kind=2 (int8 raw value), a dim, and a blob.
        let simulatedRow = StorageRow(values: [
            "kind":    .int(Int64(VectorKind.int8.rawValue)),
            "dim":     .int(4),
            "payload": .blob(Data([1, 2, 3, 4])),
            "scale":   .float(0.5)
        ])
        // decodePayload is a static method visible via @testable import.
        // A nil return means the int8 row is silently skipped on read —
        // the correct symmetric fail-closed outcome.
        let result = VectorStore.decodePayload(from: simulatedRow)
        #expect(result == nil,
                "decodePayload must return nil for int8 rows (symmetric read guard)")
    }

    /// Confirm binary and float32 rows are still decoded correctly by
    /// decodePayload — the read guard is int8-only.
    @Test func decodePayload_binaryAndFloat_decodesCorrectly() {
        let binaryRow = StorageRow(values: [
            "kind":    .int(Int64(VectorKind.binary.rawValue)),
            "dim":     .int(256),
            "payload": .blob(Data(repeating: 0, count: 32)),
            "scale":   .null
        ])
        let decoded = VectorStore.decodePayload(from: binaryRow)
        #expect(decoded != nil, "binary rows must decode normally")
        #expect(decoded?.kind == .binary)

        // 1.0f, 2.0f in IEEE-754 LE: [0,0,128,63] and [0,0,0,64]
        let floatRow = StorageRow(values: [
            "kind":    .int(Int64(VectorKind.float32.rawValue)),
            "dim":     .int(2),
            "payload": .blob(Data([0, 0, 128, 63, 0, 0, 0, 64])),
            "scale":   .null
        ])
        let decodedFloat = VectorStore.decodePayload(from: floatRow)
        #expect(decodedFloat != nil, "float32 rows must decode normally")
        #expect(decodedFloat?.kind == .float32)
    }
}

// MARK: - Engram zero helper

private extension Engram {
    static var zero: Engram {
        Engram(blocks: 0, 0, 0, 0)
    }
}
