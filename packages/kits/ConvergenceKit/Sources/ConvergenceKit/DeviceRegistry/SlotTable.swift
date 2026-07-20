// SlotTable.swift
//
// Pure decision logic over an immutable [DeviceSlot] snapshot.
//
// This file is the transport-agnostic core of the N2 slot registry protocol.
// It contains no I/O, no CloudKit imports, and no Date() calls. The
// CloudKit CAS (compare-and-swap) that actually claims or evicts slots
// in the shared registry arrives in P1-M3.
//
// All time comparisons use an injected clock (`now: @Sendable () -> Date`)
// so the table is fully testable with deterministic, reproducible inputs.
//
// Reference: DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16.md §N2

import Foundation
import SubstrateTypes

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Named time-window constants
//
// These constants define when a slot becomes eligible for eviction. They are
// named public constants (not magic literals) for three reasons:
//
//   1. Tests can verify both the happy path (slot just inside the window)
//      and the eviction path (slot just outside) without fragile sleep() calls.
//   2. The "why" is documented at the point of use, not in a distant PR comment.
//   3. P1-M3 or a future tuning mission can adjust them without grep-hunting
//      for literal seconds values.
// ─────────────────────────────────────────────────────────────────────────────

/// 30 days in seconds.
///
/// A slot whose `lastActiveHLC` physical-time component is more than 30 days
/// behind wall-clock is considered long-inactive and eligible for normal
/// eviction. 30 days was chosen to balance two competing concerns:
///
///  - A machine on a month-long holiday should not lose its slot; shorter
///    windows would evict it on the device's first reconnect, forcing an
///    unnecessary re-enroll and a brief collision window.
///  - A decommissioned machine should eventually free its slot so the estate
///    does not accumulate phantom registry entries that block new devices
///    from enrolling.
///
/// Adjudication A4 (DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16).
public let SlotLongInactivityWindow: TimeInterval = 30 * 24 * 60 * 60   // 30 days

/// 1 hour in seconds.
///
/// A slot that was claimed but has NEVER sent a heartbeat
/// (`lastActiveHLC == HLC.zero`) is a "ghost": the device minted a
/// local provisional claim but never completed enrollment into the shared
/// CloudKit registry. Ghost slots occupy a registry entry for zero benefit;
/// other devices cannot use that slot number while the ghost entry exists.
///
/// After `SlotGhostWindow` with no heartbeat the slot is eligible for
/// fast-path eviction regardless of when it was claimed. 1 hour was chosen
/// as a generous allowance for slow devices, background-restricted processes,
/// and flaky CloudKit connectivity on first enrollment.
///
/// Fast-path is checked before the long-inactivity path so ghost slots are
/// freed quickly rather than waiting 30 days.
///
/// Adjudication A4 (DECISION_CONVERGENCEKIT_CONCURRENT_MULTIDEVICE_2026-07-16).
public let SlotGhostWindow: TimeInterval = 60 * 60   // 1 hour

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Decision types
// ─────────────────────────────────────────────────────────────────────────────

/// The outcome of `SlotTable.claimSlot(for:preferring:now:)`.
public enum ClaimDecision: Sendable, Equatable {
    /// A specific slot number (1–15) is free for immediate claim.
    /// The caller should write a CloudKit record for this slot.
    case freeSlot(Int)

    /// All 15 slots are occupied, but this slot is the best eviction candidate.
    /// The caller should CAS the slot record's epoch to `candidate.epoch + 1`
    /// in CloudKit. On success the caller owns the slot at the new epoch.
    /// On CAS failure (another device evicted first), retry claimSlot().
    case evictionCandidate(DeviceSlot)

    /// All 15 slots are occupied and none qualify for eviction under the
    /// current time windows. The engine raises `SyncError.slotExhausted`
    /// and retries after a backoff period.
    case exhausted
}

