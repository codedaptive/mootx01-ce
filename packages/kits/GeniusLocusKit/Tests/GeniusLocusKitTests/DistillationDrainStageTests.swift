// DistillationDrainStageTests.swift
//
// SPEC_DISTILLATION_STORAGE §7.1 (drain-stage integration) and §9/§13.3
// (search isolation — the geometry probe).
//
//  • Drain-stage: capture of an eligible drawer rides the encode drain;
//    when `awaitEncodeDrain` returns, the drawer carries its distilled
//    representation — "a fully drained estate is a fully distilled
//    estate". The onEncoded callback fires BEFORE the terminal queue
//    reply (CorpusKit ordering), so the barrier is real, not a race.
//  • Geometry probe (Stream F amendment): §9 BM25 isolation holds — the
//    BM25 lane is invariant after distillation (content and digest
//    unchanged). The dense float lane changes: distillItemsSweep now calls
//    recomposeDenseVector for each swept item, so dense vectors are
//    distillate-composed post-sweep ("settled" state). The probe verifies
//    both invariants: BM25 byte-identical; dense scores differ.
//    Representation-only writes emit no ContentIndexJob (queue stays drained).
//
// Rust twin: coordinator.rs distillation tests cover the sweep; the
// queue-ordering twin is content_engine_queue.rs (fire_on_encoded before
// reply_batch).

import Testing
import Foundation
import LocusKit
@testable import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
import SubstrateTypes
@testable import SubstrateML
@testable import GeniusLocusKit

@Suite("Distillation drain-stage + search isolation")
struct DistillationDrainStageTests {

    // MARK: - Fixture

