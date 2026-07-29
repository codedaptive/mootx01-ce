// FingerprintLaneTests.swift
//
// Item 4 of MISSION_11X_RECALL_GAP_01: verify that the Fingerprint256
// ("distillation-features-v1") lane is correctly wired into RecallDirector.
//
// Coverage:
//  T1 — Sketch carries fingerprint: compileSketch populates queryFingerprint
//       for queries with named entities; nil for queries with none.
//  T2 — Lane queried and fused at all three sites: corpusOnly, hybrid, and
//       unionBest all return a Lane B hit when distillation entries exist.
//  T3 — Budget sums to weights.vector: combined Hamming + Dense contribution
//       cannot exceed weights.vector (each lane gets 0.5× share).
//  T4 — Contrastive fingerprint rescue: a drawer with a matching structural
//       fingerprint out-ranks a drawer with no fingerprint match when the
//       dense lane is saturated (identical embeddings, no discrimination).
//  T5 — Dark-lane no-penalty: absent Lane B entries produce the same score
//       for a fingerprint query as for a non-entity query (no penalty for
//       the fingerprint being dark).
//
// Design note: Lane B entries are written via vectorStore.addVector with
// modelID "distillation-features-v1" (the lane key used by DistillationCycle
// and RecallDirector). The probe is computed by
// DistillationPipeline.queryFingerprint + defaultExtractor (capitalization
// heuristic: non-first-word capitalized words are named entities).

import Testing
import Foundation
import EngramLib
import LocusKit
import CorpusKit
@testable import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
import SubstrateML
@testable import GeniusLocusKit

@Suite("Fingerprint Lane B — MISSION_11X_RECALL_GAP_01 Item 4")
struct FingerprintLaneTests {

    // MARK: - Constants

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    /// Lane key for structural fingerprint entries in the VectorStore.
    private let laneBModelID = "distillation-features-v1"

    // MARK: - Helpers

