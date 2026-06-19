import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// Drift — surprise lens (category 5, SPEC § 4.2). Recall a set, split
/// it by event time into a before-window and an after-window, build
/// each window's distribution over rooms, and measure how far the
/// after-window has drifted (Jensen-Shannon / KL via NeuronKit
/// `drift`). "Your filing shifted across April." Read-only. The split
/// instant is taken between two capture groups, so the windows are real
/// event-time windows — no sleeps. Swift peer of run_drift.
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

    /// Capture a drawer with an explicit event time so the drift recipe's
    /// event-time split can be tested independently of when `capture` is
    /// called (ING-01 two-clock ingest).
    private func captureWithEventTime(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        room: String, eventTime: Date
    ) async throws {
        var frame = CaptureFrame(
            content: "content",
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        frame.eventTime = eventTime
        _ = try await kit.capture(handle, frame)
    }

    private var unconfirmed: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.unconfirmed])
    }

    // CK-DR-1: filing moved rooms across the split — early drawers in
    // "study", later in "work" — registers high drift.
    //
    // Threshold note: Laplace smoothing (ε=0.5) over a 2-bin vocabulary
    // reduces the theoretical JS maximum for a 3-vs-3 disjoint partition
    // from 1.0 to ~0.457 bits. A threshold of 0.3 is meaningful (well
    // above zero drift) while remaining robust to the smoothing.
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
        #expect(out.drift.jensenShannon > 0.3, "a full room shift is high drift")
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

    // CK-DR-4: split on eventTime, not filedAt. All drawers are captured
    // "now" (filedAt = now for every drawer), but their explicit eventTimes
    // straddle splitAt. The before/after partition must follow eventTime.
    @Test("split uses eventTime, not filedAt (ING-01 two-clock)")
    func splitUsesEventTimeNotFiledAt() async throws {
        let (kit, handle) = try await openEstate()

        // Past event time — these should land in the before-window.
        let pastEvent = Date(timeIntervalSinceNow: -7_200)   // 2 hours ago
        for _ in 0..<3 {
            try await captureWithEventTime(kit, handle, room: "study", eventTime: pastEvent)
        }

        // Future event time — these should land in the after-window.
        let futureEvent = Date(timeIntervalSinceNow: 7_200)   // 2 hours from now
        for _ in 0..<3 {
            try await captureWithEventTime(kit, handle, room: "work", eventTime: futureEvent)
        }

        // splitAt is now; all filedAt values are ~now (same ingest moment),
        // so a filedAt split would misclassify all drawers into after.
        // An eventTime split correctly yields 3 before, 3 after.
        let splitAt = Date()
        let out = try await Drift.run(
            kit: kit, handle: handle, frame: unconfirmed, splitAt: splitAt)

        #expect(out.beforeCount == 3, "three past-event drawers should be in before-window")
        #expect(out.afterCount == 3, "three future-event drawers should be in after-window")
        // Laplace smoothing reduces JS for a 3-vs-3 disjoint split over a
        // 2-bin vocabulary to ~0.457; a threshold of 0.3 is meaningfully
        // high while robust to the smoothing.
        #expect(out.drift.jensenShannon > 0.3, "full room shift between windows should be high drift")
    }

    // CK-DR-5: partial-overlap vocabulary (before = {study, work},
    // after = {work, lab}). Without Laplace smoothing the absent bin
    // produces a degenerate distribution that lets KL go negative.
    // With smoothing KL ≥ 0 is guaranteed (Gibbs' inequality).
    @Test("partial-overlap vocabulary gives non-negative KL divergence")
    func partialOverlapKLNonNegative() async throws {
        let (kit, handle) = try await openEstate()

        // Before-window: two rooms.
        let pastEvent = Date(timeIntervalSinceNow: -7_200)
        try await captureWithEventTime(kit, handle, room: "study",  eventTime: pastEvent)
        try await captureWithEventTime(kit, handle, room: "work",   eventTime: pastEvent)

        // After-window: overlaps on "work" but adds "lab", drops "study".
        let futureEvent = Date(timeIntervalSinceNow: 7_200)
        try await captureWithEventTime(kit, handle, room: "work",   eventTime: futureEvent)
        try await captureWithEventTime(kit, handle, room: "lab",    eventTime: futureEvent)

        let splitAt = Date()
        let out = try await Drift.run(
            kit: kit, handle: handle, frame: unconfirmed, splitAt: splitAt)

        // KL must be ≥ 0 (Gibbs' inequality). A negative value indicates
        // the histogram builder constructed distributions that violate the
        // valid-distribution invariant (partial support, no smoothing).
        #expect(out.drift.klDivergence >= 0,
                "KL divergence must be non-negative; got \(out.drift.klDivergence)")
        #expect(out.drift.jensenShannon >= 0,
                "Jensen-Shannon must be non-negative; got \(out.drift.jensenShannon)")
    }
}
