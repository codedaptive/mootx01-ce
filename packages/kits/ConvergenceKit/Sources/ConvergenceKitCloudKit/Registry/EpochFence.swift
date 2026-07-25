// EpochFence.swift
//
// Push-path epoch fence: verifies this device's (slot, epoch) is still current
// at the start of each push cycle, and updates last_active_hlc as a heartbeat.
//
// PROTOCOL:
// 1. Fetch this device's own slot record from CloudKit (gets current epoch +
//    the change tag needed for a conditional save).
// 2. If the record is absent: slot was deleted (unexpected) — treat as reenroll.
// 3. Compare the fetched epoch to the locally stored epoch.
//    Mismatch: the slot was evicted and re-epoch'd while this device was away.
//    Throw reenrollRequired BEFORE any outbox records are read. Applying records
//    under a superseded nodeID would produce HLC collisions that different
//    replicas resolve differently (silent LWW divergence).
// 4. Update last_active_hlc on the fetched record (in-place, preserving
//    the change tag) and conditional-save with .ifServerRecordUnchanged.
// 5. If the conditional save fails (serverRecordChanged): another device
//    concurrently modified our slot record (extremely rare — only possible if
//    two devices share the same slot, which the claim flow prevents; or the
//    device was evicted mid-push). Treat as reenrollRequired.
//
// WHY HEARTBEAT DOUBLES AS FENCE:
// The conditional save has two effects: it updates last_active_hlc (marking the
// device active so it isn't evicted) AND it verifies the slot record hasn't
// changed (epoch check). A single round-trip does both.
//
// Adjudications: A4 (heartbeat updates lastActiveHLC), A5 (reenrollRequired
// is loud, not silent).
// Epoch fencing prevents a stale claimant from minting new outbound records.

import Foundation
import CloudKit
import ConvergenceKit
import SubstrateTypes
import os

private let logger = Logger(subsystem: "com.mootx01.synckit.cloudkit", category: "EpochFence")

// MARK: - EpochFence

/// Verifies that this device's (slot, epoch) claim is still current before
/// each push cycle, and updates last_active_hlc as a heartbeat signal.
///
/// Stateless: all inputs are parameters so the fence is fully testable
/// without building a live engine instance.
public enum EpochFence {

    /// Verify the epoch fence and heartbeat for this push cycle.
    ///
    /// Fetches this device's slot record from CloudKit, checks that the stored
    /// epoch matches the locally held epoch, then saves an updated last_active_hlc
    /// via a conditional save (compare-and-swap). Must be called at the START of
    /// each push cycle, BEFORE reading the outbox batch.
    ///
    /// - Parameters:
    ///   - identity: This device's current (slot, epoch, deviceUUID) from DeviceIdentityStore.
    ///   - currentHLC: The HLC to stamp as last_active_hlc on the heartbeat save.
    ///   - database: The injectable database seam.
    ///   - zoneID: The manifest's sync zone where the slot record lives.
    ///
    /// - Throws:
    ///   - `SyncError.reenrollRequired(slot:staleEpoch:currentEpoch:)` — the slot's
    ///     epoch on CloudKit has changed (slot was evicted while this device was away),
    ///     OR the conditional save was rejected (extremely rare concurrent eviction).
    ///     The engine must re-claim a fresh slot and re-mint outbox HLCs before pushing.
    ///   - `SyncError.transportFailure(detail:)` — CloudKit fetch or save error.
    public static func heartbeat(
        identity: DeviceIdentity,
        currentHLC: HLC,
        database: any CloudKitDatabaseProtocol,
        zoneID: CKRecordZone.ID
    ) async throws {
        let recordID = SlotRecordMapping.recordID(slot: identity.slot, zoneID: zoneID)

        // Step 1: Fetch this device's slot record.
        let fetchResults: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            fetchResults = try await database.fetch(withRecordIDs: [recordID])
        } catch {
            throw SyncError.transportFailure(detail: "EpochFence fetch slot \(identity.slot): \(error)")
        }