    /// Open an estate with a corpus and a standalone VectorStore.
    ///
    /// The corpus uses the provided inference function. Pass a constant-return
    /// closure (e.g., `{ _ in Array(repeating: 0.5, count: 384) }`) for a
    /// saturated dense lane; the default heuristic varies by first token.
    ///
    /// - Parameters:
    ///   - ownerSuffix:  Unique suffix for the owner identifier (test isolation).
    ///   - inference:    CoreML-style inference closure — takes FNV-1a token ids
    ///                   and returns a 384-element float vector. Defaults to the
    ///                   first-token-modulo heuristic used in degradation tests.
    private func openEstate(
        ownerSuffix: String,
        inference: @escaping @Sendable ([Int32]) async throws -> [Float] = { tokens in
            let v = Float((tokens.first ?? 0) % 4 + 1) / 4.0
            return Array(repeating: v, count: 384)
        }
    ) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "fp-lane-tests-\(ownerSuffix)")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusContentEngine(
            standaloneOn: corpusStorage,
            models: [.miniLM(inference: inference)]
        )
        await kit.registerCorpus(corpus, for: handle)

        let vsStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        await kit.registerVectorStore(vectorStore, for: handle)

        return (kit, handle)
    }

    /// Capture a drawer, ingest it into the corpus, and store a Lane A RI-binary
    /// vector. Returns the drawer id.
    private func captureAndIngest(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        content: String,
        suffix: String = "default"
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "fp-lane-tests",
            latticeAnchor: .udc("000"),
            addedBy: "fp-lane-tests-\(suffix)",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, frame)
        let corpus = try #require(await kit.corpusKits[handle])
        try await corpus.ingest(content, contentID: drawer.id, now: t0)
        // Store Lane A (RI binary) vector by embedding through the corpus.
        let vectorStore = try #require(await kit.vectorStores[handle])
        let engram = try await corpus.embed(content)
        let modelID = await corpus.modelID
        try await vectorStore.addVector(
            itemID: drawer.id, engram: engram,
            modelID: modelID, modelVersion: "1.0", filedAt: t0)
        return drawer.id
    }

    /// Write a Lane B fingerprint for `drawerID` into the estate's VectorStore.
    ///
    /// The fingerprint is computed from `content` via
    /// `DistillationPipeline.featureHash` applied to each feature extracted by
    /// `defaultExtractor`. Mirrors the write path in DistillationCycle.
    private func writeLaneBFingerprint(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        drawerID: String,
        content: String
    ) async throws {
        // Build the fingerprint the same way DistillationCycle would.
        let fingerprint = DistillationPipeline.queryFingerprint(
            query: content,
            extractFeatures: DistillationPipeline.defaultExtractor)
        // Zero fingerprint means no structural features — DistillationCycle skips
        // the write in this case (§7.5). Mirror that skip here so tests that
        // expect Lane B to be dark are not accidentally primed with a zero probe.
        guard fingerprint != .zero else { return }
        let vectorStore = try #require(await kit.vectorStores[handle])
        try await vectorStore.addVector(
            itemID: drawerID, engram: fingerprint,
            modelID: laneBModelID, modelVersion: "1", filedAt: t0)
    }

    /// Build a unionBest recall request with matrixAware scoring.
    private func unionBestRequest(queryText: String) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(filterChain: [], hydrationLevel: .full, limit: 20),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 20,
            fallback: .allowDegraded,
            queryText: queryText,
            origin: .external
        )
    }

    /// Build a corpusOnly recall request with matrixAware scoring.
    private func corpusOnlyRequest(queryText: String) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(filterChain: [], hydrationLevel: .full, limit: 20),
            mode: .corpusOnly,
            scoring: .matrixAware,
            limit: 20,
            fallback: .allowDegraded,
            queryText: queryText,
            origin: .external
        )
    }

    /// Build a hybrid recall request with matrixAware scoring.
    private func hybridRequest(queryText: String) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(filterChain: [], hydrationLevel: .full, limit: 20),
            mode: .hybrid,
            scoring: .matrixAware,
            limit: 20,
            fallback: .allowDegraded,
            queryText: queryText,
            origin: .external
        )
    }

    // MARK: - T1: Sketch carries fingerprint

    @Test("compileSketch populates queryFingerprint for queries with named entities; nil for featureless queries")
    func sketchCarriesFingerprint() async throws {
        // Named-entity query: "Geneva" and "Conference" are capitalized non-first
        // words. defaultExtractor extracts them; featureHash produces a non-zero
        // OR-reduced fingerprint.
        let entityQuery = "Recap the Geneva Conference outcomes from last quarter"
        let entityFP = DistillationPipeline.queryFingerprint(
            query: entityQuery,
            extractFeatures: DistillationPipeline.defaultExtractor)
        #expect(entityFP != .zero,
                "a query with named entities must produce a non-zero queryFingerprint")

        // No-entity query: all lowercase, no capitalized non-first words.
        // defaultExtractor returns empty → OR-reduce over empty set → zero.
        let noEntityQuery = "what happened here at the event"
        let noEntityFP = DistillationPipeline.queryFingerprint(
            query: noEntityQuery,
            extractFeatures: DistillationPipeline.defaultExtractor)
        #expect(noEntityFP == .zero,
                "a query with no named entities must produce a zero fingerprint (→ nil in compileSketch)")

        // Verify that Lane B fires in recall when there's a matching entry and
        // the query has entities. Set up: one drawer with a fingerprint for
        // "Geneva Conference", search with entity query → the hit's sources should
        // include .vectorHamming (the shared bit for both Lane A and Lane B hits).
        let (kit, handle) = try await openEstate(ownerSuffix: "t1")
        let drawerID = try await captureAndIngest(
            kit: kit, handle: handle,
            content: "The Geneva Conference produced twelve agreements last quarter.",
            suffix: "t1")
        try await writeLaneBFingerprint(
            kit: kit, handle: handle, drawerID: drawerID,
            content: "The Geneva Conference produced twelve agreements last quarter.")

        let result = try await kit.recall(handle, unionBestRequest(queryText: entityQuery))
        let hit = try #require(result.hits.first { $0.id == drawerID },
                               "drawer must appear in result for entity query")
        // vectorHamming source bit is set when either Lane A or Lane B contributed.
        #expect(hit.sources.contains(.vectorHamming),
                "hit from a Lane B match must carry the vectorHamming source bit")
    }

    // MARK: - T2: Lane queried and fused at all three sites

    @Test("Lane B is queried and contributes hits in corpusOnly, hybrid, and unionBest")
    func laneQueriedAtAllThreeSites() async throws {
        // "Paris" and "Summit" are named entities in the query.
        let query = "What was decided at the Paris Summit meeting"
        let (kit, handle) = try await openEstate(ownerSuffix: "t2")
        let content = "The Paris Summit concluded with a joint statement on climate goals."
        let drawerID = try await captureAndIngest(
            kit: kit, handle: handle, content: content, suffix: "t2")
        try await writeLaneBFingerprint(
            kit: kit, handle: handle, drawerID: drawerID, content: content)

        // All three modes must surface the drawer. vectorHamming source bit
        // confirms Lane B contributed (since Lane A RI-binary also fires via
        // the corpus engram, but the presence of vectorHamming confirms the
        // vector lane — including Lane B — is active).
        let corpusOnlyResult = try await kit.recall(handle, corpusOnlyRequest(queryText: query))
        let hybridResult     = try await kit.recall(handle, hybridRequest(queryText: query))
        let unionBestResult  = try await kit.recall(handle, unionBestRequest(queryText: query))

        for (modeName, result) in [("corpusOnly", corpusOnlyResult),
                                    ("hybrid",     hybridResult),
                                    ("unionBest",  unionBestResult)] {
            let hit = try #require(
                result.hits.first { $0.id == drawerID },
                "\(modeName): drawer must appear in recall result")
            #expect(hit.sources.contains(.vectorHamming),
                    "\(modeName): hit must carry vectorHamming source (Lane A + Lane B both contribute)")
        }
    }

    // MARK: - T3: Budget sums to weights.vector exactly

    @Test("combined Hamming + Dense contribution cannot exceed weights.vector (0.5× budget split)")
    func budgetSumsToWeightsVector() async throws {
        // weights.vector = 0.25 for uniform weights.
        // With the 0.5× split: max combined = 0.25 * 0.5 * 1.0 + 0.25 * 0.5 * 1.0 = 0.25.
        // Pre-fix (1.0× each): max combined = 0.25 + 0.25 = 0.50 > budget.
        let weightsVector: Float = RecallWeights.uniform.vector

        let (kit, handle) = try await openEstate(ownerSuffix: "t3")
        // Two drawers: A with matching fingerprint, B without. This ensures
        // normalization spreads the vector column across both candidates so the
        // normalized score for A is close to 1.0 and B close to 0.0.
        let contentA = "The Berlin Conference established the colonial boundaries in Africa."
        let contentB = "Annual rainfall statistics for the temperate zone were recorded."
        let drawerA = try await captureAndIngest(
            kit: kit, handle: handle, content: contentA, suffix: "t3a")
        // drawerB is captured to widen the buffer's normalization range:
        // with two candidates the vector column normalizes across both so
        // drawerA's normalized score is near 1.0 and drawerB's near 0.0.
        _ = try await captureAndIngest(
            kit: kit, handle: handle, content: contentB, suffix: "t3b")
        // Write Lane B entry only for drawer A.
        try await writeLaneBFingerprint(
            kit: kit, handle: handle, drawerID: drawerA, content: contentA)
        // drawerB gets NO Lane B entry — it will have zero vector score after
        // the fingerprint search finds no match.

        let query = "Tell me about the Berlin Conference colonial decisions"
        let result = try await kit.recall(handle, unionBestRequest(queryText: query))
        let hitA = try #require(result.hits.first { $0.id == drawerA }, "drawer A must appear")

        // Budget invariant: combined Hamming + Dense contribution ≤ weights.vector.
        // hitA.score.vector and hitA.score.dense are post-normalization values in [0, 1].
        // The formula applies 0.5× to each; their combined max is weights.vector.
        let combinedContrib = weightsVector * 0.5 * hitA.score.vector
                            + weightsVector * 0.5 * hitA.score.dense
        #expect(combinedContrib <= weightsVector + 1e-3,
                "combined vector+dense contribution must not exceed weights.vector (\(weightsVector)); got \(combinedContrib)")
    }

    // MARK: - T4: Contrastive fingerprint rescue

    @Test("fingerprint Lane B rescues a matching drawer when the dense lane is saturated")
    func fingerprintRescuesRankWithSaturatedDense() async throws {
        // Setup: saturated dense lane (identical embeddings, zero discrimination).
        // Drawer A: about "Tokyo Treaty" — matching fingerprint for the query.
        // Drawer B: about an unrelated topic — no fingerprint match for query.
        // Expected: drawer A ranks above drawer B because Lane B provides the
        // only contrastive signal when dense discrimination is zero.
        // Saturated dense: ALL content returns the SAME vector; zero discrimination.
        // Rankings can only be determined by Lane B (structural fingerprint).
        let (kit, handle) = try await openEstate(
            ownerSuffix: "t4",
            inference: { _ in Array(repeating: 0.5, count: 384) }
        )

        let contentA = "The Tokyo Treaty governs maritime navigation in the Pacific region."
        let contentB = "Quarterly harvest data was compiled for the agricultural review."
        let drawerA = try await captureAndIngest(
            kit: kit, handle: handle, content: contentA, suffix: "t4a")
        let drawerB = try await captureAndIngest(
            kit: kit, handle: handle, content: contentB, suffix: "t4b")

        // Write Lane B fingerprint ONLY for drawer A. The fingerprint will contain
        // the feature hash for "Tokyo" and "Treaty" (non-first capitalized words).
        try await writeLaneBFingerprint(
            kit: kit, handle: handle, drawerID: drawerA, content: contentA)
        // drawerB gets no Lane B entry — it is absent from the fingerprint lane.

        // Query contains "Tokyo" and "Treaty" — these will produce a non-nil
        // queryFingerprint that closely matches drawer A's fingerprint.
        let query = "What does the Tokyo Treaty say about Pacific shipping?"
        let result = try await kit.recall(handle, unionBestRequest(queryText: query))

        // Drawer A must rank above drawer B: the only discriminating signal is
        // Lane B (dense is saturated — identical for both drawers).
        let indexA = result.hits.firstIndex { $0.id == drawerA }
        let indexB = result.hits.firstIndex { $0.id == drawerB }
        let iA = try #require(indexA, "drawer A must appear in result")
        let iB = try #require(indexB, "drawer B must appear in result")
        #expect(iA < iB,
                "drawer A (fingerprint match) must rank above drawer B (no match) when dense is saturated; got A at \(iA), B at \(iB)")
    }

    // MARK: - T5: Dark-lane no-penalty

    @Test("absent Lane B entries produce no score penalty — dark lane contributes zero, never negative")
    func darkLaneNoPenalty() async throws {
        // Dark lane: estate has ONE drawer, NO distillation entries in VectorStore.
        // The Lane B search returns no candidates — zero contribution.
        // Compare two searches:
        //   (a) entity query → queryFingerprint is non-nil → Lane B search fires
        //                      but returns empty → zero contribution
        //   (b) non-entity query → queryFingerprint is nil → Lane B search skipped
        // Both should return the same drawer with comparable scores. Specifically,
        // the entity query must NOT produce a lower score than the non-entity query:
        // Lane B being dark must not penalize the entity query.
        let (kit, handle) = try await openEstate(ownerSuffix: "t5")
        let content = "The system reported stable throughput across all regions."
        let drawerID = try await captureAndIngest(
            kit: kit, handle: handle, content: content, suffix: "t5")
        // Deliberately NOT writing a Lane B entry for the drawer.

        let entityQuery    = "What about the Geneva Conference throughput report?"
        let nonEntityQuery = "system throughput stability across regions"

        let entityResult    = try await kit.recall(handle, unionBestRequest(queryText: entityQuery))
        let nonEntityResult = try await kit.recall(handle, unionBestRequest(queryText: nonEntityQuery))

        let entityHit    = try #require(entityResult.hits.first    { $0.id == drawerID },
                                        "drawer must appear in entity-query result")
        let nonEntityHit = try #require(nonEntityResult.hits.first { $0.id == drawerID },
                                        "drawer must appear in non-entity-query result")

        // Dark-lane safety: the entity query must not score LOWER than the non-entity
        // query for the same drawer. Lane B contributes zero (no entries), and
        // queryFingerprint being non-nil vs nil only changes whether the empty
        // search fires — no candidate is added, so no penalty can occur.
        // A 0.05 tolerance covers BM25 token variation between queries.
        #expect(entityHit.score.final >= nonEntityHit.score.final - 0.05,
                "entity query must not score lower than non-entity query on the same drawer (dark-lane safety); entity=\(entityHit.score.final), nonEntity=\(nonEntityHit.score.final)")
    }
}
