// SeedHintEncodeTests.swift
//
// Seeded-hint encode routing: the seven seeded AI_Charter_Hint wing drawers
// go through the encode path INLINE (seedDefaultWings indexes them in place,
// the same transform a queued drawer gets at drain), so:
//
//   • every hint is in the corpus index the moment provision returns, and
//     the encode drain is settled with nothing pending;
//   • re-running seedDefaultWings on an already-converged estate does
//     NOTHING — no queue work (idempotent open);
//   • a seeded hint is recallable via BM25 (the EstateVerbs.seedWing
//     "recallable like any other drawer" promise, defect 2).
//
// Rust twin: coordinator.rs `seed_hint_*` tests.

import Testing
import Foundation
import LocusKit
@testable import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
import SynapseKit
import SubstrateTypes
@testable import SubstrateML
@testable import GeniusLocusKit

@Suite("Seeded hint encode routing", .serialized)
struct SeedHintEncodeTests {

    /// Provision a GLK estate (mounts Corpus + VectorStore + drain workers).
    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-seed-hint-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Seed Hint Encode Test Estate",
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

    /// The number of seeded hint drawers that have no corpus index row —
    /// zero once seeding has indexed every hint inline.
    private func unindexedHintCount(
        _ kit: GeniusLocusKit, _ handle: EstateHandle
    ) async throws -> Int {
        let estate = try await kit.estate(for: handle)
        let all = try await estate.allDrawers()
        let names = try await estate.resolveNodeNames(parentNodeIds: all.map(\.parentNodeId))
        let hints = all.filter { names[$0.parentNodeId]?.room == LocusKit.hintRoom }
        let corpus = try #require(await kit.corpusKits[handle])
        let indexed = Set(try await corpus.allIndexStates().map(\.contentID))
        return hints.filter { !indexed.contains($0.id) }.count
    }

    @Test("fresh estate + drain: every hint is indexed inline and the drains are settled")
    func freshEstateDrainsToZero() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        // Seeding indexes its hints inline, so the estate OPENS settled —
        // every hint has its index row before anything drives the queue.
        #expect(try await unindexedHintCount(kit, handle) == 0,
                "seeding indexes inline: no hint may be unindexed at open, before any drain")
        // Draining changes nothing (there is no seed batch to drain) and
        // must leave the hints indexed.
        try await kit.awaitEncodeDrain(for: handle)
        #expect(try await unindexedHintCount(kit, handle) == 0,
                "the 7 seeded hints must stay indexed after the drain")
        // The encode drain itself is also settled.
        let statuses = try await kit.drainStatuses(handle)
        #expect(DrainStatus.encodeSettled(statuses))
        #expect(statuses.allSatisfy { !$0.isDraining },
                "every drain lane settles on a fresh drained estate: \(statuses)")
    }

    @Test("re-running seedDefaultWings on a converged estate enqueues nothing (idempotent open)")
    func reseedEnqueuesNothing() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        try await kit.awaitEncodeDrain(for: handle)
        #expect(try await unindexedHintCount(kit, handle) == 0)

        // Simulate the estate being re-opened: the open path calls
        // seedDefaultWings again. All 7 wings exist and all 7 hints are
        // already indexed, so the inline transform is a digest compare per
        // hint and the queue must see ZERO jobs.
        try await kit.seedDefaultWings(for: handle, now: Date(timeIntervalSince1970: 1_800_000_000))
        let corpus = try #require(await kit.corpusKits[handle])
        let depth = try await corpus.ingestQueueDepth()
        #expect(depth.pending == 0 && depth.inFlight == 0,
                "re-seed must not enqueue indexed hints (got \(depth))")
        #expect(try await unindexedHintCount(kit, handle) == 0)
    }

    @Test("a seeded hint is recallable via BM25 (defect-2 closure)")
    func seededHintIsRecallable() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        try await kit.awaitEncodeDrain(for: handle)

        // Distinctive phrase from the "User Canon" wing hint
        // (LocusKit.defaultWings): "standing orders".
        let corpus = try #require(await kit.corpusKits[handle])
        let hits = try await corpus.bm25TopK(query: "user directives standing orders", limit: 10)
        #expect(!hits.isEmpty, "the seeded User Canon hint must be BM25-recallable")

        // The top hit hydrates to the hint drawer (content contains the phrase).
        let estate = try await kit.estate(for: handle)
        let ids = hits.map(\.id)
        let drawers = try await estate.getDrawers(ids: ids)
        #expect(drawers.contains { $0.content.contains("standing orders") },
                "a BM25 hit for the hint phrase must hydrate to the seeded hint drawer")
    }

    @Test("charters carry the fixed sentinel identity: charterSeedDate + well-known IDs")
    func chartersCarrySentinelIdentity() async throws {
        // Failure mode this discriminates: with wall-clock stamps / random
        // UUIDs restored, the ID-set assertion fails immediately (random ids)
        // and the date assertion fails on any estate provisioned after 2000 —
        // the exact pre-fix behavior that made same-recipe estates rank
        // differently (2026-08-24 replay-drift root cause).
        let (kit, handle) = try await provisionGLKEstate()
        let estate = try await kit.estate(for: handle)
        let all = try await estate.allDrawers()
        let names = try await estate.resolveNodeNames(parentNodeIds: all.map(\.parentNodeId))
        let charters = all.filter { names[$0.parentNodeId]?.room == LocusKit.hintRoom }
        #expect(charters.count == LocusKit.defaultWings.count)
        let expectedIDs = Set((0..<LocusKit.defaultWings.count).map {
            LocusKit.charterDrawerID(forWingIndex: $0)
        })
        #expect(Set(charters.map(\.id)) == expectedIDs,
                "charter drawers must carry the fixed well-known IDs")
        for c in charters {
            #expect(c.filedAt == LocusKit.charterSeedDate,
                    "charter filedAt must be the fixed 2000-01-01 sentinel")
        }
    }
}
