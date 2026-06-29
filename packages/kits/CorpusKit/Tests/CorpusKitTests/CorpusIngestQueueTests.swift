// CorpusIngestQueueTests.swift
//
// Tests for the Corpus-owned ingest pipeline (queue + drain + worker pool),
// relocated into CorpusKit so a Corpus queues, drains, and encodes its own
// content with NO orchestrator (the layering proof: CorpusKit is a standalone
// database substrate). Covers:
//   • the standalone queue→drain→encode path (enqueueIngest → awaitIngestDrain
//     → recall) with no GeniusLocusKit in sight,
//   • the onEncoded coordination callback firing with the encoded sourceIDs,
//   • the at-least-once retry path (a transient ingest failure is retried and
//     the job still lands), and
//   • the IngestJob payload round-trip through QueueKit's Job.
//
// On-disk SQLite backend (makeScratchStorage), EmbeddingModel.deterministic
// (no CoreML). GlobalTestLock guards ingest/recall telemetry emissions.

import Foundation
import PersistenceKit
import PersistenceKitSQLite
import QueueKit
import SubstrateTypes
import Testing

@testable import CorpusKit

private let fixedNow = Date(timeIntervalSinceReferenceDate: 1_000_000)

/// A Sendable sink that records the sourceIDs handed to `onEncoded`.
private actor EncodedIDSink {
    private(set) var ids: [String] = []
    func add(_ batch: [String]) { ids.append(contentsOf: batch) }
}

/// A throwaway transient ingest fault for the at-least-once test.
private struct InjectedTransientIngestError: Error {}

/// Tracks which sourceIDs have already had their single transient failure
/// injected. `@Sendable` closure → lock-guarded.
private final class FirstAttemptFailureSet: @unchecked Sendable {
    private let lock = NSLock()
    private var failed: Set<String> = []
    /// Returns true the FIRST time a sourceID is seen (fail once), false after.
    func shouldFailFirstAttempt(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failed.insert(id).inserted
    }
}

@Suite("Corpus ingest queue", .serialized)
struct CorpusIngestQueueTests {

    // MARK: - Standalone queue → drain → encode (no GLK)

    /// A Corpus mounts its own ingest queue, enqueues documents, and the drain
    /// worker pool ingests them — all with no orchestrator. After
    /// `awaitIngestDrain`, every enqueued document is recallable.
    @Test func standaloneEnqueueDrainMakesContentRecallable() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await Corpus(storage: try makeScratchStorage())
            try await corpus.mountIngestQueue()

            try await corpus.enqueueIngest(
                "tungsten carbide cutting insert for lathe tooling",
                sourceID: "doc-1", now: fixedNow)
            try await corpus.enqueueIngest(
                "molybdenum disulfide dry film lubricant coating",
                sourceID: "doc-2", now: fixedNow)
            try await corpus.enqueueIngest(
                "niobium tantalum columbite ore refining process",
                sourceID: "doc-3", now: fixedNow)

            try await corpus.awaitIngestDrain(timeout: .seconds(20))

            let hits = try await corpus.recall("tungsten carbide tooling", limit: 5, now: fixedNow)
            #expect(!hits.isEmpty, "enqueued + drained content must be recallable")

            // The other documents are independently recallable too.
            let hits2 = try await corpus.recall("molybdenum lubricant", limit: 5, now: fixedNow)
            #expect(!hits2.isEmpty)

            await corpus.dropIngestQueue()
        }
    }

    // MARK: - onEncoded coordination callback

    /// The `onEncoded` callback fires after a drained batch ingests, carrying
    /// the encoded sourceIDs — the seam the orchestrator uses to coordinate the
    /// LocusKit room rollup without CorpusKit reaching into LocusKit.
    @Test func onEncodedFiresWithEncodedSourceIDs() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await Corpus(storage: try makeScratchStorage())
            let sink = EncodedIDSink()
            await corpus.setOnEncoded { ids in await sink.add(ids) }
            try await corpus.mountIngestQueue()

            try await corpus.enqueueIngest("alpha content one", sourceID: "src-A", now: fixedNow)
            try await corpus.enqueueIngest("beta content two", sourceID: "src-B", now: fixedNow)
            try await corpus.awaitIngestDrain(timeout: .seconds(20))

            let seen = Set(await sink.ids)
            #expect(seen.contains("src-A"), "onEncoded must report src-A")
            #expect(seen.contains("src-B"), "onEncoded must report src-B")

            await corpus.dropIngestQueue()
        }
    }

    // MARK: - At-least-once retry (transient ingest failure)

    /// An injected TRANSIENT failure on each source's first ingest attempt is
    /// retried (Corpus ingest is idempotent) and the job still lands — at-least-
    /// once delivery, nothing silently dropped.
    @Test func transientIngestFailureIsRetriedAndStillLands() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await Corpus(storage: try makeScratchStorage())
            try await corpus.mountIngestQueue()

            // Arming the hook flips the drain onto its serial per-job retry path.
            let failedOnce = FirstAttemptFailureSet()
            await corpus._armIngestFailureHook { sourceID in
                if failedOnce.shouldFailFirstAttempt(sourceID) {
                    throw InjectedTransientIngestError()
                }
            }

            try await corpus.enqueueIngest(
                "rhodium iridium platinum group metal catalyst",
                sourceID: "retry-doc", now: fixedNow)
            try await corpus.awaitIngestDrain(timeout: .seconds(20))

            let hits = try await corpus.recall("rhodium iridium catalyst", limit: 5, now: fixedNow)
            #expect(!hits.isEmpty,
                "at-least-once retry must land the job despite the injected transient failure")

            await corpus.dropIngestQueue()
        }
    }

    // MARK: - IngestJob payload round-trip

    /// The IngestJob payload survives a QueueKit Job encode/decode round-trip,
    /// preserving the sourceID, text, and (sub-second) capture instant.
    @Test func ingestJobRoundTripsThroughJob() throws {
        let captured = Date(timeIntervalSince1970: 1_700_000_000.5)
        let payload = IngestJob(
            sourceID: "drawer-123",
            text: "round-trip payload text",
            capturedAt: captured)
        let streamID = StreamID(rawValue: "corpus_ingest")
        let hlc = HLC(physicalTime: 42, logicalCount: 0, nodeID: 1)
        let job = try payload.toJob(streamID: streamID, submittedAt: hlc)
        let decoded = try IngestJob.from(job: job)

        #expect(decoded.sourceID == "drawer-123")
        #expect(decoded.text == "round-trip payload text")
        // Capture instant round-trips to the same sub-second instant.
        #expect(abs(decoded.capturedAt.timeIntervalSince1970 - captured.timeIntervalSince1970) < 0.001)
        #expect(job.streamID == streamID)
    }
}
