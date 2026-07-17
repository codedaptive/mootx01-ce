// SlotTableTests.swift
//
// Test coverage for SlotTable pure decision logic and DeviceSlot model.
// All tests use injected clocks — no real time.time(), no sleep().
//
// Coverage:
//   - claimSlot on empty registry → lowest free slot
//   - preferred free slot honoured
//   - preferred occupied → lowest available
//   - exhaustion verdict (all 15 recently-active, no eviction)
//   - long-inactivity eviction candidate
//   - ghost fast-path eviction (never heartbeated + past ghost window)
//   - ghost inside ghost window → no fast-path eviction
//   - verify: matching epoch → current
//   - verify: mismatched epoch → superseded
//   - verify: absent slot → current
//   - determinism: same inputs, same output on every call

import Testing
import Foundation
import ConvergenceKit
import SubstrateTypes

// MARK: - Test helpers

/// Returns a `@Sendable () -> Date` closure that always returns `date`.
private func fixedClock(_ date: Date) -> @Sendable () -> Date { { date } }

/// Build a DeviceSlot with a non-zero lastActiveHLC at the given date (in millis).
private func activeSlot(
    number: Int,
    lastActiveDate: Date,
    claimedAt: Date? = nil,
    epoch: Int64 = 1
) -> DeviceSlot {
    let millis = Int64(lastActiveDate.timeIntervalSince1970 * 1000)
    return DeviceSlot(
        slot: number,
        epoch: epoch,
        deviceUUID: UUID(),
        lastActiveHLC: HLC(physicalTime: millis, logicalCount: 0, nodeID: Int32(number)),
        claimedAt: claimedAt ?? lastActiveDate
    )
}

/// Build a ghost DeviceSlot (lastActiveHLC == .zero, claimedAt as given).
private func ghostSlot(number: Int, claimedAt: Date, epoch: Int64 = 1) -> DeviceSlot {
    DeviceSlot(
        slot: number,
        epoch: epoch,
        deviceUUID: UUID(),
        lastActiveHLC: HLC.zero,
        claimedAt: claimedAt
    )
}

// MARK: - Free slot tests

@Suite("SlotTable: claim on free registry")
struct SlotTableFreeTests {

    @Test("empty registry returns freeSlot(1)")
    func emptyRegistry() {
        let table = SlotTable(slots: [])
        let decision = table.claimSlot(for: UUID(), preferring: nil,
                                       now: fixedClock(Date()))
        guard case .freeSlot(1) = decision else {
            Issue.record("expected freeSlot(1), got \(decision)")
            return
        }
    }

    @Test("preferred free slot is honoured")
    func preferredFreeSlot() {
        let now = Date()
        // slots 1–4 occupied (recently active), prefer 7 which is free
        let occupied = (1...4).map { activeSlot(number: $0, lastActiveDate: now.addingTimeInterval(-60)) }
        let table = SlotTable(slots: occupied)
        let decision = table.claimSlot(for: UUID(), preferring: 7, now: fixedClock(now))
        guard case .freeSlot(7) = decision else {
            Issue.record("expected freeSlot(7), got \(decision)")
            return
        }
    }

    @Test("preferred slot occupied: lowest free slot chosen")
    func preferredOccupied() {
        let now = Date()
        // slots 1, 2, 4 occupied; prefer 1 (occupied) → expect 3
        let occupied = [1, 2, 4].map { activeSlot(number: $0, lastActiveDate: now.addingTimeInterval(-30)) }
        let table = SlotTable(slots: occupied)
        let decision = table.claimSlot(for: UUID(), preferring: 1, now: fixedClock(now))
        guard case .freeSlot(3) = decision else {
            Issue.record("expected freeSlot(3), got \(decision)")
            return
        }
    }

    @Test("nil preference returns lowest free slot")
    func nilPreference() {
        let now = Date()
        // slots 1, 2, 3 occupied; no preference → expect 4
        let occupied = (1...3).map { activeSlot(number: $0, lastActiveDate: now.addingTimeInterval(-1)) }
        let table = SlotTable(slots: occupied)
        let decision = table.claimSlot(for: UUID(), preferring: nil, now: fixedClock(now))
        guard case .freeSlot(4) = decision else {
            Issue.record("expected freeSlot(4), got \(decision)")
            return
        }
    }
}

// MARK: - Exhaustion tests

