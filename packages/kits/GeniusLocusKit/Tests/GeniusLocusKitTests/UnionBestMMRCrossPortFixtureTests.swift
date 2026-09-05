// UnionBestMMRCrossPortFixtureTests.swift
//
// Cross-port golden pin for the unionBest step 10 MMR stage (MMR-2).
//
// Reads ONE shared fixture at Tests/Conformance/union_best_mmr_fixture.json
// (Rust twin: rust/tests/union_best_mmr_parity.rs, test
// `cross_port_fixture_content_order_matches`). The fixture holds four
// near-duplicate bodies and eight diverse bodies; at limit 3 the pool (12)
// exceeds the 2N working view (6), so the greedy MMR with the shingle term
// decides which candidates enter the view. Both ports must return the
// fixture's `expected_content_order` verbatim for a `.full` unionBest
// `.matrixAware` recall.

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import SynapseKit
@testable import GeniusLocusKit

@Suite("UnionBest MMR cross-port fixture", .serialized)
struct UnionBestMMRCrossPortFixtureTests {

    private struct Fixture: Decodable {
        let query: String
        let limit: Int
        let bodies: [String]
        let expected_content_order: [String]
    }

    /// Resolves Tests/Conformance/union_best_mmr_fixture.json relative to
    /// this file (Tests/GeniusLocusKitTests/), the same layout the
    /// ScoreOrderingTests fixture uses.
    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("union_best_mmr_fixture.json")
    }

    /// Open an in-memory estate with every fixture body captured, ingested
    /// into a shared corpus, and registered in a shared vector store keyed by
    /// drawer id, so the locus, BM25, and Hamming lanes all supply candidates
    /// (the same wiring as UnionBestMMRShingleOnceTests).
    private func openFixtureEstate(bodies: [String]) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-mmr-cross-port")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusContentEngine(standaloneOn: corpusStorage)
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let modelID = await corpus.modelID
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        for body in bodies {
            let frame = CaptureFrame(
                content: body,
                channel: .typed,
                room: "mmr-cross-port",
                latticeAnchor: .udc("000"),
                addedBy: "mmr-cross-port",
                embeddingModelID: "test-model-v1"
            )
            let drawer = try await kit.capture(handle, frame)
            try await corpus.ingest(body, contentID: drawer.id, now: now)
            let engram = try await corpus.embed(body)
            try await vectorStore.addVector(
                itemID: drawer.id,
                engram: engram,
                modelID: modelID,
                modelVersion: "1.0",
                filedAt: now
            )
        }
        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle)
    }

    @Test("full-hydration unionBest matrixAware order matches the shared cross-port fixture")
    func crossPortFixtureContentOrderMatches() async throws {
        let data = try Data(contentsOf: fixtureURL())
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        try await withIntellectusLock {
            let (kit, handle) = try await openFixtureEstate(bodies: fixture.bodies)
            let request = GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.unconfirmed],
                    hydrationLevel: .full,
                    ordering: .byCaptureTimeDesc),
                mode: .unionBest,
                scoring: .matrixAware,
                limit: fixture.limit,
                fallback: .failClosed,
                queryText: fixture.query,
                origin: .internal
            )
            let result = try await kit.recall(handle, request)
            let observed = result.hits.map { $0.drawer?.content ?? "" }
            #expect(!result.degradedStages.contains("pool.hydrateBodies.mmr"),
                    "step 9.5 hydration must succeed so step 10 runs on shingle sets")
            #expect(observed == fixture.expected_content_order,
                    "cross-port fixture order moved. observed: \(observed)")
            // No `kit.close(handle)` — same convention as the other
            // corpus-plus-vector-store recall tests in this target (closing
            // stalls the parallel drain-stage suites; see
            // UnionBestMMRShingleOnceTests).
        }
    }
}
