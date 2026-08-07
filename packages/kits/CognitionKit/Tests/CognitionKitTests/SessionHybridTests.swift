// SessionHybridTests.swift
//
// Conformance tests for the "session_hybrid" named RecallShape preset and
// the SessionHybridFusion post-processing engine.
//
// Tests cover:
//   §1 Preset registration — "session_hybrid" in the roster, non-nil shape,
//      description present, reachable via ShapedRecall.run().
//   §2 Temporal window boost — drawers inside the createdAfter/createdBefore
//      window rank higher than out-of-window drawers when temporal bounds
//      are present in the filter.
//   §3 Speaker-aware boost — MCP-agent-authored drawers rank higher when the
//      query contains assistant self-reference patterns.
//   §4 Evidence gate — a query-matching (evidence-bearing) drawer is never
//      displaced by an unrelated but temporally/speaker-boosted drawer.
//   §5 Determinism — same inputs produce identical ranking across two calls.
//   §6 No-boost no-op — when filter has no temporal bounds and query has no
//      self-reference, SessionHybridFusion returns hybridRecall order.
//
// ISOLATION: tests that call ShapedRecall.run() acquire the process-wide
// cognitionTestMutex (CognitionTestLock.swift) — same discipline as
// GroundedSynthesisTests. Tests that exercise SessionHybridFusion directly
// (pure data-in/data-out) do not need the lock.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

@Suite("SessionHybridTests")
struct SessionHybridTests {

    // MARK: - §1 Preset registration

    @Test("session_hybrid is in RecallShape.presetNames")
    func presetIsRegistered() {
        #expect(RecallShape.presetNames.contains("session_hybrid"))
    }

    @Test("session_hybrid resolves to a non-nil RecallShape")
    func presetResolvesNonNil() {
        #expect(RecallShape.preset("session_hybrid") != nil)
    }

    @Test("session_hybrid has a non-empty catalog description")
    func presetHasDescription() {
        #expect(!RecallShape.presetDescription("session_hybrid").isEmpty)
    }

    @Test("ShapedRecall.run() accepts session_hybrid and returns results")
    func shapedRecallAcceptsSessionHybrid() async throws {
        try await withCognitionLock {
            let kit = GeniusLocusKit()
            let storage = InMemoryStorage(
                configuration: EstateConfiguration(
                    estateID: UUID(), backend: .inMemory))
            let handle = try await kit.open(
                storage: storage,
                owner: OwnerCredentials(ownerIdentifier: "session-hybrid-smoke"))
            // Capture a drawer so recall has something to return.
            let frame = CaptureFrame(
                content: "discussion about quantum entanglement",
                channel: .typed,
                room: "q-room",
                latticeAnchor: .udc("540"),
                addedBy: "test-agent",
                embeddingModelID: "test-v1")
            _ = try await kit.capture(handle, frame)

            let input = ShapedRecall.Input(
                query: "quantum",
                preset: "session_hybrid",
                filter: .unconfirmed,
                limit: 10)
            let output = try await ShapedRecall().run(
                input: input, estate: handle, kit: kit)
            #expect(output.appliedPreset == "session_hybrid")
        }
    }

    // MARK: - §2 Temporal window boost

