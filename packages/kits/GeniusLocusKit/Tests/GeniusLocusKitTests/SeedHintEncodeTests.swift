// SeedHintEncodeTests.swift
//
// DISTILL_SEED_STALL regression coverage: the seven seeded AI_Charter_Hint
// wing drawers go through the encode path INLINE (seedDefaultWings indexes
// and distills them in place, the same transform a queued drawer gets at
// drain), so:
//
//   • the "distillation" drain lane reaches ZERO on a fresh estate
//     (the lane previously pinned at pending:7 forever — the benchmark
//     drain-barrier stall, probe 1 2026-07-30);
//   • re-running seedDefaultWings on an already-converged estate does
//     NOTHING — no queue work, no re-distillation (idempotent open);
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
import VectorKit
import SubstrateTypes
@testable import SubstrateML
@testable import GeniusLocusKit

@Suite("Seeded hint encode routing (DISTILL_SEED_STALL)")
struct SeedHintEncodeTests {

    /// Provision a GLK estate (mounts Corpus + VectorStore + drain workers).
    /// Same fixture as DistillationDrainStageTests.
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

    /// The distillation drain-lane pending count.
    private func distillationPending(
        _ kit: GeniusLocusKit, _ handle: EstateHandle
    ) async throws -> Int {
        try await kit.drainStatuses(handle)
            .first { $0.name == "distillation" }?.pending ?? -1
    }

    @Test("fresh estate + drain: the distillation lane reaches zero (stall regression)")
    func freshEstateDrainsToZero() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        // Seeding settles its hints inline, so the estate OPENS settled —
        // the lane is already at zero before anything drives the queue.
        #expect(try await distillationPending(kit, handle) == 0,
                "seeding settles inline: the lane must be zero at open, before any drain")
        // Draining changes nothing (there is no seed batch to drain) and
        // must leave the lane settled.
        try await kit.awaitEncodeDrain(for: handle)
        #expect(try await distillationPending(kit, handle) == 0,
                "the 7 seeded hints must stay distilled — a non-zero count is the probe-1 stall")
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
        #expect(try await distillationPending(kit, handle) == 0)

        // Simulate the estate being re-opened: the open path calls
        // seedDefaultWings again. All 7 wings exist and all 7 hints carry a
        // current representation (bit 19 set, current pipeline version), so
        // the enqueue predicate must admit ZERO drawers.
        try await kit.seedDefaultWings(for: handle, now: Date(timeIntervalSince1970: 1_800_000_000))
        let corpus = try #require(await kit.corpusKits[handle])
        let depth = try await corpus.ingestQueueDepth()
        #expect(depth.pending == 0 && depth.inFlight == 0,
                "re-seed must not re-enqueue distilled hints (got \(depth))")
        #expect(try await distillationPending(kit, handle) == 0)
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
}
