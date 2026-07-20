// SlotClaimOperation.swift
//
// CloudKit CAS (compare-and-swap) claim flow for the 15-slot device registry.
//
// CLAIM FLOW:
// 1. Fetch all 15 slot records from the manifest's zone in one round-trip.
// 2. Build a DeviceSlot snapshot and run SlotTable.claimSlot() for a decision.
// 3. On .freeSlot(n): create a new CKRecord for slot n and save with
//    .ifServerRecordUnchanged. A nil change tag means "only insert if absent."
//    On .evictionCandidate(existing): take the fetched record for that slot
//    (which carries the server's change tag), bump the epoch, update all
//    fields, and save with .ifServerRecordUnchanged.
// 4. If the save fails because another device raced to the same slot first
//    (serverRecordChanged error), wait with jittered exponential backoff and
//    retry from step 1.
// 5. If SlotTable returns .exhausted, throw slotExhausted(activeCount:).
// 6. After `maxAttempts` retries all end in CAS failures, throw
//    slotExhausted(activeCount: lastSnapshotCount).
//
// WHY JITTERED BACKOFF:
// Multiple devices evicted simultaneously (e.g. two new devices joining an
// estate with a full registry) race to claim the same eviction candidate.
// Jitter spreads their retries across time so the thundering-herd converges
// rather than ping-ponging in lockstep.
//
// Adjudications: A4 (ghost fast-path already in SlotTable), A5 (CAS retry).
// Slot claims use CloudKit compare-and-swap so exactly one device wins.

import Foundation
import CloudKit
import ConvergenceKit
import SubstrateTypes
import os

private let logger = Logger(subsystem: "com.mootx01.synckit.cloudkit", category: "SlotClaim")

// MARK: - SlotClaimOperation

/// Performs the CloudKit CAS claim for one device slot (N2).
///
/// Fully injectable: `database`, `rng`, `clock`, and `sleep` are injected so
/// tests can script outcomes, advance time, and skip real network delays.
///
/// Typical usage (inside CloudKitStateActor.enable()):
/// ```swift
/// let op = SlotClaimOperation(
///     database: database,
///     zoneID: zoneID,
///     deviceUUID: identity.deviceUUID,
///     maxAttempts: 8
/// )
/// let claimed = try await op.claim(preferring: identity.slot)
/// ```
public struct SlotClaimOperation: Sendable {

    // MARK: - Configuration

    let database: any CloudKitDatabaseProtocol
    let zoneID: CKRecordZone.ID
    let deviceUUID: UUID

    /// Maximum claim attempts (initial + retries). Bounded to avoid infinite loops
    /// when the registry is persistently contested. On exhaustion throws slotExhausted.
    let maxAttempts: Int

    /// Jitter source: returns a value in [0.0, 1.0). Injected so tests are deterministic.
    let rng: @Sendable () -> Double

    /// Wall-clock source. Injected for deterministic tests.
    let clock: @Sendable () -> Date

    /// Async sleep function. Injected so tests skip real delays.
    let sleep: @Sendable (TimeInterval) async throws -> Void

    // MARK: - Init

    /// Construct a SlotClaimOperation.
    ///
    /// - Parameters:
    ///   - database: The injectable database seam.
    ///   - zoneID: The manifest's sync zone where slot records live.
    ///   - deviceUUID: This device's stable UUID for the slot record's device_uuid field.
    ///   - maxAttempts: Maximum attempts before giving up (default 8).
    ///   - rng: Jitter source returning [0.0, 1.0) (default: Double.random).
    ///   - clock: Current wall-clock source (default: Date()).
    ///   - sleep: Async sleep (default: Task.sleep(for:)).
    public init(
        database: any CloudKitDatabaseProtocol,
        zoneID: CKRecordZone.ID,
        deviceUUID: UUID,
        maxAttempts: Int = 8,
        rng: @Sendable @escaping () -> Double = { Double.random(in: 0.0..<1.0) },
        clock: @Sendable @escaping () -> Date = { Date() },
        sleep: @Sendable @escaping (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(for: .seconds(interval))
        }
    ) {
        self.database = database
        self.zoneID = zoneID
        self.deviceUUID = deviceUUID
        self.maxAttempts = maxAttempts
        self.rng = rng
        self.clock = clock
        self.sleep = sleep
    }

