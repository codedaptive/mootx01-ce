// ShadowSwapAdapterTests.swift
//
// n5 relocated here from NeuronKitTests by MD-01's B-1 fix.
//
// The test drives reclamation through the PRODUCTION ADAPTER, which is the
// point: the seam deliberately provides no default implementation, so an
// unwired conformer is a compile error rather than a silent no-op (reviewer
// ruling F-2, VEC-SHADOWSWAP-01 BRR). That coverage has to follow the adapter.
//
// EstateHNSWGraphMaintenance now lives in AriaResident because it holds a live
// VectorStore handle and NeuronKit may not (B-1). NeuronKit's test target
// cannot see it, since AriaResident depends on NeuronKit and not the reverse,
// so the test moved rather than being weakened to call VectorStore directly.

import Testing
import Foundation
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
import SynapseKit
import NeuronKit
@testable import AriaResident

@Suite("Shadow swap: reclamation through the production adapter")
struct ShadowSwapAdapterTests {
private func rowCount(_ storage: InMemoryStorage, table: String) async throws -> Int {
    try await storage.rowStore.count(table: table, where: .isTrue)
}

@Test("n5 production-adapter: reclaimSupersededGenerations deletes superseded rows from real VectorStore")
    func n5_productionAdapterDeletesSupersededRows() async throws {
        // ── Storage and VectorStore setup ─────────────────────────────────
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        try await storage.migrate(to: VectorStore.schemaDeclaration)
        let store = VectorStore(storage: storage)

        let modelID = "reclaim-test-model"
        let now = Date(timeIntervalSinceReferenceDate: 21_000_000)

        // ── Phase 1: write 3 serving-generation (gen 0) vectors ──────────
        for i in 0..<3 {
            try await store.addPayload(
                itemID: "item-\(i)",
                vectorIndex: 0,
                payload: VectorPayload(kind: .binary, dim: 256, bytes: [UInt8](repeating: 0, count: 32)),
                modelID: modelID,
                modelVersion: "1",
                filedAt: now
            )
        }

        let rowsAfterInitial = try await rowCount(storage, table: "vectors")
        #expect(rowsAfterInitial == 3, "n5: 3 serving rows written (gen 0)")

        // ── Phase 2: open shadow generation ──────────────────────────────
        let gens = try await store.beginShadowGeneration(modelIDs: [modelID])
        let shadowGen = try #require(gens[modelID])
        #expect(shadowGen == 1, "n5: first shadow generation must be 1")

        // ── Phase 3: write 3 shadow-generation (gen 1) vectors ───────────
        for i in 3..<6 {
            try await store.addPayload(
                itemID: "item-\(i)",
                vectorIndex: 0,
                payload: VectorPayload(kind: .binary, dim: 256, bytes: [UInt8](repeating: 1, count: 32)),
                modelID: modelID,
                modelVersion: "1",
                filedAt: now
            )
        }

        let rowsAfterShadow = try await rowCount(storage, table: "vectors")
        #expect(rowsAfterShadow == 6,
            "n5: 6 total rows — 3 serving (gen 0) + 3 shadow (gen 1)")

        // ── Phase 4: publish — flip serving to gen 1, gen 0 → pending-reclaim
        try await store.publishShadowGeneration(modelIDs: [modelID])

        let rowsAfterPublish = try await rowCount(storage, table: "vectors")
        #expect(rowsAfterPublish == 6,
            "n5: rows unchanged immediately after publish (old gen rows still on disk)")

        // ── Phase 5: reclaim via EstateHNSWGraphMaintenance ──────────────
        let maintenance = EstateHNSWGraphMaintenance(vectorStore: store)
        try await maintenance.reclaimSupersededGenerations(now: now)

        let rowsAfterReclaim = try await rowCount(storage, table: "vectors")
        #expect(rowsAfterReclaim == 3,
            "n5: gen-0 rows deleted by reclaim; only 3 gen-1 serving rows remain")
    }}