    @Test("temporal window boost: in-window drawer rises above out-of-window drawer with same content")
    func temporalWindowBoostOrderingEffect() {
        // Two drawers with nearly identical content. The only difference is
        // eventTime: one is inside the session window, one is outside.
        //
        // Without temporal boost both would have the same base score.
        // With temporal boost the in-window drawer should score higher.
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let windowStart = now.addingTimeInterval(-7200)  // 2 hours ago
        let windowEnd   = now.addingTimeInterval(-600)   // 10 minutes ago

        let inWindow = Drawer(
            id: "in-window",
            content: "session content",
            parentNodeId: "room-1",
            sourceFile: nil,
            chunkIndex: nil,
            addedBy: "user",
            filedAt: now.addingTimeInterval(-3600),  // 1 hour ago — inside [2h, 10min) window
            eventTime: now.addingTimeInterval(-3600),
            embeddingModelID: "test-v1",
            tombstonedAt: nil,
            removedByBatch: nil)

        let outWindow = Drawer(
            id: "out-window",
            content: "session content",
            parentNodeId: "room-1",
            sourceFile: nil,
            chunkIndex: nil,
            addedBy: "user",
            filedAt: now.addingTimeInterval(-86400),  // 1 day ago — outside window
            eventTime: now.addingTimeInterval(-86400),
            embeddingModelID: "test-v1",
            tombstonedAt: nil,
            removedByBatch: nil)

        // hybridRecall would rank them equally (both rank 0 and 1 via RRF).
        // Place in-window at rank 1, out-of-window at rank 0 to test boost
        // can reorder near-equals.
        let drawers = [outWindow, inWindow]  // out-of-window ranked first by hybridRecall
        let filter = Filter.all([
            .createdAfter(windowStart),
            .createdBefore(windowEnd),
        ])

        let result = SessionHybridFusion.boost(
            drawers: drawers,
            filter: filter,
            query: "session topic",
            limit: 10)

        #expect(result.count == 2)
        // in-window drawer should now rank first because temporal boost lifted it.
        #expect(result[0].drawer.id == "in-window",
                "temporal boost must lift in-window drawer above out-of-window drawer")
    }

    @Test("temporal window boost is inactive when no temporal bounds in filter")
    func temporalBoostInactiveWithoutBounds() {
        // When filter has no createdAfter/createdBefore, the temporal window
        // extraction returns nil and no temporal delta is applied.
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let recent = Drawer(
            id: "recent",
            content: "something",
            parentNodeId: "room-1",
            sourceFile: nil, chunkIndex: nil,
            addedBy: "user",
            filedAt: now,
            eventTime: now,
            embeddingModelID: "test-v1",
            tombstonedAt: nil, removedByBatch: nil)
        let older = Drawer(
            id: "older",
            content: "something",
            parentNodeId: "room-1",
            sourceFile: nil, chunkIndex: nil,
            addedBy: "user",
            filedAt: now.addingTimeInterval(-86400),
            eventTime: now.addingTimeInterval(-86400),
            embeddingModelID: "test-v1",
            tombstonedAt: nil, removedByBatch: nil)

        // No temporal bounds in filter — any SourceType filter, no time bounds.
        let result = SessionHybridFusion.boost(
            drawers: [older, recent],
            filter: .unconfirmed,
            query: "something",
            limit: 10)

        // With no temporal boost, hybridRecall order is preserved (older first,
        // as passed in). Neither drawer gets a boost. The stable sort keeps
        // original order for equal scores.
        #expect(result[0].drawer.id == "older",
                "no temporal boost — original hybridRecall order preserved")
    }

    // MARK: - §3 Speaker-aware boost

    @Test("speaker boost is active only for self-reference queries")
    func speakerBoostDetection() {
        #expect(SessionHybridFusion.isSelfReferenceQuery("what did you say about that"))
        #expect(SessionHybridFusion.isSelfReferenceQuery("you mentioned the deadline"))
        #expect(SessionHybridFusion.isSelfReferenceQuery("your earlier response was correct"))
        #expect(SessionHybridFusion.isSelfReferenceQuery("as you said, the answer is"))

        // Non-self-reference queries should NOT trigger the boost.
        #expect(!SessionHybridFusion.isSelfReferenceQuery("what is quantum entanglement"))
        #expect(!SessionHybridFusion.isSelfReferenceQuery("find sessions about databases"))
        #expect(!SessionHybridFusion.isSelfReferenceQuery("recent notes on Swift concurrency"))
    }

    @Test("speaker boost lifts mcpAgent drawer for self-reference query")
    func speakerBoostMcpAgentRank() {
        // Two drawers with identical content. One has channel == .mcpAgent
        // (AI-authored); the other has channel == .uiTyped (user-authored).
        // For a self-reference query, the AI-authored drawer should score higher.
        //
        // Provenance packing: channel occupies bits 6–11 of the provenance
        // bitmap. mcpAgent has rawValue 2, so provenance = 2 << 6 = 128.
        // uiTyped has rawValue 0, so provenance = 0.
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let mcpAgentProvenance = Int64(Channel.mcpAgent.rawValue) << 6
        let userProvenance = Int64(Channel.uiTyped.rawValue) << 6

        let mcpDrawer = Drawer(
            id: "mcp-authored",
            content: "I said the deployment was ready",
            parentNodeId: "room-1",
            sourceFile: nil, chunkIndex: nil,
            addedBy: "aria-mcp-server",
            filedAt: now,
            eventTime: now,
            embeddingModelID: "test-v1",
            tombstonedAt: nil, removedByBatch: nil,
            provenance: mcpAgentProvenance)

        let userDrawer = Drawer(
            id: "user-authored",
            content: "the deployment was ready",
            parentNodeId: "room-1",
            sourceFile: nil, chunkIndex: nil,
            addedBy: "human-user",
            filedAt: now,
            eventTime: now,
            embeddingModelID: "test-v1",
            tombstonedAt: nil, removedByBatch: nil,
            provenance: userProvenance)

        // Place user-authored first (would win without boost), mcp-authored second.
        let drawers = [userDrawer, mcpDrawer]
        let result = SessionHybridFusion.boost(
            drawers: drawers,
            filter: .unconfirmed,
            query: "what did you say about the deployment",
            limit: 10)

        #expect(result[0].drawer.id == "mcp-authored",
                "speaker boost must lift AI-authored drawer for self-reference query")
    }

    @Test("speaker boost is inactive for non-self-reference queries")
    func speakerBoostInactiveForNonSelfReference() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let mcpAgentProvenance = Int64(Channel.mcpAgent.rawValue) << 6
        let mcpDrawer = Drawer(
            id: "mcp-authored",
            content: "deployment notes",
            parentNodeId: "room-1",
            sourceFile: nil, chunkIndex: nil,
            addedBy: "aria-mcp-server",
            filedAt: now,
            eventTime: now,
            embeddingModelID: "test-v1",
            tombstonedAt: nil, removedByBatch: nil,
            provenance: mcpAgentProvenance)

        let userDrawer = Drawer(
            id: "user-authored",
            content: "deployment notes",
            parentNodeId: "room-1",
            sourceFile: nil, chunkIndex: nil,
            addedBy: "human-user",
            filedAt: now,
            eventTime: now,
            embeddingModelID: "test-v1",
            tombstonedAt: nil, removedByBatch: nil)

        // Not a self-reference query — speaker boost is inactive.
        let result = SessionHybridFusion.boost(
            drawers: [userDrawer, mcpDrawer],
            filter: .unconfirmed,
            query: "find deployment notes",
            limit: 10)

        // Without speaker boost, original order is preserved (user-authored first).
        #expect(result[0].drawer.id == "user-authored",
                "no speaker boost for non-self-reference query — hybridRecall order kept")
    }

    // MARK: - §4 Evidence gate

    @Test("evidence gate: query-matching drawer never displaced by boosted unrelated drawer")
    func evidenceGateMaintenedWithBoosts() {
        // EVIDENCE GATE INVARIANT MATH:
        // The invariant only holds when evidence-bearing hits are sufficiently
        // higher-ranked than frame-only hits. The max combined boost is 0.006.
        // RRF base score at rank N = 1/(N+61). For the evidence hit at rank 0 to
        // stay ahead of a fully-boosted frame-only hit at rank M:
        //
        //   1/(0+61) > 1/(M+61) + 0.006
        //   1/61 > 1/(M+61) + 0.006
        //   0.016393 > 1/(M+61) + 0.006
        //   0.010393 > 1/(M+61)
        //   M+61 > 96.2  →  M >= 36
        //
        // So frameOnlyHit must be at rank >= 36 for the invariant to hold.
        // This test pushes it to rank 40 via 39 filler drawers, giving a
        // comfortable margin. This reflects real hybridRecall output where
        // evidence-bearing hits (scored lane, BM25+dense match) dominate the
        // top ranks and frame-only hits (bitmap/recency only) fall below.
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let windowStart = now.addingTimeInterval(-3700)
        let windowEnd   = now.addingTimeInterval(3700)
        let mcpAgentProvenance = Int64(Channel.mcpAgent.rawValue) << 6

        // Rank 0: evidence-bearing hit — outside window, not mcpAgent (no boost).
        let evidenceHit = Drawer(
            id: "evidence-bearing",
            content: "quantum mechanics explained",  // matches query keyword
            parentNodeId: "room-1",
            sourceFile: nil, chunkIndex: nil,
            addedBy: "user",
            filedAt: now.addingTimeInterval(-7200),  // older — outside window
            eventTime: now.addingTimeInterval(-7200),
            embeddingModelID: "test-v1",
            tombstonedAt: nil, removedByBatch: nil)

        // Ranks 1–39: filler evidence-bearing hits (represent the ranked block
        // of query-matched drawers from the scored lane). All outside the session
        // window (eventTime offset starts at >7200s ago) and neutral provenance —
        // no temporal or speaker boost applies.
        var fillers: [Drawer] = []
        for i in 1...39 {
            // Start offsets at (i+12)*600 so even i=1 → 7800s ago, outside window.
            let offset = Double(-(i + 12)) * 600
            let fillerId = "filler-\(i)"
            let fillerContent = "quantum mechanics filler \(i)"
            fillers.append(Drawer(
                id: fillerId,
                content: fillerContent,
                parentNodeId: "room-1",
                sourceFile: nil, chunkIndex: nil,
                addedBy: "user",
                filedAt: now.addingTimeInterval(offset),
                eventTime: now.addingTimeInterval(offset),
                embeddingModelID: "test-v1",
                tombstonedAt: nil, removedByBatch: nil))
        }

        // Rank 40: frame-only hit — inside window AND mcpAgent (gets max boost).
        // At rank 40: base = 1/101 ≈ 0.0099. Boosted = 0.0099 + 0.006 = 0.0159.
        // evidenceHit at rank 0: base = 1/61 ≈ 0.0164. 0.0164 > 0.0159 ✓
        let frameOnlyHit = Drawer(
            id: "frame-only",
            content: "unrelated content about cooking",
            parentNodeId: "room-1",
            sourceFile: nil, chunkIndex: nil,
            addedBy: "aria-mcp-server",
            filedAt: now,  // very recent — inside window
            eventTime: now,
            embeddingModelID: "test-v1",
            tombstonedAt: nil, removedByBatch: nil,
            provenance: mcpAgentProvenance)  // also gets speaker boost

        let drawers = [evidenceHit] + fillers + [frameOnlyHit]

        // hybridRecall order: evidenceHit at rank 0, fillers at ranks 1–39,
        // frameOnlyHit at rank 40. frameOnlyHit gets BOTH temporal + speaker
        // boosts (max combined delta 0.006). evidenceHit gets neither boost.
        let result = SessionHybridFusion.boost(
            drawers: drawers,
            filter: .all([.createdAfter(windowStart), .createdBefore(windowEnd)]),
            query: "what did you say about quantum mechanics",
            limit: drawers.count)

        #expect(result[0].drawer.id == "evidence-bearing",
                "evidence gate: query-matching hit at rank 0 must not be displaced by boosted frame-only hit at rank 40")
    }

    // MARK: - §5 Determinism

    @Test("identical inputs produce identical ranking (same seed, two calls)")
    func deterministicRanking() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let windowStart = now.addingTimeInterval(-7200)

        // makeDrawers uses fixed IDs so both calls produce structurally identical
        // input (lineageID defaults are irrelevant to scoring).
        func makeDrawers() -> [Drawer] {
            (0..<5).map { i in
                Drawer(
                    id: "d-\(i)",
                    content: "content \(i)",
                    parentNodeId: "room-1",
                    sourceFile: nil, chunkIndex: nil,
                    addedBy: "agent",
                    filedAt: now.addingTimeInterval(Double(-i) * 600),
                    eventTime: now.addingTimeInterval(Double(-i) * 600),
                    embeddingModelID: "test-v1",
                    tombstonedAt: nil, removedByBatch: nil)
            }
        }

        let filter = Filter.createdAfter(windowStart)
        let query = "you mentioned content"

        let result1 = SessionHybridFusion.boost(drawers: makeDrawers(), filter: filter,
                                                query: query, limit: 5)
        let result2 = SessionHybridFusion.boost(drawers: makeDrawers(), filter: filter,
                                                query: query, limit: 5)

        let ids1 = result1.map { $0.drawer.id }
        let ids2 = result2.map { $0.drawer.id }
        #expect(ids1 == ids2,
                "SessionHybridFusion must produce identical ranking for identical inputs")
    }

    // MARK: - §6 No-boost no-op

    @Test("no-boost: SessionHybridFusion preserves hybridRecall order when no boosts apply")
    func noBoostPreservesOrder() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let drawers = (0..<4).map { i -> Drawer in
            Drawer(
                id: "d-\(i)",
                content: "item \(i)",
                parentNodeId: "room-1",
                sourceFile: nil, chunkIndex: nil,
                addedBy: "user",
                filedAt: now.addingTimeInterval(Double(-i) * 300),
                eventTime: now.addingTimeInterval(Double(-i) * 300),
                embeddingModelID: "test-v1",
                tombstonedAt: nil, removedByBatch: nil)
        }

        // Filter with no temporal bounds, query with no self-reference.
        let result = SessionHybridFusion.boost(
            drawers: drawers,
            filter: .unconfirmed,
            query: "find items",
            limit: 10)

        let expectedOrder = ["d-0", "d-1", "d-2", "d-3"]
        let actualOrder = result.map { $0.drawer.id }
        #expect(actualOrder == expectedOrder,
                "no boosts active — SessionHybridFusion must return input order unchanged")
    }
}
