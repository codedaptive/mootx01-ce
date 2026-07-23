// DreamingAlphaGateTests.swift — T9 REM-ALPHA pending-count gate tests
// The ALPHA gate requires both a due timer and a non-empty dreaming queue.
//
// The §12.2 gate skips the dreaming cycle when the dreaming queue is empty
// (or not yet mounted), EVEN when the timer interval is due. Only a non-empty
// queue proceeds to the full dreaming-daemon pump + drain path.
//
// Coverage:
//   §1  POSITIVE: dreaming queue has pending items AND timer due
//                 → governor tick FIRES the dreaming cycle (dreamingFired=true).
//   §2  NEGATIVE: dreaming queue EMPTY AND timer due
//                 → governor tick does NOT fire (dreamingFired=false).
//                 Anti-regression: this test MUST fail if the gate is removed.
//   §3  CADENCE:  dreaming queue has pending items BUT timer interval not
//                 elapsed → governor tick does NOT fire (dreamingFired=false).

import Foundation
import Testing
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import NeuronKit

@Suite("T9 REM-ALPHA Pending-Count Gate — AutonomicGovernor §12.2")
struct DreamingAlphaGateTests {

    // MARK: - Infrastructure

    /// Open a fresh in-memory estate and return (kit, handle).
    private func makeKit() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "alpha-gate-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Capture a drawer into the estate.
    private func capture(
        _ kit: GeniusLocusKit,
        _ handle: EstateHandle,
        content: String
    ) async throws {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "test-room",
            latticeAnchor: .udc("000"),
            addedBy: "alpha-gate-test",
            embeddingModelID: "test-model-v1"
        )
        _ = try await kit.capture(handle, frame)
    }

    /// Fire one external-origin recall, enqueueing a DreamingItem for the
    /// co-surfaced drawer set (B-10a: enqueue fires ONLY on external origin).
    private func fireRecall(
        _ kit: GeniusLocusKit,
        _ handle: EstateHandle
    ) async throws {
        let request = GLKRecallRequest(
            frame: RecallFrame(filterChain: [.currentlyBelieve], limit: 50),
            mode: .locusOnly,
            scoring: .raw,
            limit: 50,
            fallback: .failClosed,
            origin: .external
        )
        _ = try await kit.recall(handle, request)
    }

    /// Build a governor optimised for deterministic tick() tests:
    /// - graphAnalyticsIntervalMs  = Int.max (never fires)
    /// - graphCentralityIntervalMs = Int.max (never fires)
    /// - preferenceIntervalMs      = Int.max (never fires)
    /// - topologyCadenceMs         = Int.max (never fires)
    /// - poolReduceCadenceMs       = Int.max (never fires)
    /// - poolDirectory/poolTableArtifactURL = nil (no pool I/O)
    /// - clock: injected — tick() uses its own `now` parameter, not the clock.
    private func makeGovernor(
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) -> AutonomicGovernor {
        AutonomicGovernor(
            kit: kit,
            handle: handle,
            baseTickMs: 5_000,
            graphAnalyticsIntervalMs: Int.max,
            graphCentralityIntervalMs: Int.max,
            preferenceIntervalMs: Int.max,
            topologyCadenceMs: Int.max,
            poolReduceCadenceMs: Int.max,
            topologyHandler: nil,
            topologyFingerprintLoader: nil,
            topologyGate: nil,
            graphAnalyticsHandler: nil,
            poolDirectory: nil,
            poolTableArtifactURL: nil
        )
    }

    // MARK: - §1 POSITIVE: pending items + timer due → dreaming fires

    /// Verify that the governor fires the dreaming cycle when:
    ///   (a) the dreaming queue has pending items (external-origin recall fired), AND
    ///   (b) the timer interval (default 30 s) has elapsed.
    ///
    /// The pending-count gate sees count > 0, the timer gate is due →
    /// both pass → dreaming pump runs.
    @Test("§1: pending > 0 AND timer due → dreamingFired = true")
    func positiveQueuePendingAndTimerDueFires() async throws {
        let (kit, handle) = try await makeKit()

        // Capture two drawers so they co-surface on recall.
        try await capture(kit, handle, content: "REM-ALPHA Swift content A")
        try await capture(kit, handle, content: "REM-ALPHA Swift content B")

        // Fire one external-origin recall → one DreamingItem in the queue.
        try await fireRecall(kit, handle)

        // Confirm the pending count before ticking (non-claiming probe).
        let pending = await kit.dreamingQueuePendingCount(for: handle)
        #expect(pending != nil && pending! >= 1,
            "setup: expected ≥ 1 pending dreaming item, got \(pending as Any)")

        let gov = makeGovernor(kit: kit, handle: handle)

        // Tick at t = 31 s (past the 30 s default interval).
        // First-tick-fires behaviour: last_timer_fire is nil → timer due.
        // Pending gate: Some(1) > 0 → proceed.
        let t31 = Date(timeIntervalSince1970: 31)
        let report = await gov.tick(now: t31)

        #expect(report.dreamingFired,
            "§1 POSITIVE: pending > 0 + timer due → dreamingFired must be true")
    }

    // MARK: - §2 NEGATIVE: empty queue + timer due → dreaming does NOT fire

    /// Verify that the governor does NOT fire the dreaming cycle when the
    /// dreaming queue is empty (or not mounted), even when the timer is due.
    ///
    /// This is the anti-regression: without the §12.2 pending-count gate, the
    /// governor would call dreaming.pump() here and do wasteful work.
    /// The test MUST FAIL if the gate is removed.
    @Test("§2: empty queue (nil) + timer due → dreamingFired = false (anti-regression)")
    func negativeEmptyQueueTimerDueNoFire() async throws {
        let (kit, handle) = try await makeKit()

        // Capture drawers but do NOT fire any external-origin recall.
        // Dreaming queue is never mounted → pending returns nil.
        try await capture(kit, handle, content: "idle Swift content A")
        try await capture(kit, handle, content: "idle Swift content B")

        let pending = await kit.dreamingQueuePendingCount(for: handle)
        #expect(pending == nil,
            "setup: expected dreaming queue not mounted (nil), got \(pending as Any)")

        let gov = makeGovernor(kit: kit, handle: handle)

        // Tick at t = 31 s — timer is DUE (first-tick-fires: no prior fire).
        // Pending gate: nil → skip. dreaming must NOT fire.
        let t31 = Date(timeIntervalSince1970: 31)
        let report = await gov.tick(now: t31)

        #expect(!report.dreamingFired,
            "§2 NEGATIVE: empty queue (nil) + timer due → dreamingFired must be false")
    }

    // MARK: - §2b NEGATIVE: drained queue, second tick → dreaming does NOT fire

    /// Verify that after the queue is drained in the first cycle, a subsequent
    /// tick (timer due again) does NOT re-fire dreaming (queue is now empty).
    @Test("§2b: drained queue + timer due (second tick) → dreamingFired = false")
    func negativeDrainedQueueSecondTickNoFire() async throws {
        let (kit, handle) = try await makeKit()

        try await capture(kit, handle, content: "drain-once Swift A")
        try await capture(kit, handle, content: "drain-once Swift B")

        // Enqueue one item.
        try await fireRecall(kit, handle)

        let gov = makeGovernor(kit: kit, handle: handle)

        // First tick at t=31 s: timer due + pending=1 → fires + drains.
        let t31 = Date(timeIntervalSince1970: 31)
        let first = await gov.tick(now: t31)
        #expect(first.dreamingFired, "§2b setup: first tick (pending=1, timer due) must fire")

        // Verify queue is empty after drain.
        let afterDrain = await kit.dreamingQueuePendingCount(for: handle)
        #expect(afterDrain == 0,
            "§2b setup: after drain, pending must be 0, got \(afterDrain as Any)")

        // Second tick at t=62 s: timer due again (31 s > 30 s since last fire).
        // Queue empty (Some(0)) → pending gate skips.
        let t62 = Date(timeIntervalSince1970: 62)
        let second = await gov.tick(now: t62)

        #expect(!second.dreamingFired,
            "§2b NEGATIVE: drained queue + timer due on second tick → dreamingFired must be false")
    }

    // MARK: - §3 CADENCE: timer-mode cadence gate + NK-2 event-mode pumpOnEvent wiring

    /// Verify the cadence gate and NK-2 event-mode wiring together.
    ///
    /// After the first dreaming cycle fires at t=0, the SolverBandit updates the
    /// trigger mode based on the cycle's reward. If the bandit selects .timer mode,
    /// the timer gate holds at t=10 s (10 s < 30 s interval, timer not due →
    /// dreamingFired = false). If the bandit selects .event or .hybrid mode, the
    /// NK-2 pumpOnEvent path fires at t=10 s (pending > 0, threshold = 1 →
    /// dreamingFired = true) — this is CORRECT NK-2 behavior: event-mode estates
    /// receive near-realtime cycles as observations accumulate, independent of the
    /// timer cadence.
    ///
    /// The test reads `gov.dreamingTriggerMode()` after the first tick to determine
    /// which assertion applies. Both paths are validated.
    @Test("§3: cadence gate (timer mode) + NK-2 event-mode pumpOnEvent wiring")
    func cadenceTimerNotDueAndEventModeWiring() async throws {
        let (kit, handle) = try await makeKit()

        try await capture(kit, handle, content: "cadence Swift content A")
        try await capture(kit, handle, content: "cadence Swift content B")

        // Enqueue one item and fire the first tick to set the timer baseline.
        // The first tick fires dreaming (nil last fire → always fires) and drains.
        try await fireRecall(kit, handle)
        let gov = makeGovernor(kit: kit, handle: handle)

        let t0 = Date(timeIntervalSince1970: 0)
        let first = await gov.tick(now: t0)
        // The first tick fires dreaming (first-tick-fires) and drains the queue.
        // Timer baseline is now set at t=0. The bandit may update trigger mode.
        let _ = first.dreamingFired

        // Read the bandit-selected trigger mode AFTER the first cycle.
        let modeAfterFirstCycle = await gov.dreamingTriggerMode()

        // Enqueue a NEW item AFTER the first tick drained the queue.
        try await fireRecall(kit, handle)

        let pending = await kit.dreamingQueuePendingCount(for: handle)
        #expect(pending != nil && pending! >= 1,
            "§3 setup: expected ≥ 1 pending item after second enqueue, got \(pending as Any)")

        // Tick at t=10 s: timer baseline was set at t=0; elapsed = 10 s < 30 s.
        let t10 = Date(timeIntervalSince1970: 10)
        let report = await gov.tick(now: t10)

        switch modeAfterFirstCycle {
        case .timer:
            // Timer mode: timer NOT due (10 s < 30 s), pumpOnEvent returns nil →
            // dreamingFired must be false. This is the classic cadence gate.
            #expect(!report.dreamingFired,
                "§3 CADENCE (timer mode): pending > 0 but timer not due → dreamingFired must be false")
        case .event, .hybrid:
            // Event / hybrid mode: pumpOnEvent fires when pending ≥ threshold (1).
            // Timer NOT due only blocks the timer path, not the event path.
            // This is correct NK-2 behavior: near-realtime dreaming for event estates.
            #expect(report.dreamingFired,
                "§3 NK-2 (event/hybrid mode): pending > 0 → pumpOnEvent must fire → dreamingFired = true")
        }
    }
}