        // Step 2: Verify the record exists.
        guard let fetchResult = fetchResults[recordID] else {
            // Record not found: slot was deleted from the registry (e.g. server reset).
            // Treat as reenroll — the engine will claim a fresh slot.
            logger.warning("epoch fence: slot \(identity.slot) record absent from registry → reenrollRequired")
            throw SyncError.reenrollRequired(
                slot: identity.slot,
                staleEpoch: Int(identity.epoch),
                currentEpoch: 0
            )
        }

        let slotRecord: CKRecord
        switch fetchResult {
        case .success(let r):
            slotRecord = r
        case .failure(let err):
            throw SyncError.transportFailure(detail: "EpochFence fetch slot \(identity.slot): \(err)")
        }

        // Step 3: Read the epoch from the fetched record.
        guard let remoteEpoch = slotRecord["epoch"] as? Int64 else {
            throw SyncError.decodingFailure(
                detail: "EpochFence: slot \(identity.slot) record missing epoch field"
            )
        }

        // Step 3b: Epoch mismatch → this device was evicted while inactive.
        // Throw BEFORE reading any outbox entries: pushing records under the old
        // nodeID would produce HLC collisions whose LWW ties resolve differently
        // on different replicas (silent divergence). Loud failure is correct here.
        if remoteEpoch != identity.epoch {
            logger.warning(
                "epoch fence: slot \(identity.slot) epoch mismatch local=\(identity.epoch) remote=\(remoteEpoch) → reenrollRequired"
            )
            throw SyncError.reenrollRequired(
                slot: identity.slot,
                staleEpoch: Int(identity.epoch),
                currentEpoch: Int(remoteEpoch)
            )
        }

        // Step 4: Update last_active_hlc in place (preserving the change tag)
        // and do a conditional save. This is the heartbeat: it tells other devices
        // this slot is still active so they don't evict it.
        slotRecord["last_active_hlc"] = Int64(bitPattern: currentHLC.packed) as CKRecordValue

        do {
            _ = try await database.modifyRecords(
                saving: [slotRecord],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )
            logger.debug("epoch fence: heartbeat ok for slot \(identity.slot) epoch \(identity.epoch)")
        } catch {
            // Check if the failure is a serverRecordChanged CAS loss.
            // (Works for both real CKError from CloudKit and NSError fabricated in tests.)
            let nsErr = error as NSError
            let isServerRecordChanged: Bool
            if nsErr.domain == CKErrorDomain && nsErr.code == CKError.Code.serverRecordChanged.rawValue {
                isServerRecordChanged = true
            } else if nsErr.domain == CKErrorDomain, nsErr.code == CKError.Code.partialFailure.rawValue,
                      let partials = nsErr.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
                      partials.values.contains(where: { perErr in
                          let ns = perErr as NSError
                          return ns.domain == CKErrorDomain && ns.code == CKError.Code.serverRecordChanged.rawValue
                      }) {
                isServerRecordChanged = true
            } else {
                isServerRecordChanged = false
            }

            if isServerRecordChanged {
                // Another device modified our slot record since our fetch (very rare —
                // only possible if two devices simultaneously hold the same slot due to
                // a prior claim race, or the device was evicted by a concurrent evictor).
                // Extract the server epoch from the CKError's serverRecord if available.
                let serverEpoch: Int64
                if let ckErr = error as? CKError,
                   let serverRecord = ckErr.serverRecord,
                   let ep = serverRecord["epoch"] as? Int64 {
                    serverEpoch = ep
                } else {
                    // Conservative fallback: assume epoch was bumped.
                    serverEpoch = remoteEpoch + 1
                }
                logger.warning(
                    "epoch fence: heartbeat CAS rejected for slot \(identity.slot), serverEpoch=\(serverEpoch) → reenrollRequired"
                )
                throw SyncError.reenrollRequired(
                    slot: identity.slot,
                    staleEpoch: Int(identity.epoch),
                    currentEpoch: Int(serverEpoch)
                )
            }

            throw SyncError.transportFailure(detail: "EpochFence heartbeat save: \(error)")
        }
    }
}