    // MARK: - Claim

    /// Claim a registry slot for `deviceUUID`, preferring `preferredSlot` if free.
    ///
    /// The caller supplies a preferred slot (the previously persisted slot, if any)
    /// to reduce unnecessary slot changes across process restarts. If the preferred
    /// slot is occupied or if none is given, the lowest free slot is used. If all
    /// slots are occupied, an eviction candidate is chosen per SlotTable logic.
    ///
    /// - Parameter preferredSlot: Optional preferred slot number (1–15), typically
    ///   loaded from DeviceIdentityStore. Ignored when the slot is occupied.
    /// - Returns: The claimed DeviceSlot (slot, epoch, deviceUUID, claimedAt populated;
    ///   lastActiveHLC is HLC.zero — the first heartbeat happens at the start of the
    ///   next push cycle via EpochFence).
    /// - Throws:
    ///   - `SyncError.slotExhausted(activeCount:)` — all 15 slots occupied by
    ///     recently-active devices AND all eviction candidates lost their CAS
    ///     races, or no eviction candidates exist.
    ///   - `SyncError.transportFailure` — CloudKit network error fetching the snapshot.
    public func claim(preferring preferredSlot: Int?) async throws -> DeviceSlot {
        var lastSnapshotCount = 0

        for attempt in 0..<maxAttempts {
            // Backoff before retry (skip on the first attempt).
            if attempt > 0 {
                let base: TimeInterval = 0.1 * pow(2.0, Double(attempt - 1))
                let capped = min(base, 5.0)
                // Jitter: [0.5, 1.0) × capped to reduce thundering-herd.
                let jittered = capped * (0.5 + 0.5 * rng())
                logger.info("slot claim: attempt \(attempt), backoff \(String(format: "%.2f", jittered))s")
                try await sleep(jittered)
            }

            // Step 1: Fetch current registry snapshot (all 15 slot records).
            let snapshot = try await fetchSnapshot()
            lastSnapshotCount = snapshot.slots.count

            // Step 2: Run SlotTable decision logic.
            let now = clock
            let decision = snapshot.claimSlot(
                for: deviceUUID,
                preferring: preferredSlot,
                now: now
            )

            switch decision {

            case .freeSlot(let slotNumber):
                // Step 3a: Create a new slot record and CAS-insert it.
                let newSlot = DeviceSlot(
                    slot: slotNumber,
                    epoch: 1,
                    deviceUUID: deviceUUID,
                    lastActiveHLC: HLC.zero,
                    claimedAt: clock()
                )
                let newRecord = SlotRecordMapping.record(from: newSlot, zoneID: zoneID)
                if try await casModify(record: newRecord) {
                    logger.info("slot claim: claimed free slot \(slotNumber)")
                    return newSlot
                }
                // CAS failed — another device just claimed this slot. Retry.
                logger.info("slot claim: CAS failed on free slot \(slotNumber), retrying")

            case .evictionCandidate(let victim):
                // Step 3b: Evict and re-claim the victim slot.
                // We already have the fetched record (with change tag) from the snapshot.
                guard let victimRecord = snapshot.fetchedRecord(for: victim.slot) else {
                    // Snapshot is inconsistent (SlotTable said evict but record absent).
                    // Retry to get a fresh snapshot.
                    logger.warning("slot claim: eviction candidate \(victim.slot) missing from snapshot, retrying")
                    continue
                }
                let newEpoch = victim.epoch + 1
                let evictedSlot = DeviceSlot(
                    slot: victim.slot,
                    epoch: newEpoch,
                    deviceUUID: deviceUUID,
                    lastActiveHLC: HLC.zero,
                    claimedAt: clock()
                )
                // Populate the fetched record in place — preserves its change tag for CAS.
                SlotRecordMapping.populate(record: victimRecord, from: evictedSlot)
                if try await casModify(record: victimRecord) {
                    logger.info("slot claim: evicted slot \(victim.slot) (epoch \(victim.epoch) → \(newEpoch))")
                    return evictedSlot
                }
                // CAS failed — another device evicted the same slot first. Retry.
                logger.info("slot claim: CAS failed evicting slot \(victim.slot), retrying")

            case .exhausted:
                // All 15 slots occupied, no eligible eviction candidates.
                // This is a real operational event (15 concurrent machines).
                throw SyncError.slotExhausted(activeCount: lastSnapshotCount)
            }
        }

        // Exhausted all retry attempts with no successful claim.
        throw SyncError.slotExhausted(activeCount: lastSnapshotCount)
    }

