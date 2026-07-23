// DeltaReindexTests.swift
//
// Covers the DELTA-AWARE reindex tail in `reindexMissing` — the fix for the
// O(estate) vault-import cost (a ~1k-note vault import into a 50k estate
// burned ~70 min of full basis retrain + full re-embed, and an UNCHANGED
// reimport burned the same for a no-op):
//
//   • NO-OP sweep (nothing missing) → returns 0, enqueues nothing, and skips
//     the reindex tail entirely.
//   • SMALL delta (< deltaReindexThresholdPercent of the indexed corpus) →
//     rides the ENCODE stream, whose drain embeds through the LIVE basis
//     (live-capture machinery); no full retrain.
//   • LARGE delta (cold load, or ≥ threshold) → rides the IMPORT stream
//     (chunk + BM25 only) and pays the full train-once+embed-once tail.
//
// Observability is deliberately behavior-level: WHICH queue stream completed
// the sweep's jobs (the routing IS the decision), plus searchability of the
// delta content (proves the encode-stream path embedded it). These tests
// assert correctness, not wall-clock latency, so they are NOT gated behind
// GLK_LATENCY_TESTS (unlike EncodeIntakeTests / EncodeDrainNearRealtimeTests).
//
// Rust twins: is_small_reindex_delta unit tests in GLK rust intake.rs and the
// stream-routing assertions in encode_intake_parity.rs.

import Testing
import Foundation
import LocusKit
@testable import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
import SubstrateTypes
import QueueKit
@testable import GeniusLocusKit

@Suite("Delta-aware reindex tail — vault-import O(estate) fix")
struct DeltaReindexTests {

    // MARK: - Helpers

