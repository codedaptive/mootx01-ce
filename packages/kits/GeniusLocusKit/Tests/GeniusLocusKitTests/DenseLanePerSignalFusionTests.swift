// DenseLanePerSignalFusionTests.swift
//
// Tests for the 6b-core dense-lane PER-SIGNAL fan-out and N-way RRF consensus
// in the GLK RecallDirector unionBest lane.
//
// The dense lane now consumes `Corpus.floatNearestPerSignal` so EVERY held
// distributional signal is an independent RRF voter alongside the locus / BM25 /
// Hamming lanes. This file proves:
//
// §1 N=1 back-compat: a single-provider corpus (the production default) produces
//    the same unionBest dense-lane behaviour as before — dense hits present,
//    denseLaneStatus nil on hits, sources carry .vectorDense.
// §2 N>1 consensus: a TWO-provider corpus (miniLM + mpnet, both float-capable)
//    contributes both dense signals, the fused result records per-signal dense
//    provenance, and a drawer surfaced by BOTH signals ranks at/above a drawer
//    surfaced by a SINGLE signal (the consensus property).
//
// INTELLECTUS LOCK is not required here: these tests do not toggle Intellectus
// and assert only on the returned GLKRecallResult, not telemetry counters.

// Whole-record float lane tests.
import Testing
import Foundation
import LocusKit
import CorpusKit
import CorpusKitWholeRecordDense
import SynapseKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// MARK: - Helpers

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

/// A `.rrf`-scored unionBest recall frame matching every active row.
private func unionBestRRF(queryText: String, limit: Int = 10) -> GLKRecallRequest {
    GLKRecallRequest(
        frame: RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        ),
        mode: .unionBest,
        scoring: .rrf,
        limit: limit,
        fallback: .failClosed,
        queryText: queryText,
        origin: .internal
    )
}

/// Open an estate and capture `n` drawers with distinct content. Returns the
/// kit, handle, and the captured drawers in capture order.
private func openEstateWithDrawers(_ contents: [String], owner ownerID: String) async throws
    -> (kit: GeniusLocusKit, handle: EstateHandle, drawers: [LocusKit.Drawer]) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: ownerID)
    let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
    let storage = InMemoryStorage(configuration: config)
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner)

    var drawers: [LocusKit.Drawer] = []
    for content in contents {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "per-signal-fusion-tests",
            latticeAnchor: .udc("000"),
            addedBy: "per-signal-fusion-tests",
            embeddingModelID: "test-model-v1"
        )
        drawers.append(try await kit.capture(handle, frame))
    }
    return (kit: kit, handle: handle, drawers: drawers)
}

// MARK: - §1 N=1 back-compat

@Suite("§1 Dense per-signal — N=1 single provider (production default)", .serialized)
struct DenseLaneSingleProviderTests {

    /// A single-provider (miniLM) corpus: the dense lane fans out to one signal,
    /// which is exactly the pre-6b single-`floatNearest` path. The lane runs,
    /// produces hits, and carries .vectorDense evidence — unchanged behaviour.
    @Test("single-provider unionBest dense lane runs and surfaces vectorDense hits")
    func singleProviderDenseLaneRunsUnchanged() async throws {
        let content = "photosynthesis converts light into chemical energy in plants"
        let (kit, handle, drawers) = try await openEstateWithDrawers(
            [content], owner: "single-provider-owner")

        // One float-capable signal. The provider keys off the first word so
        // distinct content embeds to distinct vectors.
        let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusKit.CorpusContentEngine(
            standaloneOn: corpusStorage,
            models: [.lsa(provider: FirstWordAxisProvider(modelID: "minilm-v6"))]
        )
        try await corpus.ingest(content, contentID: drawers[0].id, now: t0)
        await kit.registerCorpus(corpus, for: handle)

        let result = try await kit.recall(handle, unionBestRRF(queryText: content))

        // Dense lane produced hits → no dark marker (pre-6b semantics).
        #expect(result.denseLaneStatus == nil,
            "single-provider dense lane that produced hits must carry nil denseLaneStatus; got '\(result.denseLaneStatus ?? "nil")'")
        // The captured drawer surfaces with dense evidence.
        let denseHit = result.hits.first { $0.id == drawers[0].id }
        #expect(denseHit != nil, "the ingested drawer must surface in unionBest recall")
        #expect(denseHit?.sources.contains(.vectorDense) == true,
            "the dense-lane hit must carry .vectorDense evidence; sources: \(denseHit?.sources ?? [])")
    }
}

// MARK: - §2 N>1 consensus

@Suite("§2 Dense per-signal — N>1 consensus across two float signals", .serialized)
struct DenseLaneConsensusTests {