    // MARK: - Private helpers

    /// Fetch all 15 slot records and build a RegistrySnapshot.
    private func fetchSnapshot() async throws -> RegistrySnapshot {
        let ids = SlotRecordMapping.allRecordIDs(zoneID: zoneID)
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.fetch(withRecordIDs: ids)
        } catch {
            throw SyncError.transportFailure(detail: "slot registry fetch: \(error)")
        }

        var slots: [DeviceSlot] = []
        var recordsBySlot: [Int: CKRecord] = [:]

        for (_, result) in results {
            if case .success(let record) = result {
                if let slot = try? SlotRecordMapping.slot(from: record) {
                    slots.append(slot)
                    recordsBySlot[slot.slot] = record
                }
            }
            // Failure entries mean the slot record doesn't exist → slot is free.
        }

        return RegistrySnapshot(table: SlotTable(slots: slots), recordsBySlot: recordsBySlot)
    }

    /// Perform a compare-and-swap save of `record` using `.ifServerRecordUnchanged`.
    ///
    /// Returns `true` if the CAS succeeded, `false` if serverRecordChanged was thrown
    /// (another device modified the record between our fetch and our save).
    ///
    /// All other errors are rethrown as `SyncError.transportFailure`.
    private func casModify(record: CKRecord) async throws -> Bool {
        do {
            _ = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
            return true
        } catch {
            // Check if any per-record result is a serverRecordChanged CAS loss.
            // We check the error as NSError (works for both real CKError from
            // production and NSError-fabricated from tests).
            let nsErr = error as NSError
            if nsErr.domain == CKErrorDomain && nsErr.code == CKError.Code.serverRecordChanged.rawValue {
                return false
            }
            // Also check for a batch error where individual record results carry serverRecordChanged.
            // modifyRecords(atomically: false) may throw a CKError.partialFailure where
            // individual records are in the userInfo.
            if nsErr.domain == CKErrorDomain, nsErr.code == CKError.Code.partialFailure.rawValue,
               let partialErrors = nsErr.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                let allServerRecordChanged = partialErrors.values.allSatisfy { perErr in
                    let ns = perErr as NSError
                    return ns.domain == CKErrorDomain && ns.code == CKError.Code.serverRecordChanged.rawValue
                }
                if allServerRecordChanged { return false }
            }
            throw SyncError.transportFailure(detail: "slot CAS save: \(error)")
        }
    }
}

// MARK: - RegistrySnapshot

/// Carries the SlotTable and the raw CKRecord objects (with their change tags)
/// from a single fetch of the registry. The records are needed for eviction CAS
/// (the existing record's change tag is required for .ifServerRecordUnchanged).
private struct RegistrySnapshot: Sendable {
    let table: SlotTable
    let recordsBySlot: [Int: CKRecord]

    /// Delegate `claimSlot` to the underlying `SlotTable`.
    func claimSlot(
        for deviceUUID: UUID,
        preferring slot: Int?,
        now: @Sendable () -> Date
    ) -> ClaimDecision {
        table.claimSlot(for: deviceUUID, preferring: slot, now: now)
    }

    var slots: [DeviceSlot] { table.slots }

    /// Look up the fetched CKRecord (with change tag) for a slot number.
    func fetchedRecord(for slot: Int) -> CKRecord? {
        recordsBySlot[slot]
    }
}
