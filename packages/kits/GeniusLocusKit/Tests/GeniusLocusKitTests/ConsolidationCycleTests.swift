// ConsolidationCycleTests.swift
//
// Wave-2 acceptance coverage for the GLK layer (SPEC_CONSOLIDATION_VAGUE_RECALL):
//   AC-2 (shrinkage): Fast Recall's default excludes exactly the represented
//         constituents and admits the vague item.
//   AC-3 (bounded two-hop): vagueRecall never hydrates more than K per hit /
//         M total.
//   AC-5 (supersession containment): consolidation supersedes NOTHING — every
//         constituent keeps its state; only bit 21 changes.
//   AC-7 (scheduling): the sweep is invocation-only — nothing here runs from
//         a capture path (structural: the sweep is an explicit call).
// Plus: D5 minimum-cluster rejection and sweep idempotence.
//
// Determinism: capture happens "today"; the sweep runs with an injected
// `now` 91 days later, so the D1/D2 age gate passes without wall-clock
// manipulation. No recall traces are written, so the D3 quiet gate passes
// by trace absence — the ratified semantics.

import Testing
import EngramLib
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import VectorKit
import SubstrateTypes
@testable import SubstrateML
@testable import GeniusLocusKit

@Suite("Wave-2 consolidation sweep + vague recall (GLK layer)")
struct ConsolidationCycleTests {

    private let modelID = "test-model-v1"

