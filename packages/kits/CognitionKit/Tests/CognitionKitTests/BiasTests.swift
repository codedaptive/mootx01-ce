import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// Bias — preference lens (category 4, SPEC § 4.2). Three honest
/// signals over the estate: REPRESENTATION (room share vs a reference,
/// signed), DISMISSAL (per-room withdrawal rate — bias against you
/// enacted), and LEARNED PREFERENCE (Bradley-Terry over confirmations
/// as endorsements and withdrawals as dismissals — what you actually
/// keep vs what merely accumulates). Read-only over the live confirm /
/// withdraw verbs, end-to-end against a real estate. Swift peer of
/// run_bias.
@Suite("BiasTests")
struct BiasTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "bias-test"))
        return (kit, handle)
    }

    /// Capture a drawer into `room`; return the minted Drawer.
    @discardableResult
    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, room: String
    ) async throws -> Drawer {
        let frame = CaptureFrame(
            content: "content",
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        return try await kit.capture(handle, frame)
    }

    // CK-BI-1: the estate over-weights philosophy and never touches
    // finance; against a balanced reference, philosophy is bias-for and
    // finance is the most-avoided bias-against.
    @Test("over-weighted room is for; never-captured room is most avoided")
    func forAndAgainstRepresentation() async throws {
        let (kit, handle) = try await openEstate()
        var philosophyNodeId = ""
        for _ in 0..<4 {
            let d = try await capture(kit, handle, room: "philosophy")
            philosophyNodeId = d.parentNodeId
        }
        let cookingDrawer = try await capture(kit, handle, room: "cooking")
        let cookingNodeId = cookingDrawer.parentNodeId

        // Reference uses parentNodeIds for captured rooms; "never-captured-node"
        // has no matching parentNodeId and appears as bias-against.
        let report = try await Bias.run(
            kit: kit, handle: handle,
            reference: [(philosophyNodeId, 1.0), (cookingNodeId, 1.0), ("never-captured-node", 1.0)])

        #expect(report.biasedFor.contains { $0.label == philosophyNodeId },
                "over-weighted → for")
        #expect(report.biasedAgainst.contains { $0.label == "never-captured-node" },
                "never-captured → against")
        #expect(report.biasedAgainst.last?.label == "never-captured-node",
                "never-captured is the most avoided (last by bias)")
    }

    // CK-BI-2: withdrawing memories from a room registers a dismissal
    // rate — "bias against" you enacted (the live withdraw verb).
    @Test("withdrawal registers as dismissal")
    func withdrawalIsDismissal() async throws {
        let (kit, handle) = try await openEstate()
        let firstDrawer = try await capture(kit, handle, room: "doubts")
        let doubtsNodeId = firstDrawer.parentNodeId
        _ = try await capture(kit, handle, room: "doubts")
        _ = try await capture(kit, handle, room: "doubts")
        try await kit.withdraw(handle, WithdrawFrame(rowID: firstDrawer.id, reason: "reconsidered"))

        let report = try await Bias.run(
            kit: kit, handle: handle, reference: [(doubtsNodeId, 1.0)])

        let doubts = try #require(report.dismissal.first { $0.nodeId == doubtsNodeId })
        #expect(doubts.rate > 0, "dismissal rate is positive")
    }

    // CK-BI-3: learned preference reads real curation choices —
    // confirming a room's memories makes it preferred, withdrawing
    // another's makes it disfavored, and an untouched room sits at
    // neutral between them.
    @Test("confirm and withdraw drive learned preference")
    func confirmAndWithdrawDriveLearnedPreference() async throws {
        let (kit, handle) = try await openEstate()
        // "kept": captured then confirmed (endorsed).
        var keptNodeId = ""
        for _ in 0..<3 {
            let d = try await capture(kit, handle, room: "kept")
            keptNodeId = d.parentNodeId
            try await kit.mutate(handle, MutateFrame(rowID: d.id, kind: .confirm))
        }
        // "dropped": captured then withdrawn (dismissed).
        var droppedNodeId = ""
        for _ in 0..<3 {
            let d = try await capture(kit, handle, room: "dropped")
            droppedNodeId = d.parentNodeId
            try await kit.withdraw(handle, WithdrawFrame(rowID: d.id, reason: "reconsidered"))
        }
        // "untouched": captured and left alone (no curation signal).
        let untouchedDrawer = try await capture(kit, handle, room: "untouched")
        let untouchedNodeId = untouchedDrawer.parentNodeId
        _ = try await capture(kit, handle, room: "untouched")

        let report = try await Bias.run(
            kit: kit, handle: handle, reference: [(keptNodeId, 1.0)])

        // Endorsed leads, dismissed trails, neutral sits between.
        #expect(report.learned.map(\.label) == [keptNodeId, untouchedNodeId, droppedNodeId],
                "curation orders preference")

        let kept = try #require(report.learned.first { $0.label == keptNodeId })
        let dropped = try #require(report.learned.first { $0.label == droppedNodeId })
        let untouched = try #require(report.learned.first { $0.label == untouchedNodeId })
        #expect(kept.strength > 0, "confirmed room preferred")
        #expect(dropped.strength < 0, "withdrawn room disfavored")
        #expect(abs(untouched.strength) < 1e-6, "uncurated room neutral")
        // The raw curation counts round-tripped through the recall frames.
        #expect(kept.endorsements == 3)
        #expect(dropped.dismissals == 3)
    }
}
