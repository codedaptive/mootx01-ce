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

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle, VectorStore) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-consolidation-tests")
        let estateStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: estateStorage, owner: owner)
        try await estateStorage.open(schema: GeniusLocusKitSchema.estateSchemaDeclaration)
        let handle = try await kit.open(storage: estateStorage, owner: owner)

        let vsStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        try await vsStorage.open(schema: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle, vectorStore)
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
        // Shrinkage arithmetic: pool was 6 originals; default recall returns
        // the 2 distinct items + 1 vague item — exactly the constituents gone.
        #expect(recalled.count == distinctBodies.count + 1)
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