    /// Provision a GLK estate (mounts Corpus + VectorStore + drain workers).
    /// Same fixture as EncodeIntakeTests / DeltaReindexTests.
    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-distill-drain-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Distillation Drain Test Estate",
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
            room: "distill-drain-tests",
            latticeAnchor: .udc("000"),
            addedBy: "distill-drain-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    /// BM25-only recall snapshot (corpusOnly + rrf). §9: BM25 scores must be
    /// byte-identical before and after a distillation sweep — content and
    /// digest are unchanged; the BM25 index keys on `text`.
    private func bm25Snapshot(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, queries: [String]
    ) async throws -> String {
        var lines: [String] = []
        for query in queries {
            let request = GLKRecallRequest(
                frame: RecallFrame(filterChain: [], hydrationLevel: .full, limit: 20),
                mode: .corpusOnly,
                scoring: .rrf,
                limit: 20,
                fallback: .allowDegraded,
                queryText: query,
                origin: .external
            )
            let result = try await kit.recall(handle, request)
            lines.append("query: \(query)")
            for hit in result.hits {
                lines.append("\(hit.id) \(hit.score.bm25)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Dense-lane score snapshot (unionBest + matrixAware, `score.dense`).
    /// After a distillation sweep that triggers recomposeDenseVector, the
    /// dense float vectors are distillate-composed ("settled" state), so
    /// scores differ from the pre-sweep organic baseline.
    private func denseScoreSnapshot(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, queries: [String]
    ) async throws -> String {
        var lines: [String] = []
        for query in queries {
            let request = GLKRecallRequest(
                frame: RecallFrame(filterChain: [], hydrationLevel: .full, limit: 20),
                mode: .unionBest,
                scoring: .matrixAware,
                limit: 20,
                fallback: .allowDegraded,
                queryText: query,
                origin: .external
            )
            let result = try await kit.recall(handle, request)
            lines.append("query: \(query)")
            for hit in result.hits {
                // `score.dense` is the normalized cosine similarity from the
                // dense float lane. 0 for hits that did not come from the
                // dense lane.
                lines.append("\(hit.id) \(hit.score.dense)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - §7.1 drain-stage

    @Test("a fully drained estate is a fully distilled estate")
    func drainedEstateIsDistilled() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        // Regular-mode capture rides the encode queue; the drain worker
        // encodes, then the onEncoded callback distills BEFORE the job is
        // replied — so the drain barrier covers distillation.
        let drawer = try await kit.capture(
            handle,
            captureFrame("The launch review moved to Friday. Ops signed off. Legal pending."),
            mode: .regular)
        try await kit.awaitEncodeDrain(for: handle, timeout: .seconds(30))

        let estate = try await kit.estate(for: handle)
        let row = try #require(try await estate.getDrawers(ids: [drawer.id]).first)
        #expect(row.distilled != nil,
                "post-drain the representation columns must be populated (§7.1)")
        #expect(row.distilledPipelineVersion == DistillationPipelineVersion.current)
        #expect(row.distilledTokenCount != nil)
        #expect(row.distilledAt != nil)
        // The rendering carries no inline metadata (§5.2).
        #expect(!(row.distilled ?? "").hasPrefix("[DIST|"))
    }

    @Test("drain-stage uses the registered distillFn override when present")
    func drainStageUsesRegisteredOverride() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        await kit.registerDistillationFunction({ _ in
            DistillationOutput(
                distilledText: "STUB RENDERING",
                confidence: 1.0, uncertain: false, snr: 1.0, deltaType: nil,
                succeeded: true, failureReason: nil,
                featureFingerprint: DistillationPipeline.featureHash("stub"))
        }, for: handle)

        let drawer = try await kit.capture(
            handle,
            captureFrame("Alpha statement holds. Beta statement holds. Gamma statement holds."),
            mode: .regular)
        try await kit.awaitEncodeDrain(for: handle, timeout: .seconds(30))

        let estate = try await kit.estate(for: handle)
        let row = try #require(try await estate.getDrawers(ids: [drawer.id]).first)
        #expect(row.distilled == "STUB RENDERING")
    }

    // MARK: - §9/§13.3 geometry probe

    @Test("BM25 invariant after distillation sweep; dense scores change when distillate lands")
    func geometryInvarianceProbe() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        // Impatient captures index inline (no queue job, no onEncoded, so
        // the estate is searchable but UNDISTILLED — the pre-sweep state).
        let bodies = [
            "The reactor maintenance window opens on March 3rd at the Geneva site.",
            "Sarah approved the vendor contract for the Geneva facility yesterday.",
            "Quarterly metrics show reactor uptime improved by twelve percent.",
            "The travel policy for contractor visits was updated last week.",
        ]
        for body in bodies {
            _ = try await kit.capture(handle, captureFrame(body), mode: .impatient)
        }
        let queries = ["reactor maintenance Geneva", "vendor contract", "travel policy"]

        // Pre-sweep: verify the estate is undistilled.
        let estate = try await kit.estate(for: handle)
        let preRows = try await estate.allDrawers()
        #expect(preRows.allSatisfy { $0.distilled == nil })

        // Encode queue is idle before the sweep.
        let corpus = try #require(await kit.corpusKits[handle])
        let depthBefore = try await corpus.ingestQueueDepth()
        #expect(depthBefore.pending == 0 && depthBefore.inFlight == 0)

        // BM25-only pre-sweep snapshot (organic state — lexical-composed vectors,
        // distilled columns nil). Dense pre-sweep snapshot captures the organic
        // (lexical-composed) dense scores.
        let bm25Before = try await bm25Snapshot(kit, handle, queries: queries)
        let densesBefore = try await denseScoreSnapshot(kit, handle, queries: queries)

        // Full distillation sweep (the moot_distill path, p1 contract).
        // Stream F: sweep also calls recomposeDenseVector for each swept item.
        let produced = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: Date(timeIntervalSince1970: 1_750_000_000),
            limit: nil)
        // ≥, not ==: a provisioned estate carries system drawers (e.g. the
        // AI-charter hint) beyond the four fixture bodies, and §13.1 says
        // EVERY active non-empty item distills — the fixture bodies are the floor.
        #expect(produced >= bodies.count, "§13.1: every active non-empty item distills")

        // §9.2: representation-only writes emitted NO ContentIndexJob.
        let depthAfter = try await corpus.ingestQueueDepth()
        #expect(depthAfter.pending == 0 && depthAfter.inFlight == 0,
                "a representation-only write must not enqueue an index job")

        // §9 (BM25 isolation): BM25 scores are byte-identical before and after
        // the sweep. Content was not modified; the digest keys on `text` and is
        // unchanged by writing the distilled column. The BM25 index is anchored
        // to `text` — distillation is invisible to it.
        let bm25After = try await bm25Snapshot(kit, handle, queries: queries)
        #expect(bm25After == bm25Before,
                "BM25 scores must be byte-identical after distillation sweep (§9)")

        // Dense-over-distillate (Stream F): after the sweep, recomposeDenseVector
        // was called for every swept item. The dense float vectors are now
        // distillate-composed ("settled" state). Dense scores differ from the
        // organic (lexical-composed) baseline — this is the settled testmark
        // precondition: post-sweep recall geometry differs in the dense lane.
        let densesAfter = try await denseScoreSnapshot(kit, handle, queries: queries)
        #expect(densesAfter != densesBefore,
                "dense scores must change after distillation sweep (Stream F: settled > organic)")

        // And the sweep really populated the distillation columns (§13.1/§13.5).
        let postRows = try await estate.allDrawers()
        #expect(postRows.allSatisfy { $0.distilled != nil && $0.distilledTokenCount != nil })
    }