/// The outcome of `SlotTable.verify(slot:epoch:)`.
public enum VerifyResult: Sendable, Equatable {
    /// The (slot, epoch) pair is still valid in the current registry snapshot.
    /// The device may proceed with normal sync operations.
    case current

    /// The slot's epoch has changed since this device last enrolled.
    /// The slot was evicted and re-claimed by another device while this
    /// device was inactive. The engine raises `SyncError.reenrollRequired`
    /// and the device must claim a fresh slot before applying any records.
    case superseded
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SlotTable
// ─────────────────────────────────────────────────────────────────────────────

/// Pure decision logic over an immutable snapshot of the 15-slot device
/// registry. Instances are cheap to create (they hold a value copy of the
/// snapshot array) and are not cached — callers re-create them from the
/// current CloudKit-downloaded snapshot on each decision point.
///
/// All time comparisons use the injected `now` clock argument; there is
/// no `Date()` call inside this type. This ensures tests are fully
/// deterministic without sleep() calls or time mocking.
public struct SlotTable: Sendable {

    /// The registry snapshot. Contains 0–15 `DeviceSlot` entries.
    public let slots: [DeviceSlot]

    public init(slots: [DeviceSlot]) {
        self.slots = slots
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Claim decision
    // ─────────────────────────────────────────────────────────────────────────

    /// Determine the best slot claim action for `deviceUUID`.
    ///
    /// Decision priority (first matching rule wins):
    /// 1. If `preferring` is given and that slot is free → `.freeSlot(preferring)`
    /// 2. Lowest-numbered free slot → `.freeSlot(n)`
    /// 3. Best ghost-fast-path eviction candidate → `.evictionCandidate(slot)`
    /// 4. Best long-inactivity eviction candidate → `.evictionCandidate(slot)`
    /// 5. No eligible candidate → `.exhausted`
    ///
    /// - Parameters:
    ///   - deviceUUID: The UUID of the device requesting a slot.
    ///   - preferring: Optional preferred slot (the caller's provisionally
    ///     persisted slot, if any). Honoured when the slot is free; ignored
    ///     otherwise to avoid infinite collision loops.
    ///   - now: Injected clock. Must not call `Date()` — callers supply the
    ///     current time so tests can reproduce any scenario deterministically.
    public func claimSlot(
        for deviceUUID: UUID,
        preferring preferredSlot: Int?,
        now: @Sendable () -> Date
    ) -> ClaimDecision {
        let currentTime = now()
        let occupiedSlotNumbers = Set(slots.map { $0.slot })
        let allSlotNumbers = Set(1...15)
        let freeSlotNumbers = allSlotNumbers.subtracting(occupiedSlotNumbers)

        // Fast path: preferred slot is free
        if let preferred = preferredSlot, freeSlotNumbers.contains(preferred) {
            return .freeSlot(preferred)
        }

        // Any free slot (lowest numbered for deterministic selection)
        if let lowest = freeSlotNumbers.sorted().first {
            return .freeSlot(lowest)
        }

        // All slots occupied — look for an eviction candidate
        if let candidate = evictionCandidate(now: currentTime) {
            return .evictionCandidate(candidate)
        }

        return .exhausted
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Eviction candidate
    // ─────────────────────────────────────────────────────────────────────────

    /// Find the best eviction candidate given the current time.
    ///
    /// **Ghost fast-path (adjudication A4):** A slot whose `lastActiveHLC`
    /// is `HLC.zero` (never heartbeated) AND whose `claimedAt` is older than
    /// `SlotGhostWindow` is a ghost. Ghosts are checked first because they
    /// provide zero benefit — evicting them is always safe and does not punish
    /// a device that actually produced valid HLCs.
    ///
    /// When multiple ghost slots exist, the oldest-by-claimedAt is selected
    /// to be deterministic and to free the stale claims first.
    ///
    /// **Long-inactivity slow-path:** Among non-ghost slots, the slot whose
    /// `lastActiveHLC.physicalTime` is furthest behind wall-clock beyond
    /// `SlotLongInactivityWindow` is the candidate. When multiple qualify,
    /// the one with the smallest (oldest) `lastActiveHLC` is selected.
    ///
    /// Returns `nil` if no slot qualifies under either window.
    public func evictionCandidate(now: Date) -> DeviceSlot? {
        // Ghost fast-path: never heartbeated + past the ghost window
        let ghosts = slots.filter { slot in
            slot.lastActiveHLC == HLC.zero
            && now.timeIntervalSince(slot.claimedAt) > SlotGhostWindow
        }
        if let oldestGhost = ghosts.min(by: { $0.claimedAt < $1.claimedAt }) {
            return oldestGhost
        }

        // Long-inactivity slow-path: oldest lastActiveHLC past the window
        // Convert wall-clock to milliseconds for comparison with HLC physicalTime.
        //
        // CRITICAL: lastActiveHLC round-trips through HLC.packed, whose physical
        // field is 40 bits (HLC.swift: `phys & 0xFF_FFFF_FFFF`; this is the
        // SubstrateTypes layout — node 8b | logical 16b | physical 40b — as
        // defined in spec B-6, distinct from the CKRecordMapping CloudKit wire
        // layout which uses physical 48b | logical 12b | node 4b). A full-width
        // 2026 Unix-ms value (~1.75e12) exceeds 2^40 (~1.10e12), so the
        // unpacked physicalTime is truncated. Comparing
        // it against full-width now-millis makes every slot look ~35 years
        // stale — every non-ghost slot becomes permanently eviction-eligible,
        // silently defeating fenced eviction (Adams P1 review, CRITICAL #1).
        // Fix: mask now-millis into the same 40-bit space so both sides of the
        // subtraction wrap identically. The window comparison is then correct
        // except across a 2^40-ms (~35-year) wrap boundary, which the epoch
        // fence tolerates: a mis-evicted ACTIVE device is fenced loudly at its
        // next heartbeat and re-enrolls without data loss (A2 re-mint).
        // BOTH sides are masked: a slot's lastActiveHLC may be full-width
        // (constructed directly, as in tests) or already truncated (round-
        // tripped through packed, as real registry records are). Masking both
        // puts the subtraction in one consistent 40-bit space either way.
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000) & 0xFF_FFFF_FFFF
        let longInactivityMillis = Int64(SlotLongInactivityWindow * 1000)
        let candidates = slots.filter { slot in
            // Exclude zero-HLC slots (ghosts, handled above)
            slot.lastActiveHLC != HLC.zero
            && (nowMillis - (slot.lastActiveHLC.physicalTime & 0xFF_FFFF_FFFF)) > longInactivityMillis
        }
        // Return the slot with the oldest (smallest) lastActiveHLC
        return candidates.min(by: { $0.lastActiveHLC < $1.lastActiveHLC })
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Epoch fencing
    // ─────────────────────────────────────────────────────────────────────────

    /// Check whether an existing (slot, epoch) pair is still valid against
    /// the current registry snapshot.
    ///
    /// - If the slot is **absent** from the snapshot: `.current`
    ///   The slot is free in the shared registry, so the device's provisional
    ///   local claim is uncontested. The CloudKit CAS in P1-M3 will confirm
    ///   or reject it; until then no fencing is possible.
    ///
    /// - If the slot is **present with the same epoch**: `.current`
    ///   The device's claim is still live in the registry.
    ///
    /// - If the slot is **present with a different epoch**: `.superseded`
    ///   Another device evicted this slot (bumping the epoch) while this
    ///   device was away. The caller raises `SyncError.reenrollRequired`
    ///   before applying any inbound records.
    public func verify(slot: Int, epoch: Int64) -> VerifyResult {
        guard let entry = slots.first(where: { $0.slot == slot }) else {
            // Slot not in registry — provisional local claim is uncontested.
            // CloudKit CAS in P1-M3 will arbitrate any concurrent claims.
            return .current
        }
        return entry.epoch == epoch ? .current : .superseded
    }
}
