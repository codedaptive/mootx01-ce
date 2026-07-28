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
//  • Geometry probe: for a fixed estate and query set, ranks, scores,
//    and explain output are BYTE-IDENTICAL before and after a full
//    distillation sweep, and representation-only writes emit no
//    ContentIndexJob (the encode queue stays drained).
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

    /// One search pass: the exact-search geometry (`moot_memory_search`'s
    /// request shape) with explain enabled, serialized to a deterministic
    /// snapshot string (ids, final scores, explanation lines).
    private func searchSnapshot(
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
                lines.append("\(hit.id) \(hit.score.final)")
                lines.append(contentsOf: hit.explanation)
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

    @Test("geometry invariance: search is byte-identical before and after a distillation sweep, and representation writes emit no index jobs")
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

        // Pre-sweep snapshot. Verify the estate really is undistilled.
        let estate = try await kit.estate(for: handle)
        let before = try await searchSnapshot(kit, handle, queries: queries)
        let preRows = try await estate.allDrawers()
        #expect(preRows.allSatisfy { $0.distilled == nil })

        // Encode queue is idle before the sweep.
        let corpus = try #require(await kit.corpusKits[handle])
        let depthBefore = try await corpus.ingestQueueDepth()
        #expect(depthBefore.pending == 0 && depthBefore.inFlight == 0)

        // Full distillation sweep (the moot_distill path, p1 contract).
        let produced = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: Date(timeIntervalSince1970: 1_750_000_000),
            limit: nil)
        // ≥, not ==: a provisioned estate carries system drawers (e.g. the
        // AI-charter hint) beyond the four fixture bodies, and §13.1 says
        // EVERY active non-empty item distills — the fixture bodies are the
        // floor.
        #expect(produced >= bodies.count, "§13.1: every active non-empty item distills")

        // §9.2: representation-only writes emitted NO ContentIndexJob —
        // the queue frontier is untouched.
        let depthAfter = try await corpus.ingestQueueDepth()
        #expect(depthAfter.pending == 0 && depthAfter.inFlight == 0,
                "a representation-only write must not enqueue an index job")

        // §13.3: ranks, scores, and explain output byte-identical.
        let after = try await searchSnapshot(kit, handle, queries: queries)
        #expect(after == before,
                "distillation must not perturb search geometry (§9.3)")

        // And the sweep really populated the columns (§13.1/§13.5).
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
}