@Suite("SlotTable: exhaustion verdict")
struct SlotTableExhaustionTests {

    @Test("all 15 slots recently active: exhausted")
    func allRecentlyActive() {
        let now = Date()
        // All 15 slots active 60 seconds ago — well inside both windows
        let full = (1...15).map { activeSlot(number: $0, lastActiveDate: now.addingTimeInterval(-60)) }
        let table = SlotTable(slots: full)
        let decision = table.claimSlot(for: UUID(), preferring: nil, now: fixedClock(now))
        guard case .exhausted = decision else {
            Issue.record("expected exhausted, got \(decision)")
            return
        }
    }
}

// MARK: - Eviction tests

@Suite("SlotTable: eviction candidate")
struct SlotTableEvictionTests {

    @Test("long-inactive slot selected as eviction candidate")
    func longInactiveEviction() {
        let now = Date()
        let recentDate = now.addingTimeInterval(-60)  // 1 minute ago — well inside window
        // 14 recently-active slots; slot 9 long-inactive (35 days)
        var slots = (1...15).filter { $0 != 9 }
            .map { activeSlot(number: $0, lastActiveDate: recentDate) }
        let oldDate = now.addingTimeInterval(-(35 * 24 * 60 * 60))
        slots.append(activeSlot(number: 9, lastActiveDate: oldDate))

        let table = SlotTable(slots: slots)
        let decision = table.claimSlot(for: UUID(), preferring: nil, now: fixedClock(now))
        guard case .evictionCandidate(let candidate) = decision else {
            Issue.record("expected evictionCandidate, got \(decision)")
            return
        }
        #expect(candidate.slot == 9)
    }

    @Test("oldest long-inactive slot chosen when multiple qualify")
    func oldestInactiveWins() {
        let now = Date()
        let recentDate = now.addingTimeInterval(-60)
        // slots 5 and 8 are both long-inactive; slot 5 is older
        var slots = (1...15).filter { $0 != 5 && $0 != 8 }
            .map { activeSlot(number: $0, lastActiveDate: recentDate) }
        let oldest = now.addingTimeInterval(-(40 * 24 * 60 * 60))
        let older  = now.addingTimeInterval(-(32 * 24 * 60 * 60))
        slots.append(activeSlot(number: 5, lastActiveDate: oldest))
        slots.append(activeSlot(number: 8, lastActiveDate: older))

        let table = SlotTable(slots: slots)
        let decision = table.claimSlot(for: UUID(), preferring: nil, now: fixedClock(now))
        guard case .evictionCandidate(let candidate) = decision else {
            Issue.record("expected evictionCandidate, got \(decision)")
            return
        }
        #expect(candidate.slot == 5, "oldest-inactive slot (5) should be preferred over 8")
    }

    @Test("ghost fast-path: never-heartbeated slot past ghost window is evictable")
    func ghostFastPath() {
        let now = Date()
        let recentDate = now.addingTimeInterval(-60)
        // 14 recently-active slots; slot 3 is a ghost (never heartbeated, 2 hours old)
        var slots = (1...15).filter { $0 != 3 }
            .map { activeSlot(number: $0, lastActiveDate: recentDate) }
        let twoHoursAgo = now.addingTimeInterval(-(2 * 60 * 60))
        slots.append(ghostSlot(number: 3, claimedAt: twoHoursAgo))

        let table = SlotTable(slots: slots)
        let decision = table.claimSlot(for: UUID(), preferring: nil, now: fixedClock(now))
        guard case .evictionCandidate(let candidate) = decision else {
            Issue.record("expected evictionCandidate (ghost fast-path), got \(decision)")
            return
        }
        #expect(candidate.slot == 3)
        #expect(candidate.lastActiveHLC == HLC.zero, "ghost slot must have HLC.zero")
    }

    @Test("ghost inside window is not yet evictable → exhausted")
    func ghostInsideWindow() {
        let now = Date()
        let recentDate = now.addingTimeInterval(-60)
        // 14 recently-active; slot 3 is a ghost but only 30 minutes old (inside 1h window)
        var slots = (1...15).filter { $0 != 3 }
            .map { activeSlot(number: $0, lastActiveDate: recentDate) }
        let thirtyMinutesAgo = now.addingTimeInterval(-(30 * 60))
        slots.append(ghostSlot(number: 3, claimedAt: thirtyMinutesAgo))

        let table = SlotTable(slots: slots)
        let decision = table.claimSlot(for: UUID(), preferring: nil, now: fixedClock(now))
        guard case .exhausted = decision else {
            Issue.record("expected exhausted (ghost inside window), got \(decision)")
            return
        }
    }

