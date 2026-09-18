// HybridRecallChestDiversityTests.swift
//
// ADR-027 D3: with chest-aware diversity in force, two drawers in one
// container score 1.0 in the MMR similarity, so the rerank reaches for a
// drawer from another container before a container-mate. Off, the shingle
// term alone decides and input order stands. Twin of the Rust
// `hybrid_recall_chest_diversity` tests.

import Testing
import Foundation
import GeniusLocusKit
import SubstrateML
@testable import NeuronKit

@Suite("HybridRecall chest diversity (ADR-027 D3)")
struct HybridRecallChestDiversityTests {

    private func drawer(_ id: String, _ content: String, container: String) -> Drawer {
        Drawer(
            id: id, content: content, parentNodeId: container, sourceFile: nil,
            chunkIndex: nil, addedBy: "test", filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "test-embed-v1", tombstonedAt: nil, removedByBatch: nil,
            provenance: 0, adjectiveBitmap: 0, operationalBitmap: 0, lineageID: UUID(),
            udcCode: "", udcFacets: nil, wikidataQID: nil, wikidataQidsSecondary: nil)
    }

    // Three drawers with no shared trigrams: A and B share a container, C
    // sits alone. Input order is the relevance order (no cue terms).
    private var pool: [Drawer] {
        [drawer("a", "apple banana cherry", container: "CHEST-1"),
         drawer("b", "dog elephant fox", container: "chest-1"),
         drawer("c", "kiwi lemon mango", container: "chest-2")]
    }

    @Test("on: a container-mate is held back behind a drawer from another container")
    func onHoldsBackTheContainerMate() async throws {
        try await withIntellectusLock {
            let tuning = RecallFrameTuning(mmrLambda: 0.5, chestDiversity: true)
            let out = HybridRecallEngine.rerank(drawers: pool, tuning: tuning)
            #expect(out.map(\.id) == ["a", "c", "b"], "container ids compare case-insensitively")
        }
    }

    @Test("off: the shingle term alone decides and input order stands")
    func offKeepsInputOrder() async throws {
        try await withIntellectusLock {
            let tuning = RecallFrameTuning(mmrLambda: 0.5, chestDiversity: false)
            let out = HybridRecallEngine.rerank(drawers: pool, tuning: tuning)
            #expect(out.map(\.id) == ["a", "b", "c"])
        }
    }
}
