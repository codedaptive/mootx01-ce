// EncodeIntakeTests.swift
//
// Dual-Path Intake acceptance line (P3/P4/P6): proves the previously-dark
// semantic-recall lane is now LIT for normally-captured content.
//
// Before this wiring, a capture wrote a LocusKit drawer row only — never
// chunked, never BM25-indexed — so a `moot_memory_search`-style hybrid recall
// could only find captured content via the Locus structured lane, never the
// BM25/vector semantic lane. These tests provision an estate (which mounts the
// dedicated encode queue, D-B), capture through the mode-aware write verb, and
// assert the drawer comes back via the CORPUS BM25 lane (`.corpusBM25`) — the
// lane that was dark before. Two paths:
//
//   • REGULAR: capture returns, awaitEncodeDrain() blocks until the encode
//     worker has ingested, then recall returns the drawer via .corpusBM25.
//   • IMPATIENT: capture ingests inline, so recall returns the drawer via
//     .corpusBM25 immediately, with NO drain wait.

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
import SubstrateTypes
import QueueKit
@testable import GeniusLocusKit

@Suite("Dual-Path Intake — semantic recall is lit for captured content")
struct EncodeIntakeTests {

    // MARK: - Helpers

    /// Provision a GLK estate (mounts Corpus + VectorStore + the dedicated
    /// encode queue with its drain worker), returning the kit and handle.
    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-encode-intake-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Encode Intake Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        // .deterministic embedding model needs no CoreML and is reproducible.
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle)
    }

    /// A recall frame matching every newly captured active row.
    private func recallAllActive() -> RecallFrame {
        RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    /// A hybrid recall request with the given query text.
    private func hybridRequest(query: String, limit: Int = 50) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: recallAllActive(),
            mode: .hybrid,
            scoring: .raw,
            limit: limit,
            fallback: .failClosed,
            queryText: query
        )
    }

    private func captureFrame(_ content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "encode-intake-tests",
            latticeAnchor: .udc("000"),
            addedBy: "encode-intake-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    // MARK: - THE KEY TEST: regular write → drain → semantic recall finds it

    /// A REGULAR write of a fresh drawer, then awaitEncodeDrain(), then a hybrid
    /// recall RETURNS that drawer via the BM25 (corpus) lane — i.e. semantic
    /// recall now works for normally-captured content. This is the lane that was
    /// DARK before the dual-path wiring.
    @Test
    func regularWriteBecomesSemanticallySearchableAfterDrain() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let content = "apple mango banana fruit recall semantic content"
        let drawer = try await kit.capture(handle, captureFrame(content), mode: .regular)

        // Block until the encode worker has ingested the drawer into the Corpus.
        try await kit.awaitEncodeDrain(for: handle)

        // Hybrid recall on a query that matches the seeded content.
        let result = try await kit.recall(handle, hybridRequest(query: "fruit mango recall"))

        // The drawer is returned...
        let hit = result.hits.first { $0.drawer?.id == drawer.id }
        let foundDrawer = try #require(
            hit, "regular-written drawer must be recalled after the encode queue drains")
        // ...AND it was found via the CORPUS BM25 lane — the previously-dark
        // semantic lane. This is the load-bearing assertion: capture content is
        // now BM25-searchable, not only Locus-structured-searchable.
        #expect(foundDrawer.sources.contains(.corpusBM25),
            "the drawer must surface via .corpusBM25 — the semantic lane lit by the encode worker; got \(foundDrawer.sources)")
    }

    // MARK: - IMPATIENT write → immediately searchable, no drain wait

    /// An IMPATIENT write returns and the drawer is IMMEDIATELY semantically
    /// searchable with NO drain wait — the inline encode (P6) ran before the
    /// write returned.
    @Test
    func impatientWriteIsImmediatelySearchable() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let content = "kingfisher heron osprey wading bird estuary content"
        let drawer = try await kit.capture(handle, captureFrame(content), mode: .impatient)

        // NO awaitEncodeDrain — impatient encodes inline before returning.
        let result = try await kit.recall(handle, hybridRequest(query: "heron wading bird"))

        let hit = result.hits.first { $0.drawer?.id == drawer.id }
        let foundDrawer = try #require(
            hit, "impatient-written drawer must be recalled immediately, with no drain wait")
        #expect(foundDrawer.sources.contains(.corpusBM25),
            "impatient drawer must surface via .corpusBM25 immediately; got \(foundDrawer.sources)")
    }

    // MARK: - awaitEncodeDrain returns promptly on an empty queue

    /// awaitEncodeDrain() returns promptly when the queue is empty and does not
    /// hang when there is nothing to drain.
    @Test
    func awaitEncodeDrainReturnsPromptlyWhenEmpty() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        // No writes — the encode queue is empty. awaitEncodeDrain must return
        // quickly without hanging or timing out.
        let start = ContinuousClock.now
        try await kit.awaitEncodeDrain(for: handle, timeout: .seconds(5))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1),
            "awaitEncodeDrain on an empty queue must return promptly, took \(elapsed)")
    }

    // MARK: - Regular vs impatient agree on the final searchable state

    /// After draining, a regular-written drawer and an impatient-written drawer
    /// are both semantically recallable — the two paths converge on the same
    /// lit-lane end state.
    @Test
    func regularAndImpatientConvergeOnSearchableState() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let regular = try await kit.capture(
            handle, captureFrame("tungsten molybdenum refractory metal alloy"),
            mode: .regular)
        let impatient = try await kit.capture(
            handle, captureFrame("tungsten carbide cutting tool tip industrial"),
            mode: .impatient)

        try await kit.awaitEncodeDrain(for: handle)

        let result = try await kit.recall(handle, hybridRequest(query: "tungsten metal"))
        let ids = Set(result.hits.compactMap { $0.drawer?.id })
        #expect(ids.contains(regular.id),
            "regular-written drawer must be searchable after drain")
        #expect(ids.contains(impatient.id),
            "impatient-written drawer must be searchable")
    }

    // MARK: - EncodeJob payload round-trips through QueueKit's Job

    // MARK: - reindexMissing: backfill for pre-wiring drawers

    /// `reindexMissing` enqueues an EncodeJob for every active drawer that is
    /// NOT already in the Corpus BundleStore, so content captured before the
    /// dual-path wiring (or after an index loss) becomes BM25/vector searchable.
    ///
    /// Sequence:
    ///   1. Capture a drawer via the LEGACY no-mode overload (simulating pre-wiring
    ///      content: the row lands but the Corpus is never fed).
    ///   2. Assert the drawer is NOT findable via BM25 (semantic lane dark).
    ///   3. Call `reindexMissing`. Assert the return value is 1.
    ///   4. Drain the encode queue. Assert the drawer IS now findable via BM25.
    @Test
    func reindexMissingEnqueuesUnindexedDrawersAndTheyBecomeSearchable() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let content = "palladium platinum catalyst oxidation chemical"

        // 1. Capture via the legacy path (row-only, no Corpus feed). This simulates
        //    content that landed before the dual-path intake wiring.
        let drawer = try await kit.capture(handle, captureFrame(content))

        // 2. Drain the queue and confirm the drawer is NOT in the Corpus yet.
        //    (The legacy capture never enqueued a job, so the queue is empty and
        //    the drawer's sourceID is absent from the BundleStore.)
        try await kit.awaitEncodeDrain(for: handle)
        let beforeResult = try await kit.recall(handle, hybridRequest(query: "palladium catalyst"))
        let beforeHit = beforeResult.hits.first { $0.drawer?.id == drawer.id && $0.sources.contains(.corpusBM25) }
        #expect(beforeHit == nil,
            "legacy-captured drawer must NOT be found via BM25 before reindexMissing")

        // 3. Call reindexMissing. It should enqueue exactly 1 job.
        let enqueued = try await kit.reindexMissing(handle: handle, now: Date())
        #expect(enqueued == 1,
            "reindexMissing must enqueue 1 job for the 1 un-indexed drawer; got \(enqueued)")

        // 4. Drain and confirm the drawer IS now semantically searchable.
        try await kit.awaitEncodeDrain(for: handle)
        let afterResult = try await kit.recall(handle, hybridRequest(query: "palladium catalyst oxidation"))
        let afterHit = afterResult.hits.first { $0.drawer?.id == drawer.id && $0.sources.contains(.corpusBM25) }
        #expect(afterHit != nil,
            "after reindexMissing + drain, the drawer must surface via .corpusBM25")
    }

    /// `reindexMissing` skips drawers that are already in the Corpus —
    /// idempotence invariant.
    @Test
    func reindexMissingSkipsAlreadyIndexedDrawers() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        // Capture via the mode-aware path (indexed immediately via regular drain).
        _ = try await kit.capture(handle, captureFrame("rhodium iridium rare metal group"), mode: .regular)
        try await kit.awaitEncodeDrain(for: handle)

        // reindexMissing should find 0 missing (the drawer is already indexed).
        let enqueued = try await kit.reindexMissing(handle: handle, now: Date())
        #expect(enqueued == 0,
            "reindexMissing must skip already-indexed drawers; expected 0, got \(enqueued)")
    }

    /// `reindexMissing` correctly handles a mix: some drawers indexed, some not.
    @Test
    func reindexMissingHandlesMixedIndexedAndUnindexed() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        // Capture 2 via mode-aware (will be indexed).
        _ = try await kit.capture(handle, captureFrame("vanadium steel alloying element"), mode: .regular)
        _ = try await kit.capture(handle, captureFrame("chromium stainless hardening"), mode: .regular)
        try await kit.awaitEncodeDrain(for: handle)

        // Capture 3 via legacy path (will NOT be indexed).
        _ = try await kit.capture(handle, captureFrame("niobium tantalum columbite ore"))
        _ = try await kit.capture(handle, captureFrame("molybdenum disulfide lubricant"))
        _ = try await kit.capture(handle, captureFrame("tungsten carbide cutting insert"))

        // reindexMissing must enqueue exactly 3 (the un-indexed ones).
        let enqueued = try await kit.reindexMissing(handle: handle, now: Date())
        #expect(enqueued == 3,
            "reindexMissing must enqueue 3 un-indexed drawers; got \(enqueued)")

        // After draining, all 3 un-indexed drawers should be BM25-searchable.
        try await kit.awaitEncodeDrain(for: handle)
        let result = try await kit.recall(handle, hybridRequest(query: "niobium tungsten carbide"))
        let corpusHits = result.hits.filter { $0.sources.contains(.corpusBM25) }
        #expect(corpusHits.count >= 1,
            "at least 1 reindexed drawer must surface via BM25 after drain; got \(corpusHits.count)")
    }

    // MARK: - EncodeJob round-trip

    /// The EncodeJob payload (P2) survives a Job encode/decode round-trip,
    /// preserving the drawer id, estate uuid, text, model id, and capture instant.
    @Test
    func encodeJobRoundTripsThroughJob() throws {
        let captured = Date(timeIntervalSince1970: 1_700_000_000.5)
        let estate = UUID()
        let payload = EncodeJob(
            drawerID: "drawer-123",
            estateUUID: estate,
            text: "round-trip payload text",
            embeddingModelID: "test-model-v1",
            capturedAt: captured)
        let streamID = StreamID(rawValue: "glk_encode_test")
        let hlc = HLC(physicalTime: 42, logicalCount: 0, nodeID: 1)
        let job = try payload.toJob(streamID: streamID, submittedAt: hlc)
        let decoded = try EncodeJob.from(job: job)

        #expect(decoded.drawerID == "drawer-123")
        #expect(decoded.estateUUID == estate)
        #expect(decoded.text == "round-trip payload text")
        #expect(decoded.embeddingModelID == "test-model-v1")
        // Capture instant round-trips to the same sub-second instant.
        #expect(abs(decoded.capturedAt.timeIntervalSince1970 - captured.timeIntervalSince1970) < 0.001)
        #expect(job.streamID == streamID)
    }
}