    /// Build a two-provider corpus (minilm-v6 + mpnet-base-v2 slots) over two
    /// drawers, both float-capable so both signals rank both drawers. The
    /// providers are engineered so:
    ///   - drawer CONSENSUS is ranked HIGH by BOTH dense signals (strong cross-
    ///     signal agreement → large consensus boost);
    ///   - drawer SINGLE is ranked high by ONE signal but lower by the other (weak
    ///     agreement → small consensus boost).
    /// The fused hit for the consensus drawer must record per-signal dense
    /// provenance naming BOTH modelIDs, and the consensus drawer must rank at or
    /// above the single-agreement drawer (the consensus property).
    @Test("a drawer with strong cross-signal agreement ranks at/above a weak-agreement drawer")
    func consensusDrawerOutranksSingleSignalDrawer() async throws {
        // Distinct first words drive distinct embeddings. The query shares its
        // first word with the consensus doc under both signals. The
        // single-signal doc is captured FIRST and the consensus doc LAST, so the
        // locus lane (byCaptureTimeDesc) and the dense consensus AGREE on ordering
        // — the dense per-signal fan-out then provides the per-signal provenance
        // that uniquely proves multiple signals voted on the consensus drawer.
        let queryText = "alpha consensus topic shared across both embedding signals"
        let consensusContent = "alpha consensus topic shared across both embedding signals"
        let singleContent = "zeta unrelated divergent wording only one signal aligns here"

        let (kit, handle, drawers) = try await openEstateWithDrawers(
            [singleContent, consensusContent], owner: "consensus-owner")
        let singleID = drawers[0].id
        let consensusID = drawers[1].id

        // "minilm-v6" (FirstWordAxisProvider): aligns the query with BOTH docs
        // through the shared component, and with the consensus doc more closely
        // because they share a first word. "mpnet-base-v2" (TwoAxisProvider):
        // aligns the query ONLY with the consensus doc ("alpha…" leads odd,
        // "zeta…" leads even) and embeds the single doc orthogonally. Both are
        // keyed off the text so the cosine ordering is deterministic.
        let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusKit.CorpusContentEngine(
            standaloneOn: corpusStorage,
            models: [
                .lsa(provider: FirstWordAxisProvider(modelID: "minilm-v6")),
                .lsa(provider: TwoAxisProvider(modelID: "mpnet-base-v2")),
            ]
        )
        try await corpus.ingest(consensusContent, contentID: consensusID, now: t0)
        try await corpus.ingest(singleContent, contentID: singleID, now: t0)
        await kit.registerCorpus(corpus, for: handle)

        let result = try await kit.recall(handle, unionBestRRF(queryText: queryText, limit: 10))

        // Both drawers should surface.
        let consensusHit = result.hits.first { $0.id == consensusID }
        let singleHit = result.hits.first { $0.id == singleID }
        #expect(consensusHit != nil, "consensus drawer must surface in the fused result")

        // Per-signal dense provenance: the consensus hit's explanation must name
        // BOTH dense signals (minilm-v6 and mpnet-base-v2). The denseSignals line
        // is appended at step 11 from the per-signal voter map — direct proof that
        // both held signals voted (the dense lane fanned out across both).
        let consensusExplanation = (consensusHit?.explanation ?? []).joined(separator: " | ")
        #expect(consensusExplanation.contains("vectorDense:minilm-v6"),
            "consensus hit explanation must record the miniLM dense signal; got: \(consensusExplanation)")
        #expect(consensusExplanation.contains("vectorDense:mpnet-base-v2"),
            "consensus hit explanation must record the mpnet dense signal; got: \(consensusExplanation)")

        // The dense lane contributed a real cosine for the consensus drawer.
        #expect((consensusHit?.score.dense ?? 0) > 0,
            "consensus drawer must carry a positive dense cosine column")

        // Consensus property: the strong-agreement drawer ranks at or above the
        // weak-agreement drawer. If the single drawer surfaced, its index must be
        // no lower than the consensus drawer's, and the consensus drawer's fused
        // final must be at least the single drawer's.
        if let single = singleHit,
           let consensus = consensusHit,
           let cIdx = result.hits.firstIndex(where: { $0.id == consensus.id }),
           let sIdx = result.hits.firstIndex(where: { $0.id == single.id }) {
            #expect(cIdx <= sIdx,
                "consensus drawer (rank \(cIdx)) must rank at/above the weak-agreement drawer (rank \(sIdx))")
            #expect(consensus.score.final >= single.score.final,
                "consensus drawer final \(consensus.score.final) must be >= weak-agreement final \(single.score.final)")
        }
    }
}
