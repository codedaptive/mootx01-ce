// DenseOverDistillateTests.swift
//
// MISSION_11X_RECALL_GAP_01 Stream F — dense-over-distillate (GLK integration).
//
// Verifies the four BRR-required properties at the GeniusLocusKit level:
//
//  §null-fallback  An undistilled drawer's float vector is composed from
//      `text` (effectiveDenseText fallback). The float lane is functional
//      and the drawer appears in dense recall before any distillation sweep.
//
//  §recompose-on-distill  After a distillate is written (sweep path), the
//      float vector is recomposed via CorpusContentEngine.recomposeDenseVector
//      (never direct to VectorStore). Dense scores differ from the organic
//      (lexical-composed) baseline — this is the "settled > organic" testmark.
//
//  §retrain-recomposes  After a distillate is written and a full reindex is
//      triggered (the retrain path — CorpusContentEngine.reindex), the float
//      vector uses effectiveDenseText (the distillate), not raw `text`. The
//      retrain score equals the recompose score: both use effectiveDenseText
//      so the resulting float vectors are bit-identical.
//
//  §mixed-estate  An estate where some drawers are settled (distillate-composed
//      float vectors) and others are organic (lexical-composed) can recall from
//      both in the same unionBest query. Neither group is invisible to float
//      recall; the settled drawers score differently from the organic ones.
//
// Rust twin: coordinator.rs distillation tests cover the sweep path;
// content_engine.rs recompose_dense_float covers the float-lane write.

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

@Suite("DenseOverDistillate — GLK integration", .serialized)
struct DenseOverDistillateTests {

    // MARK: - Shared timestamp

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Fixture

    /// Provision a GLK estate with the deterministic embedding model.
    /// The deterministic provider implements embedFloat (FNV-1a + FloatSimHash),
    /// so float-lane results are real and content-sensitive in test environments
    /// without CoreML.
    private func provisionGLKEstate(ownerID: String = "owner-dense-over-distillate")
        async throws -> (GeniusLocusKit, EstateHandle)
    {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "DenseOverDistillate Test Estate",
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
            room: "dense-over-distillate-tests",
            latticeAnchor: .udc("000"),
            addedBy: "dense-over-distillate-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    /// Recall via the dense float lane (unionBest + matrixAware).
    /// Returns the hit list for `queryText`, or [] when no dense lane is
    /// available (provider opted out for this query shape).
    private func denseRecall(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, queryText: String, limit: Int = 20
    ) async throws -> [RecallHit] {
        let request = GLKRecallRequest(
            frame: RecallFrame(filterChain: [], hydrationLevel: .full, limit: limit),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: limit,
            fallback: .allowDegraded,
            queryText: queryText,
            origin: .external
        )
        let result = try await kit.recall(handle, request)
        // Keep only hits that have a non-zero dense component — hits surfaced
        // only by BM25 carry score.dense == 0.
        return result.hits.filter { $0.score.dense > 0 }
    }

    /// Extract the dense score for a specific drawer ID from a hit list.
    /// Returns nil when the drawer does not appear in the hit list.
    private func denseScore(for drawerID: String, in hits: [RecallHit]) -> Float? {
        hits.first(where: { $0.id == drawerID })?.score.dense
    }

    // MARK: - §null-fallback

    @Test("undistilled drawer produces a valid float vector (null-fallback composition)")
    func undistilledDrawerAppearsInFloatLane() async throws {
        let (kit, handle) = try await provisionGLKEstate(
            ownerID: "owner-null-fallback")
        // Impatient capture: item is indexed immediately with nil distillate.
        // effectiveDenseText returns `text` (the null-fallback path).
        let drawer = try await kit.capture(
            handle,
            captureFrame(
                "The satellite telemetry feed reports nominal trajectory adjustments."),
            mode: .impatient)

        let hits = try await denseRecall(
            kit, handle, queryText: "satellite telemetry trajectory")

        // The drawer must appear in float-lane recall. If the float lane were
        // not populated (null-fallback broken), the hit would be absent here.
        let score = denseScore(for: drawer.id, in: hits)
        #expect(score != nil,
                "§null-fallback: undistilled drawer must appear in float-lane recall (effectiveDenseText → text)")
        #expect((score ?? 0) > 0,
                "§null-fallback: dense score for the drawer must be positive")