    // MARK: - §7.1 drain accounting (moot_drain_status surface)

    @Test("drainStatuses reports distillation pending and reaches idle only when fully distilled")
    func drainStatusesIncludesDistillation() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        // Impatient captures: searchable but undistilled (no queue job, no
        // onEncoded) — the pre-sweep state the accounting must expose.
        for body in ["First fact stands alone here.", "Second fact stands alone here."] {
            _ = try await kit.capture(handle, captureFrame(body), mode: .impatient)
        }

        let before = try await kit.drainStatuses(handle)
        let distillBefore = try #require(before.first { $0.name == "distillation" },
            "the distillation drain must be reported on every estate")
        #expect(distillBefore.pending >= 2,
            "undistilled rows must count as pending — fully-drained must not false-positive")
        #expect(distillBefore.isDraining)

        _ = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn,
            now: Date(timeIntervalSince1970: 1_750_000_000), limit: nil)

        let after = try await kit.drainStatuses(handle)
        let distillAfter = try #require(after.first { $0.name == "distillation" })
        #expect(distillAfter.pending == 0, "a swept estate reads fully distilled")
        #expect(!distillAfter.isDraining)
    }

    // MARK: - Finding 3 regression: the T5 finisher gate keys on the ENCODE drain only

    // PERF_W1_DRAIN_RIDER_2026-07-28 Finding 3: the "distillation" drain entry
    // counts rows that only a sweep can distill (system-provisioned drawers
    // never transit the encode queue), so a T5 exit check keyed on ALL drains
    // never settles — the detached drainer holds the encode DrainLease for its
    // full maxWait and wedges the next serve session's encode queue. The gate
    // for spawning/exiting the T5 finisher is `DrainStatus.encodeSettled`,
    // which must ignore every drain except "corpus_encode".

    @Test("a non-idle distillation drain must not block T5 exit / lease release")
    func encodeSettledIgnoresNonIdleDistillationDrain() {
        let statuses = [
            DrainStatus(name: DrainStatus.corpusEncodeName, pending: 0, inFlight: 0,
                        detail: "encoded_chunks: 42"),
            // The Finding 3 shape: system-provisioned drawers (wing seeds,
            // AI_Charter_Hint) counted undistilled on an otherwise-drained estate.
            DrainStatus(name: "distillation", pending: 7, inFlight: 0,
                        detail: "pipeline: p1"),
        ]
        #expect(DrainStatus.encodeSettled(statuses),
                "distillation pending must not hold the T5 finisher or its lease")
    }

    @Test("encode work on either frontier keeps the T5 gate closed")
    func encodeSettledFalseWhileEncodeDrainHasWork() {
        let pending = [
            DrainStatus(name: DrainStatus.corpusEncodeName, pending: 3, inFlight: 0),
            DrainStatus(name: "distillation", pending: 0, inFlight: 0),
        ]
        let inFlight = [
            DrainStatus(name: DrainStatus.corpusEncodeName, pending: 0, inFlight: 1)
        ]
        #expect(!DrainStatus.encodeSettled(pending))
        #expect(!DrainStatus.encodeSettled(inFlight))
    }

    @Test("an estate with no encode drain reads settled (bare estate / empty list)")
    func encodeSettledTrueWhenNoEncodeDrainListed() {
        #expect(DrainStatus.encodeSettled([]))
        #expect(DrainStatus.encodeSettled(
            [DrainStatus(name: "distillation", pending: 7, inFlight: 0)]))
    }

    @Test("live estate: undistilled rows leave the T5 gate open for exit")
    func t5GateSettlesOnLiveEstateWithUndistilledRows() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        // Impatient captures are the same shape as Finding 3's system drawers:
        // rows present and searchable, but never routed through the encode
        // queue, so only a sweep can distill them. The distillation drain is
        // non-idle; the encode drain is idle.
        for body in ["First fact stands alone here.", "Second fact stands alone here."] {
            _ = try await kit.capture(handle, captureFrame(body), mode: .impatient)
        }
        let statuses = try await kit.drainStatuses(handle)
        let distill = try #require(statuses.first { $0.name == "distillation" })
        #expect(distill.isDraining, "precondition: the Finding 3 shape is present")
        #expect(DrainStatus.encodeSettled(statuses),
                "the T5 finisher must exit (releasing the encode lease) on this estate")
    }
}
