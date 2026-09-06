// SpanVectorStoreTests.swift
//
// Encoder span rows in the vectors table (ENCODER_RERANK_CONTRACT §3):
// writeSpanVectors / spanVectors / deleteSpanVectors / reclaimRetiredVectorRows.
//
// Failure modes pinned:
//   1. Round trip: 3 spans written under one item come back in index order
//      with their int8 bytes, scale and ext bounds intact. A port that stores
//      bytes without two's-complement conversion, drops the scale, or mangles
//      the ext JSON fails here.
//   2. Replace, never append: a second writeSpanVectors with 2 spans leaves
//      exactly 2 rows. A port that upserts by (item, index) leaves the stale
//      third span; a port that inserts without deleting hits the UNIQUE
//      constraint or returns 5 rows.
//   3. Reclaim: rows under a retired model id and rows at a non-serving
//      generation are deleted; serving rows of a live model survive.

import Testing
import Foundation
import PersistenceKit
@testable import SynapseKit

@Suite("SpanVectorStore", .serialized)
struct SpanVectorStoreTests {

    private func makeStore() async throws -> VectorStore {
        let storage = try makeScratchStorage()
        try await storage.open(schema: VectorStore.schemaDeclaration)
        return VectorStore(storage: storage)
    }

    private func span(_ index: UInt32, _ bytes: [Int8], scale: Float, start: Int, end: Int) -> SpanVectorInput {
        SpanVectorInput(index: index, int8: bytes, scale: scale, startWord: start, endWord: end,
                        contentVersion: "cv-\(index)")
    }

    @Test("three spans round-trip in index order with bounds, scale and bytes intact")
    func roundTrip() async throws {
        await GlobalTestLock.shared.acquire()
        defer { Task { await GlobalTestLock.shared.release() } }
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        // Written out of order on purpose: the read path orders by vector_index.
        let spans = [
            span(2, [127, -127, 0, 5], scale: 0.0078, start: 60, end: 120),
            span(0, [1, -1, 2, -2], scale: 0.5, start: 0, end: 60),
            span(1, [-128, 127, 64, -64], scale: 0.25, start: 30, end: 90),
        ]
        try await store.writeSpanVectors(itemID: "item-a", modelID: "minilm-l6-v2-w60",
                                         modelVersion: "r1", spans: spans, filedAt: now)
        let rows = try await store.spanVectors(itemIDs: ["item-a", "item-missing"], modelID: "minilm-l6-v2-w60")
        #expect(rows.keys.sorted() == ["item-a"], "items without span rows are absent")
        let got = try #require(rows["item-a"])
        #expect(got.map(\.index) == [0, 1, 2])
        #expect(got[1].int8 == [-128, 127, 64, -64], "two's-complement bytes survive the BLOB round trip")
        #expect(got[1].scale == Float(0.25))
        #expect(got[2].startWord == 60 && got[2].endWord == 120 && got[2].contentVersion == "cv-2")
        // A different model id sees nothing: spans are keyed by model identity.
        let other = try await store.spanVectors(itemIDs: ["item-a"], modelID: "minilm-l6-v2-w150")
        #expect(other.isEmpty)
    }

    @Test("a second write replaces the span set; it never appends")
    func replaceNotAppend() async throws {
        await GlobalTestLock.shared.acquire()
        defer { Task { await GlobalTestLock.shared.release() } }
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let model = "minilm-l6-v2-w60"
        try await store.writeSpanVectors(itemID: "item-b", modelID: model, modelVersion: "r1", spans: [
            span(0, [1, 2], scale: 1, start: 0, end: 60),
            span(1, [3, 4], scale: 1, start: 30, end: 90),
            span(2, [5, 6], scale: 1, start: 60, end: 100),
        ], filedAt: now)
        try await store.writeSpanVectors(itemID: "item-b", modelID: model, modelVersion: "r1", spans: [
            span(0, [9, 9], scale: 2, start: 0, end: 40),
            span(1, [8, 8], scale: 2, start: 20, end: 55),
        ], filedAt: now)
        let got = try #require(try await store.spanVectors(itemIDs: ["item-b"], modelID: model)["item-b"])
        #expect(got.count == 2, "stale span 2 must not survive the replace")
        #expect(got.map(\.int8) == [[9, 9], [8, 8]])
        #expect(got.map(\.endWord) == [40, 55])
        // Malformed input is rejected before any row changes.
        await #expect(throws: SynapseKitError.self) {
            try await store.writeSpanVectors(itemID: "item-b", modelID: model, modelVersion: "r1", spans: [
                span(0, [1, 2], scale: 1, start: 0, end: 60),
                span(1, [1, 2, 3], scale: 1, start: 30, end: 90),
            ], filedAt: now)
        }
        let after = try #require(try await store.spanVectors(itemIDs: ["item-b"], modelID: model)["item-b"])
        #expect(after.count == 2, "a rejected write leaves the prior span set in place")
        try await store.deleteSpanVectors(itemID: "item-b", modelID: model)
        #expect(try await store.spanVectors(itemIDs: ["item-b"], modelID: model).isEmpty)
    }

    @Test("reclaim removes retired-model rows and non-serving generations, keeps serving rows")
    func reclaim() async throws {
        await GlobalTestLock.shared.acquire()
        defer { Task { await GlobalTestLock.shared.release() } }
        let store = try await makeStore()
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        // Live model: two serving rows (generation 0).
        try await store.addPayload(itemID: "i1", vectorIndex: 0, payload: VectorPayload(floats: [1, 0]),
                                   modelID: "live-v1", modelVersion: "1", filedAt: now)
        try await store.addPayload(itemID: "i2", vectorIndex: 0, payload: VectorPayload(floats: [0, 1]),
                                   modelID: "live-v1", modelVersion: "1", filedAt: now)
        // Retired family rows.
        try await store.addPayload(itemID: "i1", vectorIndex: 0, payload: VectorPayload(floats: [1, 0]),
                                   modelID: "lsa-v1", modelVersion: "1", filedAt: now)
        try await store.addPayload(itemID: "i2", vectorIndex: 0, payload: VectorPayload(floats: [0, 1]),
                                   modelID: "fdc-v1", modelVersion: "1", filedAt: now)
        // A non-serving generation row for the live model, written raw
        // (generation 7 while the model serves generation 0).
        _ = try await store.storage.rowStore.insert(table: "vectors", values: [
            "id": .uuid(UUID()), "item_id": .text("i3"), "vector_index": .int(0),
            "model_id": .text("live-v1"), "model_version": .text("1"),
            "kind": .int(1), "dim": .int(2),
            "payload": .blob(Data(VectorPayload(floats: [1, 1]).bytes)),
            "scale": .null, "filed_at": .timestamp(now), "generation": .int(7),
        ])
        let counts = try await store.reclaimRetiredVectorRows(retiredModelIDs: ["lsa-v1", "nmf-v1", "ppmi-v1", "fdc-v1"])
        #expect(counts.retiredModelRows == 2)
        #expect(counts.nonServingRows == 1)
        let remaining = try await store.storage.rowStore.query(
            table: "vectors", where: .isTrue, orderBy: [], limit: nil, offset: nil, columns: ["model_id", "generation"])
        #expect(remaining.count == 2)
        #expect(remaining.allSatisfy { $0["model_id"] == .text("live-v1") && $0["generation"] == .int(0) })
    }
}
