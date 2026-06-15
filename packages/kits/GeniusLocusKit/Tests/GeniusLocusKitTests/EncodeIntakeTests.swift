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
            embeddingModel: .deterministic)
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
            latticeAnchor: .udc("000.000"),
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