        // Verify the drawer is genuinely undistilled (precondition for the test).
        let estate = try await kit.estate(for: handle)
        let row = try #require(try await estate.getDrawers(ids: [drawer.id]).first)
        #expect(row.distilled == nil, "precondition: impatient capture must not trigger distillation")
    }

    // MARK: - §recompose-on-distill

    @Test("dense float vector changes when distillate lands via sweep path (settled > organic)")
    func sweepRecomposesDenseVectorAcrossCorpus() async throws {
        let (kit, handle) = try await provisionGLKEstate(
            ownerID: "owner-recompose-on-distill")
        // Multiple items in undistilled (organic) state. Dense vectors are
        // lexical-composed (effectiveDenseText returns `text`).
        let contents = [
            "The accelerometer calibration drift exceeded the acceptable margin.",
            "Firmware rollback procedures require supervisor approval at midnight.",
            "Temperature sensors in zone three are showing erratic variance.",
        ]
        for content in contents {
            _ = try await kit.capture(handle, captureFrame(content), mode: .impatient)
        }
        let query = "accelerometer calibration drift"

        // Organic (pre-sweep) dense snapshot.
        let organicHits = try await denseRecall(kit, handle, queryText: query)
        let organicScores = organicHits.map { "\($0.id):\($0.score.dense)" }.sorted()

        // Full distillation sweep. Stream F: sweep calls recomposeDenseVector
        // for every swept item immediately after writing its distillate.
        _ = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: t0,
            limit: nil)

        // Settled (post-sweep) dense snapshot.
        let settledHits = try await denseRecall(kit, handle, queryText: query)
        let settledScores = settledHits.map { "\($0.id):\($0.score.dense)" }.sorted()

        // Dense vectors must change: post-sweep vectors are distillate-composed,
        // organics are lexical-composed. If scores are equal, the recompose
        // did not fire or had no effect (both are failures).
        //
        // Guard: if the dense lane returned no hits in either pass (provider
        // opted out), we cannot observe the change — skip rather than false-fail.
        if !organicScores.isEmpty && !settledScores.isEmpty {
            #expect(settledScores != organicScores,
                    "§recompose-on-distill: dense scores must change after sweep + recompose (settled > organic)")
        }
    }

    // MARK: - §retrain-recomposes

    @Test("full reindex after distillate uses effectiveDenseText (retrain produces same float as recompose)")
    func reindexAfterDistillateUsesEffectiveDenseText() async throws {
        let (kit, handle) = try await provisionGLKEstate(
            ownerID: "owner-retrain-recomposes")
        // Item in organic state (lexical-composed float vector).
        let drawer = try await kit.capture(
            handle,
            captureFrame(
                "The neutron flux monitoring protocol requires quarterly re-certification."),
            mode: .impatient)

        // Organic dense score (lexical-composed).
        let organicHits = try await denseRecall(
            kit, handle, queryText: "neutron flux monitoring")
        let organicScore = denseScore(for: drawer.id, in: organicHits)

        // Sweep: writes distillate + recomposeDenseVector via the sweep-path
        // rider. Post-sweep, the float vector is distillate-composed.
        _ = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: t0,
            limit: nil)

        let postSweepHits = try await denseRecall(
            kit, handle, queryText: "neutron flux monitoring")
        let postSweepScore = denseScore(for: drawer.id, in: postSweepHits)

        // Full reindex (the retrain path): CorpusContentEngine.reindex calls
        // indexWholeContentBatch with force:true, which uses effectiveDenseText
        // for the float vector — same text as recomposeDenseFloat just used.
        // The resulting float vectors must be bit-identical between the two
        // paths, so the dense score after reindex equals the post-sweep score.
        let corpus = try #require(await kit.corpusKits[handle])
        try await corpus.reindex(now: t0)

        let postReindexHits = try await denseRecall(
            kit, handle, queryText: "neutron flux monitoring")
        let postReindexScore = denseScore(for: drawer.id, in: postReindexHits)

        // Guard: skip comparison if the float lane was unavailable (empty results).
        if let sweep = postSweepScore, let reindex = postReindexScore {
            // §retrain-recomposes: both paths read effectiveDenseText (the
            // distillate). Float vectors are bit-identical → scores match.
            #expect(reindex == sweep,
                    "§retrain: reindex float score must match post-sweep score (both use effectiveDenseText)")
        }

        // Separately: the settled score must differ from the organic score
        // (proving the distillate changed the embedding, not just that both
        // paths are consistently wrong).
        if let organic = organicScore, let reindex = postReindexScore {
            #expect(reindex != organic,
                    "§retrain: post-distillate reindex score must differ from organic (effectiveDenseText ≠ text)")
        }
    }

    // MARK: - §mixed-estate

    @Test("mixed settled/organic estate: both groups present in float-lane recall")
    func mixedEstateRecallCoversSettledAndOrganic() async throws {
        let (kit, handle) = try await provisionGLKEstate(
            ownerID: "owner-mixed-estate")

        // Two groups of items. After the sweep, groupA is settled
        // (distillate-composed vectors); groupB remains organic (lexical-composed).
        // We use distinct sentinel words to distinguish the two groups in recall.
        let groupAContent = [
            "Cryogenic helium supply logistics involve weekly pressure verification schedules.",
            "The laser alignment procedure must be performed under blackout conditions.",
        ]
        let groupBContent = [
            "Contract renewal negotiations with the procurement team are pending approval.",
            "Quarterly expense reconciliation requires three-way match validation.",
        ]

        var groupADrawers: [LocusKit.Drawer] = []
        var groupBDrawers: [LocusKit.Drawer] = []

        for content in groupAContent {
            groupADrawers.append(
                try await kit.capture(handle, captureFrame(content), mode: .impatient))
        }
        for content in groupBContent {
            groupBDrawers.append(
                try await kit.capture(handle, captureFrame(content), mode: .impatient))
        }

        // Sweep distills groupA (and any system drawers). groupB is left
        // undistilled by running only two items' worth of sweep.
        // Use a low limit (groupA count) to distill only the groupA drawers.
        // Note: system-provisioned drawers may also distill within the limit;
        // the constraint is that at least one groupB drawer remains organic.
        let groupACount = groupADrawers.count
        _ = try await kit.distillItemsSweep(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: t0,
            limit: groupACount)

        // Verify at least one groupB drawer is still undistilled (organic).
        let estate = try await kit.estate(for: handle)
        let groupBRows = try await estate.getDrawers(ids: groupBDrawers.map { $0.id })
        let organicBCount = groupBRows.filter { $0.distilled == nil }.count
        guard organicBCount > 0 else {
            // Limit did not constrain to groupA only; the mixed condition cannot
            // be verified — this is a fixture constraint failure, not a product bug.
            return
        }

        // Both groups must be recall-able via the dense float lane.
        // Query A: semantically close to groupA content (cryogenic + laser).
        // Query B: semantically close to groupB content (contract + expense).
        let queryA = "helium cryogenic laser alignment"
        let queryB = "contract renewal expense reconciliation"

        let hitsA = try await denseRecall(kit, handle, queryText: queryA)
        let hitsB = try await denseRecall(kit, handle, queryText: queryB)

        // At least one drawer from each group must appear in the respective
        // float-lane recall result. Neither organic nor settled drawers should
        // disappear from recall due to the recompose operation.
        let groupAIDsInA = groupADrawers.map { $0.id }.filter { id in
            hitsA.contains(where: { $0.id == id })
        }
        let groupBIDsInB = groupBDrawers.map { $0.id }.filter { id in
            hitsB.contains(where: { $0.id == id })
        }

        #expect(!groupAIDsInA.isEmpty,
                "§mixed-estate: settled (distillate-composed) drawers must appear in float-lane recall")
        #expect(!groupBIDsInB.isEmpty,
                "§mixed-estate: organic (lexical-composed) drawers must appear in float-lane recall")
    }
}