    @Test("ghost fast-path takes priority over long-inactive")
    func ghostBeforeLongInactive() {
        let now = Date()
        let recentDate = now.addingTimeInterval(-60)
        // slot 2: long-inactive (35 days), slot 7: ghost 2 hours old
        var slots = (1...15).filter { $0 != 2 && $0 != 7 }
            .map { activeSlot(number: $0, lastActiveDate: recentDate) }
        let oldDate = now.addingTimeInterval(-(35 * 24 * 60 * 60))
        slots.append(activeSlot(number: 2, lastActiveDate: oldDate))
        slots.append(ghostSlot(number: 7, claimedAt: now.addingTimeInterval(-(2 * 60 * 60))))

        let table = SlotTable(slots: slots)
        let decision = table.claimSlot(for: UUID(), preferring: nil, now: fixedClock(now))
        guard case .evictionCandidate(let candidate) = decision else {
            Issue.record("expected evictionCandidate, got \(decision)")
            return
        }
        // Ghost fast-path wins over long-inactive
        #expect(candidate.slot == 7, "ghost fast-path (slot 7) should win over long-inactive (slot 2)")
        #expect(candidate.lastActiveHLC == HLC.zero)
    }
}

// MARK: - Verify tests

@Suite("SlotTable: epoch fencing via verify()")
struct SlotTableVerifyTests {

    @Test("matching epoch returns .current")
    func matchingEpoch() {
        let slot = DeviceSlot(slot: 5, epoch: 3, deviceUUID: UUID(),
                              lastActiveHLC: HLC(physicalTime: 1_000, logicalCount: 0, nodeID: 5),
                              claimedAt: Date())
        let table = SlotTable(slots: [slot])
        #expect(table.verify(slot: 5, epoch: 3) == .current)
    }

    @Test("different epoch returns .superseded")
    func differentEpoch() {
        let slot = DeviceSlot(slot: 5, epoch: 4, deviceUUID: UUID(),
                              lastActiveHLC: HLC(physicalTime: 1_000, logicalCount: 0, nodeID: 5),
                              claimedAt: Date())
        let table = SlotTable(slots: [slot])
        // We hold epoch 3, registry shows 4 → we were evicted
        #expect(table.verify(slot: 5, epoch: 3) == .superseded)
    }

    @Test("absent slot returns .current (provisional claim uncontested)")
    func absentSlot() {
        let table = SlotTable(slots: [])
        // Slot not in registry — local provisional claim stands pending CloudKit CAS
        #expect(table.verify(slot: 7, epoch: 1) == .current)
    }

    @Test("verify for different slot number is unaffected")
    func differentSlotNumber() {
        let slot = DeviceSlot(slot: 10, epoch: 2, deviceUUID: UUID(),
                              lastActiveHLC: HLC(physicalTime: 500, logicalCount: 0, nodeID: 10),
                              claimedAt: Date())
        let table = SlotTable(slots: [slot])
        // Querying slot 11 which is absent → .current
        #expect(table.verify(slot: 11, epoch: 2) == .current)
        // Querying slot 10 with matching epoch → .current
        #expect(table.verify(slot: 10, epoch: 2) == .current)
    }
}

// MARK: - Determinism test

@Suite("SlotTable: determinism with injected clock")
struct SlotTableDeterminismTests {