    /// Provision a GLK estate (mounts Corpus + VectorStore + both drain
    /// workers). Same fixture as EncodeIntakeTests.
    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-delta-reindex-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Delta Reindex Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle)
    }

    private func captureFrame(_ content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "delta-reindex-tests",
            latticeAnchor: .udc("000"),
            addedBy: "delta-reindex-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    /// Completed-job counts per stream on the corpus's shared ingest queue.
    private func completedCounts(
        _ kit: GeniusLocusKit, _ handle: EstateHandle
    ) async throws -> (encode: Int, imported: Int) {
        let corpus = try #require(await kit.corpusKits[handle])
        guard let queue = await corpus.ingestQueue else { return (0, 0) }
        // Shared-content 1.1: the copied-text import stream no longer exists —
        // every change reference rides the one encode stream. `imported` is
        // retained in the tuple shape for the assertions below and is always
        // the legacy stream's count (0 on a cutover estate).
        let encode = try await queue.completed(streamID: CorpusContentEngine.encodeStreamID).count
        let imported = try await queue.completed(streamID: Corpus.importStreamID).count
        return (encode, imported)
    }

    /// Bulk-capture `count` drawers (row-only — captureBatch skips the encode
    /// hook, exactly like a vault/palace import) with contents carrying `tag`.
    private func bulkCapture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, count: Int, tag: String
    ) async throws {
        let frames = (0..<count).map {
            captureFrame("\(tag) drawer number \($0) fills the corpus with prose")
        }
        _ = try await kit.captureBatch(handle, frames)
    }

    // MARK: - No-op sweep skips the tail

    @Test
    func noopSweepReturnsZeroAndEnqueuesNothing() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        // Baseline sweep first: provisioning seeds estate drawers (charter,
        // hints) that the first sweep indexes; flushing them makes every
        // count below relative to OUR captures only.
        _ = try await kit.reindexMissing(handle: handle, now: Date())

        // Cold-ish load: bulk-capture + sweep reaches full coverage.
        try await bulkCapture(kit, handle, count: 3, tag: "baseline")
        let first = try await kit.reindexMissing(handle: handle, now: Date())
        #expect(first == 3, "sweep indexes every bulk-captured drawer")
        let after = try await completedCounts(kit, handle)

        // No-op reimport: nothing missing → 0, and NOTHING new on either
        // stream (the observed defect was an unchanged vault reimport paying
        // the full O(corpus) tail; the tail is now skipped outright).
        let second = try await kit.reindexMissing(handle: handle, now: Date())
        #expect(second == 0, "nothing missing → sweep reports zero")
        let final = try await completedCounts(kit, handle)
        #expect(final.encode == after.encode, "no-op sweep must not enqueue encode jobs")
        #expect(final.imported == after.imported, "no-op sweep must not enqueue import jobs")
    }

    // MARK: - Small delta rides the encode stream

    @Test
    func smallDeltaRidesEncodeStreamAndIsSearchable() async throws {
        let (kit, handle) = try await provisionGLKEstate()

        // Flush the provisioning-seeded drawers, then build the baseline
        // corpus: 40 drawers, loaded via the import path (40 ≥ 5% of the few
        // already-indexed provisioning drawers → large).
        _ = try await kit.reindexMissing(handle: handle, now: Date())
        try await bulkCapture(kit, handle, count: 40, tag: "baseline")
        _ = try await kit.reindexMissing(handle: handle, now: Date())
        let baseline = try await completedCounts(kit, handle)
        #expect(baseline.encode >= 40,
                "bulk load rides the encode stream (change references; the import stream is gone)")

        // Delta: 1 new drawer = 2.5% of 40 indexed — under the 5% threshold.
        let deltaDrawers = try await kit.captureBatch(
            handle, [captureFrame("zanzibar quixotic delta payload")])
        let deltaID = try #require(deltaDrawers.first?.id)
        let enqueued = try await kit.reindexMissing(handle: handle, now: Date())
        #expect(enqueued == 1)

        let after = try await completedCounts(kit, handle)
        #expect(after.encode == baseline.encode + 1,
                "small delta must ride the ENCODE stream (live-basis embed)")
        #expect(after.imported == 0,
                "the legacy import stream must stay empty on a cutover estate")

        // The delta content is semantically searchable — the encode drain
        // embedded it through the live basis (no full retrain needed).
        let recall = try await kit.recall(
            handle,
            GLKRecallRequest(
                frame: RecallFrame(
                    filterChain: [.unconfirmed],
                    hydrationLevel: .structured,
                    ordering: .byCaptureTimeDesc
                ),
                mode: .hybrid,
                scoring: .raw,
                limit: 50,
                fallback: .failClosed,
                queryText: "zanzibar quixotic"
            ))
        // Assert by drawer ID: .structured hydration deliberately returns
        // drawers WITHOUT content (content readers must request .full — the
        // two-lane hydration contract), so a content-substring assert is
        // always false at this level. And the LANE is the load-bearing part:
        // frame-union membership alone would pass for any active drawer;
        // .corpusBM25 provenance proves the encode-stream ingest actually
        // indexed the delta (the small-delta path's whole promise).
        let hit = recall.hits.first { $0.drawer?.id == deltaID }
        let found = try #require(hit, "delta drawer must be recalled")
        #expect(found.sources.contains(.corpusBM25),
                "delta drawer must surface via .corpusBM25 — the semantic lane lit by the encode-stream ingest; got \(found.sources)")
    }

    // MARK: - Large delta takes the import stream (full tail)

    @Test
    func largeDeltaRidesEncodeStream() async throws {
        let (kit, handle) = try await provisionGLKEstate()

        // Flush provisioning-seeded drawers, then baseline: 40 drawers indexed.
        _ = try await kit.reindexMissing(handle: handle, now: Date())
        try await bulkCapture(kit, handle, count: 40, tag: "baseline")
        _ = try await kit.reindexMissing(handle: handle, now: Date())
        let baseline = try await completedCounts(kit, handle)

        // Delta: 10 new drawers = 25% of 40 — well over the 5% threshold, so
        // the sweep must take the bulk import path (chunk+BM25, full tail).
        try await bulkCapture(kit, handle, count: 10, tag: "expansion")
        let enqueued = try await kit.reindexMissing(handle: handle, now: Date())
        #expect(enqueued == 10)

        let after = try await completedCounts(kit, handle)
        #expect(after.encode == baseline.encode + 10,
                "large delta rides the encode stream too — change references only")
        #expect(after.imported == 0,
                "the legacy import stream must stay empty on a cutover estate")
    }
}