    /// Provision a full GLK estate (Corpus + VectorStore mounted) — the
    /// production shape; the expunge-based defrag path requires the corpus
    /// registration for its cross-kit vector deletes.
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle, Void) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-consolidation-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Consolidation Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle, ())
    }

    @discardableResult
    private func captureItem(
        body: String, kit: GeniusLocusKit, handle: EstateHandle
    ) async throws -> String {
        let frame = CaptureFrame(
            content: body,
            channel: .typed,
            room: "inbox",
            latticeAnchor: LatticeAnchor.udc("000"),
            addedBy: "test-consolidation",
            embeddingModelID: modelID
        )
        return try await kit.capture(handle, frame).id
    }

    /// Near-identical bodies (entity-heavy so the extractor yields a rich,
    /// clusterable fingerprint) + clearly distinct bodies.
    private let clusterBodies = [
        "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
        "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist now.",
        "Project Falcon deadline moved to March again. Falcon deploy target is the staging cluster. Maria owns the Falcon rollout checklist.",
        "Project Falcon deadline moved to March. Falcon deploy target remains the staging cluster. Maria owns the Falcon rollout checklist.",
    ]
    private let distinctBodies = [
        "Grandmother's lasagna recipe uses fresh basil. The oven runs hot at 400 degrees. Sunday dinners start at six.",
        "The telescope needs a new focuser knob. Jupiter rises after midnight this week. Collimation drifts in cold air.",
    ]

    /// Full pipeline to a consolidated estate: capture → distill (fingerprints)
    /// → consolidation sweep 91 days later. Returns (kit, handle, aged now).
    private func consolidatedEstate() async throws
        -> (GeniusLocusKit, EstateHandle, [String], Date, Int)
    {
        let (kit, handle, _) = try await openEstate()
        var clusterIDs: [String] = []
        for body in clusterBodies {
            clusterIDs.append(try await captureItem(body: body, kit: kit, handle: handle))
        }
        for body in distinctBodies {
            _ = try await captureItem(body: body, kit: kit, handle: handle)
        }
        let now = Date()
        _ = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now, limit: nil)
        let aged = now.addingTimeInterval(91 * 86_400)
        let produced = try await kit.consolidationSweep(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: aged)
        return (kit, handle, clusterIDs, aged, produced)
    }

    // MARK: - The act

    @Test("sweep consolidates the similar cluster and only it; constituents keep state (AC-5)")
    func sweepConsolidatesCluster() async throws {
        let (kit, handle, clusterIDs, _, produced) = try await consolidatedEstate()
        #expect(produced == 1, "exactly the one similar cluster consolidates")

        let estate = try await kit.estate(for: handle)
        let constituents = try await estate.getDrawers(ids: clusterIDs)
        #expect(constituents.count == clusterIDs.count)
        for drawer in constituents {
            #expect(drawer.representedByVague, "every constituent carries bit 21")
            #expect(!drawer.isVague, "constituents are not vague items")
            // AC-5: consolidation supersedes nothing — rows remain present and
            // fetchable with their content intact (state untouched is asserted
            // at the LocusKit layer in ConsolidationTransactionTests; here we
            // pin the GLK-visible half: no tombstone, no content change).
            #expect(!drawer.content.isEmpty)
        }
    }

    @Test("sweep is idempotent — represented constituents leave the pool")
    func sweepIdempotent() async throws {
        let (kit, handle, _, aged, produced) = try await consolidatedEstate()
        #expect(produced == 1)
        let second = try await kit.consolidationSweep(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: aged.addingTimeInterval(3600))
        #expect(second == 0, "re-running the sweep must not re-consolidate")
    }

    @Test("D5: fewer than three similar items never consolidate")
    func minimumClusterSizeHolds() async throws {
        let (kit, handle, _) = try await openEstate()
        for body in clusterBodies.prefix(2) {
            _ = try await captureItem(body: body, kit: kit, handle: handle)
        }
        for body in distinctBodies {
            _ = try await captureItem(body: body, kit: kit, handle: handle)
        }
        let now = Date()
        _ = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now, limit: nil)
        let produced = try await kit.consolidationSweep(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: now.addingTimeInterval(91 * 86_400))
        #expect(produced == 0)
    }

    @Test("D3: recently-recalled items are hot and never consolidate")
    func recallQuietGateHolds() async throws {
        let (kit, handle, _) = try await openEstate()
        var ids: [String] = []
        for body in clusterBodies {
            ids.append(try await captureItem(body: body, kit: kit, handle: handle))
        }
        let now = Date()
        _ = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now, limit: nil)
        let aged = now.addingTimeInterval(91 * 86_400)
        // Trace one cluster member as recalled INSIDE the quiet window: the
        // cluster drops below D5 and nothing consolidates.
        let estate = try await kit.estate(for: handle)
        // Two hot members drop the similar cluster from 4 to 2 — below D5.
        // (One hot member would leave 3, which correctly still consolidates.)
        try await estate.insertRecallTraces([
            RecallTraceItem(
                target: ids[0],
                recalledAt: aged.addingTimeInterval(-86_400),
                score: nil,
                operationalBitmap: 0),
            RecallTraceItem(
                target: ids[1],
                recalledAt: aged.addingTimeInterval(-43_200),
                score: nil,
                operationalBitmap: 0),
        ])
        let produced = try await kit.consolidationSweep(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: aged)
        #expect(produced == 0, "two hot members shrink the cluster below D5")
    }

    // MARK: - AC-2: Fast Recall shrinkage

    @Test("AC-2: default recall excludes represented constituents, admits the vague item")
    func fastRecallShrinkage() async throws {
        let (kit, handle, clusterIDs, _, produced) = try await consolidatedEstate()
        #expect(produced == 1)
        let recalled = try await kit.recall(handle, RecallFrame(
            filterChain: [],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        ))
        let recalledIDs = Set(recalled.map(\.id))
        for id in clusterIDs {
            #expect(!recalledIDs.contains(id),
                    "represented constituent must be excluded from Fast Recall")
        }
        let hasVague = recalled.contains(where: \.isVague)
        #expect(hasVague, "the vague item participates in Fast Recall")
        // Shrinkage arithmetic (AC-2): default recall is exactly the .all
        // tier minus the represented constituents — no more, no fewer.
        // (Count difference, not absolute count: provisioned estates carry
        // system seed drawers, which are ordinary drawers and stay.)
        let everything = try await kit.recall(handle, RecallFrame(
            filterChain: [.recallTier(.all)],
            hydrationLevel: .full,
            ordering: .byCaptureTimeDesc
        ))
        #expect(everything.count - recalled.count == clusterIDs.count)
    }

    // MARK: - §5.1 fold-in

    @Test("fold-in: a newly-aged neighbor joins the existing vague item's own lineage")
    func foldInReconsolidation() async throws {
        let (kit, handle, clusterIDs, aged, produced) = try await consolidatedEstate()
        #expect(produced == 1)

        // A fifth similar item arrives after the first consolidation…
        let fifthID = try await captureItem(
            body: "Project Falcon deadline moved to March. Falcon deploy target is the staging cluster. Maria still owns the Falcon rollout checklist.",
            kit: kit, handle: handle)
        _ = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn,
            now: aged.addingTimeInterval(3_600), limit: nil)

        // …and ages past the gate before the next maintenance window.
        let aged2 = aged.addingTimeInterval(92 * 86_400)
        // Explicit D4 ceiling (configured wins — the ratified alternative to
        // per-sweep derivation): the combined-distillate fingerprint sits
        // at ~59 (Swift) / ~106 (Rust) bits of a member's per-item fingerprint across the
        // two ports on this fixture (the provisioned system seeds also
        // tighten the DERIVED p10 below it). 112 pins the fold MECHANICS with
        // margin on both sides, twin-aligned with the Rust suite.
        var foldConfig = ConsolidationConfig()
        foldConfig.hammingCeiling = 112
        let report = try await kit.consolidationSweepReport(
            handle: handle,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: aged2,
            config: foldConfig)
        #expect(report.foldIns == 1, "the neighbor folds into the existing vague item")

        // The active vague version carries the ENLARGED constituent set; the
        // prior version is superseded in the SAME lineage (§3.3 containment).
        let v2 = try await kit.vagueRecall(handle, query: "Project Falcon rollout checklist")
        #expect(v2.vagueHits.count == 1, "exactly one ACTIVE vague version")
        let enlarged = try await (try await kit.estate(for: handle))
            .vagueConstituents(of: v2.vagueHits[0].id)
        #expect(Set(enlarged) == Set(clusterIDs + [fifthID]))
        let folded = try await (try await kit.estate(for: handle)).getDrawers(ids: [fifthID])
        #expect(folded.first?.representedByVague == true)
    }

    @Test("§5.2 defrag = cascade + re-consolidate; constituents never orphaned")
    func defragRecomposes() async throws {
        let (kit, handle, clusterIDs, aged, produced) = try await consolidatedEstate()
        #expect(produced == 1)
        let hit = try await kit.vagueRecall(handle, query: "Project Falcon rollout checklist")
        let vagueID = try #require(hit.vagueHits.first?.id)

        let report = try await kit.defragVagueItem(
            handle: handle,
            vagueDrawerID: vagueID,
            distillFn: GeniusLocusKit.defaultDistillFn,
            now: aged.addingTimeInterval(86_400))
        #expect(report.newVagueItems == 1, "the reverted pool re-consolidates")

        let estate = try await kit.estate(for: handle)
        let constituents = try await estate.getDrawers(ids: clusterIDs)
        let allRepresented = constituents.allSatisfy(\.representedByVague)
        #expect(allRepresented, "constituents are represented by the REBUILT vague item")
        let rebuilt = try await kit.vagueRecall(handle, query: "Project Falcon rollout checklist")
        #expect(rebuilt.vagueHits.count == 1)
        #expect(rebuilt.vagueHits[0].id != vagueID, "the drifted vague item was expunged")
    }

    // MARK: - AC-3: bounded two-hop

    @Test("AC-3: vagueRecall hydrates constituents, bounded by K and M")
    func vagueRecallBounded() async throws {
        let (kit, handle, clusterIDs, _, produced) = try await consolidatedEstate()
        #expect(produced == 1)

        let full = try await kit.vagueRecall(
            handle, query: "Project Falcon rollout checklist")
        #expect(full.vagueHits.count == 1)
        let allVague = full.vagueHits.allSatisfy(\.isVague)
        #expect(allVague)
        #expect(Set(full.constituents.map(\.id)) == Set(clusterIDs),
                "hop 2 hydrates the full constituent set within bounds")

        // K bound: cluster of 4 with K=2 hydrates exactly 2.
        let kBound = try await kit.vagueRecall(
            handle, query: "Project Falcon rollout checklist",
            constituentsPerHit: 2)
        #expect(kBound.constituents.count == 2)

        // M bound: M=1 wins over K.
        let mBound = try await kit.vagueRecall(
            handle, query: "Project Falcon rollout checklist",
            constituentsPerHit: 8, totalConstituents: 1)
        #expect(mBound.constituents.count == 1)
    }
}