    @Test("same inputs produce identical decisions")
    func sameInputsSameOutput() {
        // Fixed reference time: 2 hours past the ghost window for a ghost slot
        let epoch = Date(timeIntervalSince1970: 1_750_000_000)
        let twoHoursEarlier = epoch.addingTimeInterval(-(2 * 60 * 60))
        let ghost = ghostSlot(number: 4, claimedAt: twoHoursEarlier)
        // Fill remaining 14 slots with recent activity
        let recentDate = epoch.addingTimeInterval(-60)
        var slots = (1...15).filter { $0 != 4 }
            .map { activeSlot(number: $0, lastActiveDate: recentDate) }
        slots.append(ghost)

        let table = SlotTable(slots: slots)
        // Call three times with the same fixed clock
        let d1 = table.claimSlot(for: UUID(), preferring: nil, now: fixedClock(epoch))
        let d2 = table.claimSlot(for: UUID(), preferring: nil, now: fixedClock(epoch))
        let d3 = table.claimSlot(for: UUID(), preferring: nil, now: fixedClock(epoch))

        switch (d1, d2, d3) {
        case (.evictionCandidate(let a), .evictionCandidate(let b), .evictionCandidate(let c)):
            #expect(a.slot == 4, "first call should choose ghost slot 4")
            #expect(b.slot == 4, "second call should choose same slot")
            #expect(c.slot == 4, "third call should choose same slot")
        default:
            Issue.record("expected evictionCandidate(4) on all three calls, got \(d1), \(d2), \(d3)")
        }
    }
}

// MARK: - DeviceSlot model test

@Suite("DeviceSlot model")
struct DeviceSlotTests {

    @Test("HLC.zero is the sentinel for never-heartbeated slots")
    func hlcZeroSentinel() {
        let slot = ghostSlot(number: 5, claimedAt: Date())
        #expect(slot.lastActiveHLC == HLC.zero)
    }

    @Test("slot range 1...15 is accepted")
    func validSlotRange() {
        let now = Date()
        let millis = Int64(now.timeIntervalSince1970 * 1000)
        for i in 1...15 {
            let s = DeviceSlot(slot: i, epoch: 1, deviceUUID: UUID(),
                               lastActiveHLC: HLC(physicalTime: millis, logicalCount: 0, nodeID: Int32(i)),
                               claimedAt: now)
            #expect(s.slot == i)
        }
    }
}

// MARK: - 40-bit physicalTime truncation regression (Adams P1 CRITICAL #1)

@Suite("SlotTable: packed-HLC truncation regression")
struct SlotTableTruncationRegressionTests {

    /// A slot heartbeated moments ago must NOT be eviction-eligible, even when
    /// its lastActiveHLC has round-tripped through HLC.packed (whose physical
    /// field is 40 bits, so 2026-scale Unix-ms values are truncated). Before
    /// the fix, evictionCandidate compared full-width now-millis against the
    /// truncated physicalTime, making every real-world slot look ~35 years
    /// stale and permanently eviction-eligible.
    @Test("recently-active slot with packed-truncated HLC is not evictable at 2026-scale timestamps")
    func recentlyActivePackedSlotNotEvictable() {
        // 2026-07-16T00:00:00Z — well above 2^40 ms, so packing truncates.
        let now = Date(timeIntervalSince1970: 1_784_160_000)
        let recentMillis = Int64(now.timeIntervalSince1970 * 1000) - 60_000 // 1 min ago
        let fullWidth = HLC(physicalTime: recentMillis, logicalCount: 0, nodeID: 3)
        // Round-trip through the packed form, exactly as SlotRecordMapping does.
        let truncated = HLC(packed: fullWidth.packed)
        let slot = DeviceSlot(
            slot: 3, epoch: 1, deviceUUID: UUID(),
            lastActiveHLC: truncated, claimedAt: now.addingTimeInterval(-3600)
        )
        let table = SlotTable(slots: [slot])
        #expect(table.evictionCandidate(now: now) == nil,
                "recently-active slot must not be eviction-eligible after packed round-trip")
    }

    /// The inverse guarantee: a slot genuinely idle beyond the long-inactivity
    /// window IS still detected after the same packed round-trip (the masked
    /// comparison preserves real staleness, not just recency).
    @Test("genuinely stale slot remains evictable after packed round-trip")
    func genuinelyStaleSlotStillEvictable() {
        let now = Date(timeIntervalSince1970: 1_784_160_000)
        // 40 days idle — beyond the 30-day long-inactivity window.
        let staleMillis = Int64(now.timeIntervalSince1970 * 1000) - 40 * 86_400_000
        let fullWidth = HLC(physicalTime: staleMillis, logicalCount: 0, nodeID: 4)
        let truncated = HLC(packed: fullWidth.packed)
        let slot = DeviceSlot(
            slot: 4, epoch: 1, deviceUUID: UUID(),
            lastActiveHLC: truncated, claimedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let table = SlotTable(slots: [slot])
        #expect(table.evictionCandidate(now: now)?.slot == 4,
                "genuinely idle slot must remain eviction-eligible")
    }
}
