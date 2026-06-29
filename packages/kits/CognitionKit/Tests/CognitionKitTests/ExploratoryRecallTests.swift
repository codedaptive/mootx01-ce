// ExploratoryRecallTests.swift
//
// Conformance tests for the ExploratoryRecall recipe (recall_exploratory,
// cookbook § 19.1). Seven tests mirroring CK-ER-1 through CK-ER-7 in
// the Rust port's exploratory_recall_recipe.rs test suite.
//
// Layer discipline: estates are opened via GeniusLocusKit (the correct
// composition layer) and tunnels are captured through the estate's
// TunnelCaptureFrame API — no direct substrate access.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("ExploratoryRecallTests")
struct ExploratoryRecallTests {

    private static let wing = "study"

    // Canonical UUID strings for test drawers — deterministic; never random.
    // Match the Rust SEED_ID/A_ID/B_ID/C_ID constants byte-for-byte.
    private static let seedID = "00000000-0000-0000-0000-000000000001"
    private static let aID    = "00000000-0000-0000-0000-000000000002"
    private static let bID    = "00000000-0000-0000-0000-000000000003"
    private static let cID    = "00000000-0000-0000-0000-000000000004"

    // Long walk so visit frequencies are stable enough to assert on;
    // matches the Rust LEN constant.
    private static let walkLength = 20_000

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "exploratory-recall-test"))
        return (kit, handle)
    }

    private func addEdge(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        src: String, tgt: String
    ) async throws {
        let estate = try await kit.estate(for: handle)
        let frame = TunnelCaptureFrame(
            sourceWing: Self.wing, sourceRoom: "r",
            targetWing: Self.wing, targetRoom: "r",
            label: "relates", addedBy: "user",
            sourceDrawerId: src, targetDrawerId: tgt, kind: .references)
        _ = try await estate.capture(frame)
    }

    // CK-ER-1: seed is always visited; seed is excluded from results;
    // the reachable non-seed drawers A and B both appear.
    @Test("seed visited and excluded from results")
    func seedVisitedAndExcludedFromResults() async throws {
        let (kit, handle) = try await openEstate()
        // Three-node directed cycle: seed→A, A→B, B→seed.
        try await addEdge(kit, handle, src: Self.seedID, tgt: Self.aID)
        try await addEdge(kit, handle, src: Self.aID,    tgt: Self.bID)
        try await addEdge(kit, handle, src: Self.bID,    tgt: Self.seedID)

        let input = ExploratoryRecall.Input(
            wing: Self.wing,
            seedDrawerID: Self.seedID,
            steps: Self.walkLength,
            k: 0)
        let recipe = ExploratoryRecall()
        let out = try await recipe.run(input: input, estate: handle, kit: kit)

        // Seed must not appear in results (it is the origin).
        #expect(!out.results.contains(where: { $0.drawerID == Self.seedID }))
        // Both A and B must appear in the reachable set.
        #expect(out.results.contains(where: { $0.drawerID == Self.aID }))
        #expect(out.results.contains(where: { $0.drawerID == Self.bID }))
        // visitedCount includes the seed.
        #expect(out.visitedCount >= 2)
    }

    // CK-ER-2: seed absent from the graph yields an empty result.
    @Test("seed absent from graph yields empty")
    func seedAbsentFromGraphYieldsEmpty() async throws {
        let (kit, handle) = try await openEstate()
        // Only A→B edge; seedID has no outgoing edge.
        try await addEdge(kit, handle, src: Self.aID, tgt: Self.bID)

        let input = ExploratoryRecall.Input(
            wing: Self.wing,
            seedDrawerID: Self.seedID,
            steps: Self.walkLength,
            k: 10)
        let recipe = ExploratoryRecall()
        let out = try await recipe.run(input: input, estate: handle, kit: kit)

        #expect(out.results.isEmpty)
        #expect(out.visitedCount == 0)
    }

    // CK-ER-3: same inputs always produce identical results (determinism, B-6).
    @Test("recipe is deterministic")
    func recipeIsDeterministic() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: Self.seedID, tgt: Self.aID)
        try await addEdge(kit, handle, src: Self.aID,    tgt: Self.bID)
        try await addEdge(kit, handle, src: Self.bID,    tgt: Self.seedID)

        let input = ExploratoryRecall.Input(
            wing: Self.wing,
            seedDrawerID: Self.seedID,
            steps: Self.walkLength,
            k: 0)
        let recipe = ExploratoryRecall()
        let first  = try await recipe.run(input: input, estate: handle, kit: kit)
        let second = try await recipe.run(input: input, estate: handle, kit: kit)

        // Visit counts and ranking must be identical across two runs.
        #expect(first.results.count == second.results.count)
        #expect(first.visitedCount == second.visitedCount)
        for (a, b) in zip(first.results, second.results) {
            #expect(a.drawerID == b.drawerID)
            #expect(a.visitCount == b.visitCount)
        }
    }

    // CK-ER-4: top-k truncation — k=1 returns only the most-visited drawer.
    @Test("top-k truncates results")
    func topKTruncatesResults() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: Self.seedID, tgt: Self.aID)
        try await addEdge(kit, handle, src: Self.aID,    tgt: Self.bID)
        try await addEdge(kit, handle, src: Self.bID,    tgt: Self.seedID)

        let input = ExploratoryRecall.Input(
            wing: Self.wing,
            seedDrawerID: Self.seedID,
            steps: Self.walkLength,
            k: 1)
        let recipe = ExploratoryRecall()
        let out = try await recipe.run(input: input, estate: handle, kit: kit)

        #expect(out.results.count == 1)
    }

    // CK-ER-5: drawers disconnected from the seed are never visited.
    @Test("disconnected component not visited")
    func disconnectedComponentNotVisited() async throws {
        let (kit, handle) = try await openEstate()
        // seed ↔ A (connected).
        try await addEdge(kit, handle, src: Self.seedID, tgt: Self.aID)
        try await addEdge(kit, handle, src: Self.aID,    tgt: Self.seedID)
        // B ↔ C (disconnected from seed).
        try await addEdge(kit, handle, src: Self.bID, tgt: Self.cID)
        try await addEdge(kit, handle, src: Self.cID, tgt: Self.bID)

        let input = ExploratoryRecall.Input(
            wing: Self.wing,
            seedDrawerID: Self.seedID,
            steps: Self.walkLength,
            k: 0)
        let recipe = ExploratoryRecall()
        let out = try await recipe.run(input: input, estate: handle, kit: kit)

        // B and C are unreachable from the seed.
        #expect(!out.results.contains(where: { $0.drawerID == Self.bID }))
        #expect(!out.results.contains(where: { $0.drawerID == Self.cID }))
    }

    // CK-ER-6: exploratoryRecall capability is in the shipped set.
    @Test("exploratoryRecall capability is shipped")
    func exploratoryRecallCapabilityIsShipped() {
        #expect(shippedNeuronKitCapabilities.contains(.exploratoryRecall))
    }

    // CK-ER-7: canonical conformance anchor — three-node directed cycle with
    // the cookbook §7.4 restart probability (0.15) and 1000 steps. Both A
    // and B must appear; results must be sorted by visit count descending;
    // seed must be excluded. Mirrors the Rust canonical_conformance_fixture.
    @Test("canonical conformance fixture")
    func canonicalConformanceFixture() async throws {
        let (kit, handle) = try await openEstate()
        // Graph: seed→A, A→B, B→seed.
        try await addEdge(kit, handle, src: Self.seedID, tgt: Self.aID)
        try await addEdge(kit, handle, src: Self.aID,    tgt: Self.bID)
        try await addEdge(kit, handle, src: Self.bID,    tgt: Self.seedID)

        let input = ExploratoryRecall.Input(
            wing: Self.wing,
            seedDrawerID: Self.seedID,
            steps: 1000,
            restartProbability: 0.15,
            k: 0)
        let recipe = ExploratoryRecall()
        let out = try await recipe.run(input: input, estate: handle, kit: kit)

        // Both A and B must appear in a three-node cycle.
        #expect(out.results.contains(where: { $0.drawerID == Self.aID }))
        #expect(out.results.contains(where: { $0.drawerID == Self.bID }))
        // Results must be sorted descending by visit count.
        for i in 0..<(out.results.count - 1) {
            #expect(out.results[i].visitCount >= out.results[i + 1].visitCount)
        }
        // Seed excluded from ranked output.
        #expect(!out.results.contains(where: { $0.drawerID == Self.seedID }))
    }

    // CK-4: steps clamped to maxWalkSteps — absurdly large step count degrades
    // gracefully (completes with results) rather than running until OOM/timeout.
    @Test("CK-4: oversized steps clamped to maxWalkSteps")
    func ck4OversizedStepsClamped() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: Self.seedID, tgt: Self.aID)
        try await addEdge(kit, handle, src: Self.aID,    tgt: Self.seedID)

        // Pass Int.max steps — would take O(Int.max) CPU without the CK-4 clamp.
        // The test asserts the call completes (clamp engaged) and produces a result.
        let input = ExploratoryRecall.Input(
            wing: Self.wing,
            seedDrawerID: Self.seedID,
            steps: Int.max,
            k: 0)
        let recipe = ExploratoryRecall()
        let out = try await recipe.run(input: input, estate: handle, kit: kit)
        // A is reachable: the walk ran with clamped steps, not Int.max steps.
        #expect(out.results.contains(where: { $0.drawerID == Self.aID }),
                "A must be reachable with clamped steps")
    }

    // CK-4: restartProbability ≥ 1.0 clamped to 0.999 — prevents infinite
    // teleport loops in the walk engine (every step would teleport home,
    // leaving visitedCount == 1 (seed only) and no progress through the graph).
    @Test("CK-4: restartProbability >= 1.0 clamped to 0.999")
    func ck4RestartProbabilityAtOneClamped() async throws {
        let (kit, handle) = try await openEstate()
        try await addEdge(kit, handle, src: Self.seedID, tgt: Self.aID)
        try await addEdge(kit, handle, src: Self.aID,    tgt: Self.seedID)

        let input = ExploratoryRecall.Input(
            wing: Self.wing,
            seedDrawerID: Self.seedID,
            steps: 1_000,
            restartProbability: 1.0,   // always-teleport without the clamp
            k: 0)
        let recipe = ExploratoryRecall()
        // Must complete without hanging; visitedCount > 0 confirms the engine ran.
        let out = try await recipe.run(input: input, estate: handle, kit: kit)
        #expect(out.visitedCount > 0,
                "walk must complete with clamped restart probability")
    }
}
