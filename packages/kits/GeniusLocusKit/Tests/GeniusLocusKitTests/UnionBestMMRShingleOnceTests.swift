// UnionBestMMRShingleOnceTests.swift
//
// Pins the unionBest MMR selection order for a full-hydration recall over a
// pool whose top three candidates by relevance are near-duplicates.
//
// Step 10 of `RecallDirector.recallUnionBest` compares each selected
// candidate against every remaining candidate. The similarity term is the
// SubstrateML character-3-gram shingle Jaccard over the bodies hydrated at
// step 9.5; each body is shingled ONCE and the sets are reused across both
// MMR phases. The expected orders below were captured from the build that
// shingled both bodies on every pairwise call. The set overload computes the
// same |∩|/|∪| as the string overload, so the selection must not move.
//
// Tests:
//   1. fullHydrationNearDuplicateOrderIsPinned — the matrixAware order
//      matches the pinned pre-change order and is stable across two recalls.
//   2. setOverloadMatchesStringOverloadOnFixtureBodies — for every fixture
//      body pair, the set overload used by step 10 equals the string overload
//      the loop called before.

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateML
import SynapseKit
@testable import GeniusLocusKit

@Suite("UnionBest MMR shingles each candidate once", .serialized)
struct UnionBestMMRShingleOnceTests {

    /// Three near-duplicate bodies at the top of the relevance order (bodies
    /// 0 to 2: the query itself plus one trailing word, one shared 3-gram
    /// cluster) and six diverse bodies that carry the query terms in longer,
    /// different phrasing. The pool (9) is larger than the 2N working view
    /// (4 at `limit: 2`), so step 10 decides which candidates enter the view.
    /// With shingle similarity the second and third near-duplicates are
    /// penalised out of the view and a diverse body takes the second slot.
    /// With the sourceMask proxy alone (every body is supplied by the same
    /// lanes, so every pair scores 1.0) the view is the top-4 by relevance
    /// and two near-duplicates are returned. Observed: the proxy-only
    /// mutation returns [body 0, body 2]; the shingle term returns the pinned
    /// order below. The pin therefore discriminates the shingle term itself.
    static let bodies: [String] = [
        "quarterly budget review meeting notes finance team",
        "quarterly budget review meeting notes finance team ok",
        "quarterly budget review meeting notes finance team yes",
        "finance team quarterly review: budget meeting notes and action items about vendor contracts",
        "meeting notes, finance team: quarterly budget review of travel policy and expense caps",
        "notes from the finance team budget review meeting each quarterly cycle for headcount plans",
        "quarterly finance team notes: budget review meeting covering software licences",
        "budget review meeting notes with the finance team about the quarterly forecast model",
        "team meeting notes quarterly budget review by finance on the new office lease",
    ]

    static let query = "quarterly budget review meeting notes finance team"

    /// Pinned order (by body text) captured from the pre-change build for
    /// `limit: 2` at `hydrationLevel: .full`, `.matrixAware` scoring. Only
    /// matrixAware is pinned: under `.rrf` every candidate ties at the
    /// presentation cut, the 4N widening exhausts the pool, and the whole tie
    /// group is returned, so the MMR term cannot move membership there.
    static let pinnedOrder: [GLKRecallScoring: [String]] = [
        .matrixAware: [
            "quarterly budget review meeting notes finance team",
            "team meeting notes quarterly budget review by finance on the new office lease",
        ],
    ]

    /// Open an in-memory estate with every fixture body captured, ingested
    /// into a shared corpus, and registered in a shared vector store keyed by
    /// drawer id, so the locus, BM25, and Hamming lanes all supply candidates.
    private func openFixtureEstate() async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-mmr-shingle-once")
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

        for body in Self.bodies {
            let frame = CaptureFrame(
                content: body,
                channel: .typed,
                room: "mmr-shingle-once",
                latticeAnchor: .udc("000"),
                addedBy: "mmr-shingle-once",
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

    private func request(scoring: GLKRecallScoring) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed],
                hydrationLevel: .full,
                ordering: .byCaptureTimeDesc),
            mode: .unionBest,
            scoring: scoring,
            limit: 2,
            fallback: .failClosed,
            queryText: Self.query,
            origin: .internal
        )
    }

    // MARK: - 1. Pinned order

    @Test("full-hydration unionBest order over near-duplicates matches the pinned pre-change order")
    func fullHydrationNearDuplicateOrderIsPinned() async throws {
        // open/capture/recall cross telemetry emit sites; hold the process-wide
        // Intellectus mutex (see IntellectusTestLock.swift).
        try await withIntellectusLock {
            for (scoring, expected) in Self.pinnedOrder.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let (kit, handle) = try await openFixtureEstate()
                let first = try await kit.recall(handle, request(scoring: scoring))
                let second = try await kit.recall(handle, request(scoring: scoring))
                let observed = first.hits.map { $0.drawer?.content ?? "" }
                #expect(!first.degradedStages.contains("pool.hydrateBodies.mmr"),
                        "\(scoring) step 9.5 hydration must succeed so step 10 runs on shingle sets")
                #expect(observed.allSatisfy { !$0.isEmpty },
                        "\(scoring) .full recall must return bodies; got \(observed)")
                #expect(observed == expected,
                        "\(scoring) order moved. observed: \(observed)")
                #expect(first.hits.map(\.id) == second.hits.map(\.id),
                        "\(scoring) order must be stable across two identical recalls")
                // No `kit.close(handle)`: the same convention as the other
                // corpus-plus-vector-store recall tests in this target. Closing
                // this kit while the drain-stage suites run in parallel stalled
                // their encode drains (`drainTimeout(pending: 0, inFlight: 1)`
                // in three tests, reproduced three times with the close and
                // absent without this file); the in-memory estate is released
                // with the kit.
            }
        }
    }

    // MARK: - 2. Set overload equals string overload

    @Test("the set overload step 10 uses equals the string overload over every fixture body pair")
    func setOverloadMatchesStringOverloadOnFixtureBodies() {
        let sets = Self.bodies.map { ShingleSimilarity.shingles($0) }
        for i in Self.bodies.indices {
            for j in Self.bodies.indices {
                let viaStrings = ShingleSimilarity.similarity(Self.bodies[i], Self.bodies[j])
                let viaSets = ShingleSimilarity.similarity(sets[i], sets[j])
                #expect(viaStrings == viaSets,
                        "pair (\(i), \(j)): string overload \(viaStrings) != set overload \(viaSets)")
            }
        }
        // The near-duplicate cluster must be far more similar than any
        // cross-cluster pair, or the fixture could not move the MMR order.
        let inCluster = ShingleSimilarity.similarity(sets[0], sets[1])
        let crossCluster = (3..<Self.bodies.count).map { ShingleSimilarity.similarity(sets[0], sets[$0]) }.max() ?? 1
        #expect(inCluster > 0.8 && crossCluster < 0.6,
                "fixture cluster contrast lost: in \(inCluster) cross \(crossCluster)")
    }
}
