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

    /// Capture a drawer into `room`; return its minted id.
    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, room: String
    ) async throws -> String {
        let frame = CaptureFrame(
            content: "content",
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        return try await kit.capture(handle, frame).id
    }

    // CK-BI-1: the estate over-weights philosophy and never touches
    // finance; against a balanced reference, philosophy is bias-for and
    // finance is the most-avoided bias-against.
    @Test("over-weighted room is for; never-captured room is most avoided")
    func forAndAgainstRepresentation() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<4 { _ = try await capture(kit, handle, room: "philosophy") }
        _ = try await capture(kit, handle, room: "cooking")

        let report = try await Bias.run(
            kit: kit, handle: handle,
            reference: [("philosophy", 1.0), ("cooking", 1.0), ("finance", 1.0)])

        #expect(report.biasedFor.contains { $0.label == "philosophy" },
                "over-weighted → for")
        #expect(report.biasedAgainst.contains { $0.label == "finance" },
                "never-captured → against")
        #expect(report.biasedAgainst.last?.label == "finance",
                "finance is the most avoided (last by bias)")
    }

    // CK-BI-2: withdrawing memories from a room registers a dismissal
    // rate — "bias against" you enacted (the live withdraw verb).
    @Test("withdrawal registers as dismissal")
    func withdrawalIsDismissal() async throws {
        let (kit, handle) = try await openEstate()
        let first = try await capture(kit, handle, room: "doubts")
        _ = try await capture(kit, handle, room: "doubts")
        _ = try await capture(kit, handle, room: "doubts")
        try await kit.withdraw(handle, WithdrawFrame(rowID: first, reason: "reconsidered"))

        let report = try await Bias.run(
            kit: kit, handle: handle, reference: [("doubts", 1.0)])

        let doubts = try #require(report.dismissal.first { $0.room == "doubts" })
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
        for _ in 0..<3 {
            let id = try await capture(kit, handle, room: "kept")
            try await kit.mutate(handle, MutateFrame(rowID: id, kind: .confirm))
        }
        // "dropped": captured then withdrawn (dismissed).
        for _ in 0..<3 {
            let id = try await capture(kit, handle, room: "dropped")
            try await kit.withdraw(handle, WithdrawFrame(rowID: id, reason: "reconsidered"))
        }
        // "untouched": captured and left alone (no curation signal).
        _ = try await capture(kit, handle, room: "untouched")
        _ = try await capture(kit, handle, room: "untouched")

        let report = try await Bias.run(
            kit: kit, handle: handle, reference: [("kept", 1.0)])

        // Endorsed leads, dismissed trails, neutral sits between.
        #expect(report.learned.map(\.label) == ["kept", "untouched", "dropped"],
                "curation orders preference")

        let kept = try #require(report.learned.first { $0.label == "kept" })
        let dropped = try #require(report.learned.first { $0.label == "dropped" })
        let untouched = try #require(report.learned.first { $0.label == "untouched" })
        #expect(kept.strength > 0, "confirmed room preferred")
        #expect(dropped.strength < 0, "withdrawn room disfavored")
        // After Option B, all captured drawers are stamped Confirmation.userConfirmed
        // at capture time, so confirmedFrame now covers the same drawers as the active
        // frame — the "untouched" room's 2 drawers appear in both sets. The room is
        // no longer neutral; it registers positive endorsements equal to its capture
        // count. The ranking (kept > untouched > dropped) remains semantically correct.
        #expect(untouched.strength > 0, "uncurated room is now positive (all captures are confirmed)")
        // The raw curation counts round-tripped through the recall frames.
        #expect(kept.endorsements == 3)
        #expect(dropped.dismissals == 3)
    }
}
