// RecallPruningTests.swift
//
// Tests for fingerprint pruning (spec section 7.9.4 step 1): the prune
// predicates on BitmapEvaluator and the container-aware recall path.
// The integration test proves the prune is sound and equivalent, it
// drops a container that cannot match yet returns exactly the rows a
// full scan would.

import Foundation
import Testing
@testable import LocusKit

@Suite("RecallPruningTests")
struct RecallPruningTests {

    // MARK: - Prune predicates

    @Test("chainHasPrunableFilter is true only when a set-bit filter is present")
    func chainPrunability() {
        #expect(BitmapEvaluator.chainHasPrunableFilter([.hasFeatureFlag(.hasVoice)]))
        #expect(BitmapEvaluator.chainHasPrunableFilter([.all([.hasFeatureFlag(.hasImage)])]))
        #expect(!BitmapEvaluator.chainHasPrunableFilter([.currentlyBelieve, .trustworthy]))
    }

    @Test("containerSurvives prunes only when a required bit is absent")
    func containerSurvival() {
        let withVoice = ContainerFingerprint(adjective: 0, operational: 1 << 13, provenance: 0)
        let withImage = ContainerFingerprint(adjective: 0, operational: 1 << 14, provenance: 0)

        // Set-bit present, survives; absent, pruned.
        #expect(BitmapEvaluator.containerSurvives(chain: [.hasFeatureFlag(.hasVoice)], fingerprint: withVoice))
        #expect(!BitmapEvaluator.containerSurvives(chain: [.hasFeatureFlag(.hasVoice)], fingerprint: withImage))

        // Threshold filters never prune.
        #expect(BitmapEvaluator.containerSurvives(chain: [.currentlyBelieve], fingerprint: withImage))

        // Conjunction: a missing conjunct excludes.
        #expect(!BitmapEvaluator.containerSurvives(
            chain: [.all([.hasFeatureFlag(.hasVoice), .hasFeatureFlag(.hasImage)])],
            fingerprint: withVoice))

        // Disjunction: one satisfiable disjunct survives.
        #expect(BitmapEvaluator.containerSurvives(
            chain: [.any([.hasFeatureFlag(.hasVoice), .hasFeatureFlag(.hasImage)])],
            fingerprint: withVoice))

        // Negation gives no sound exclusion, so it survives.
        #expect(BitmapEvaluator.containerSurvives(
            chain: [.not(.hasFeatureFlag(.hasVoice))], fingerprint: withImage))
    }

    // MARK: - Container-aware recall

    private func drawer(id: String, parentNodeId: String, op: Int64) -> Drawer {
        let content = "c-" + id
        // provenance confirmation = userConfirmed (raw 1 at bits 18-23
        // per cookbook §2.5) for explicit confirmation-axis checks;
        // adjective 0 is active and trustworthy.
        return Drawer(id: TestStorage.tid(id), content: content, parentNodeId: parentNodeId, addedBy: "t",
                      filedAt: Date(timeIntervalSince1970: 1_700_000_000),
                      embeddingModelID: "m",
                      provenance: Int64(1) << 18,
                      adjectiveBitmap: 0,
                      operationalBitmap: op,
                      lineageID: UUID())
    }

    @Test("Recall prunes a non-matching container and returns the equivalent rows")
    func recallPrunesAndStaysEquivalent() async throws {
        let url = TestStorage.tempURL()
        defer { TestStorage.cleanup(url) }
        let storage = TestStorage.sqlite(url)

        // Seed the manifest, then add rows through a bare store so the
        // operational flag bits are set directly.
        _ = try await Estate.create(storage: storage,
                                    owner: OwnerCredentials(ownerIdentifier: "o"))
        // Seed node tree: root → wing "w" → rooms "r1", "r2"
        let nodeStore = NodeStore(storage: storage)
        let root = try await nodeStore.createRoot(displayName: "Estate", now: Date())
        let wing = try await nodeStore.createNode(displayName: "w", parentId: root.id, now: Date())
        let room1 = try await nodeStore.createNode(displayName: "r1", parentId: wing.id, now: Date())
        let room2 = try await nodeStore.createNode(displayName: "r2", parentId: wing.id, now: Date())
        let drawerStore = try await DrawerStore(storage: storage)
        try await drawerStore.addDrawer(drawer(id: "d1", parentNodeId: room1.id.uuidString, op: 1 << 13))   // hasVoice
        try await drawerStore.addDrawer(drawer(id: "d2", parentNodeId: room2.id.uuidString, op: 1 << 14))  // hasImage only

        // Reopen so the backfill covers both containers.
        let estate = try await Estate.open(storage: storage,
                                           owner: OwnerCredentials(ownerIdentifier: "o"))

        // Room r2's OR lacks the hasVoice bit, so it is pruned whole;
        // d1 is the only match.
        let frame = RecallFrame(filterChain: [.hasFeatureFlag(.hasVoice)])
        let stream = await estate.recall(frame)
        var ids: [String] = []
        for await page in stream { ids.append(contentsOf: page.rows.map(\.id)) }

        #expect(ids == [TestStorage.tid("d1")])
    }
}
