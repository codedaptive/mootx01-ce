import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// Drift — surprise lens (category 5, SPEC § 4.2). Recall a set, split
/// it by capture time into a before-window and an after-window, build
/// each window's distribution over rooms, and measure how far the
/// after-window has drifted (Jensen-Shannon / KL via NeuronKit
/// `drift`). "Your filing shifted across April." Read-only. The split
/// instant is taken between two capture groups, so the windows are real
/// capture-time windows — no sleeps. Swift peer of run_drift.
@Suite("Drift recipe (CognitionKit)")
struct DriftRecipeTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "drift-recipe-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, room: String
    ) async throws {
        let frame = CaptureFrame(
            content: "content",
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, frame)
    }

    private var unconfirmed: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.userConfirmed])
    }

    // CK-DR-1: filing moved rooms across the split — early drawers in
    // "study", later in "work" — registers high drift.
    @Test("a room shift across the split registers high drift")
    func roomShiftRegistersDrift() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<3 { try await capture(kit, handle, room: "study") }
        let splitAt = Date()   // between the two capture groups
        for _ in 0..<3 { try await capture(kit, handle, room: "work") }

        let out = try await Drift.run(
            kit: kit, handle: handle, frame: unconfirmed, splitAt: splitAt)

        #expect(out.beforeCount == 3)
        #expect(out.afterCount == 3)
        #expect(out.drift.jensenShannon > 0.5, "a full room shift is high drift")
    }

    // CK-DR-2: same room across the split — no drift.
    @Test("stable filing across the split has no drift")
    func stableFilingNoDrift() async throws {
        let (kit, handle) = try await openEstate()
        try await capture(kit, handle, room: "study")
        let splitAt = Date()
        try await capture(kit, handle, room: "study")

        let out = try await Drift.run(
            kit: kit, handle: handle, frame: unconfirmed, splitAt: splitAt)

        #expect(abs(out.drift.jensenShannon) < 1e-5, "stable filing ⇒ no drift")
    }

    // CK-DR-3: a window with no drawers yields zero drift (guarded —
    // nothing to compare).
    @Test("an empty window is guarded to zero drift")
    func emptyWindowIsGuarded() async throws {
        let (kit, handle) = try await openEstate()
        try await capture(kit, handle, room: "study")
        let futureSplit = Date().addingTimeInterval(3600)   // everything is "before"

        let out = try await Drift.run(
            kit: kit, handle: handle, frame: unconfirmed, splitAt: futureSplit)

        #expect(out.beforeCount == 1)
        #expect(out.afterCount == 0)
        #expect(out.drift.jensenShannon == 0)
        #expect(out.drift.klDivergence == 0)
    }
}
