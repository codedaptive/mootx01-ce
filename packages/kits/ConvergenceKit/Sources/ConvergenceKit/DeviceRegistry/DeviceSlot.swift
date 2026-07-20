// DeviceSlot.swift
//
// Model for a single entry in the shared device slot registry (N2).
//
// The HLC node field is 4 bits in the CKRecordMapping.packed() CloudKit wire
// layout (spec B-6: physical 48b | logical 12b | node 4b), giving 16
// addressable values. Slot 0 is permanently reserved: legacy shipped code
// fabricated HLCs with nodeID 0, so no registry-assigned identity may ever
// be ambiguous against those historical writes. That leaves slots 1–15 for
// concurrent live machines.
//
// A participating device owns one claimed slot and fence epoch.

import Foundation
import SubstrateTypes

/// One claimed entry in the 15-slot device registry.
///
/// The HLC 4-bit node field supports 16 values; slot 0 is permanently
/// reserved for pre-registry legacy HLCs (see file header). Assigning
/// slot 0 would make its HLCs ambiguous against legacy writes, producing
/// silent LWW divergence that cannot be detected or repaired after the fact.
public struct DeviceSlot: Sendable, Equatable {

    /// Registry slot number. Always in 1...15.
    ///
    /// Slot 0 is permanently reserved for legacy pre-registry HLCs. The
    /// shipped code drew `Int32.random(in: 1...0x0F)` per launch with no
    /// persistence, generating nodeID-0 HLCs on some launches. Those HLCs
    /// are undetectably ambiguous; no registry entry may ever use slot 0.
    public let slot: Int

    /// Epoch counter. Bumped every time this slot is evicted and re-claimed.
    ///
    /// A device that returns after eviction compares its stored epoch against
    /// the registry epoch: a mismatch means the slot was re-assigned (N2
    /// fencing protocol). The device must re-enroll before applying any records.
    public let epoch: Int64

    /// Stable device identity. Minted once per device/estate pair.
    /// Differentiates machines that share the same iCloud account.
    public let deviceUUID: UUID

    /// Most recent HLC timestamp the device sent as a heartbeat.
    ///
    /// `HLC.zero` means the slot was claimed but the device has never
    /// completed a heartbeat — this is the ghost-slot condition (adjudication
    /// A4). Ghost slots are eligible for fast-path eviction after `SlotGhostWindow`
    /// even though they would not qualify under the long-inactivity window.
    public let lastActiveHLC: HLC

    /// ISO8601 wall-clock timestamp when this slot was first claimed in
    /// its current epoch. Used together with `lastActiveHLC` to detect
    /// ghost slots: a slot is a ghost when `lastActiveHLC == .zero` and
    /// `claimedAt` is older than `SlotGhostWindow`.
    public let claimedAt: Date

    /// Designated initialiser.
    ///
    /// - Precondition: `slot` must be in `1...15`. Slot 0 is permanently
    ///   reserved for legacy pre-registry HLCs (see module-level comment).
    public init(slot: Int, epoch: Int64, deviceUUID: UUID,
                lastActiveHLC: HLC, claimedAt: Date) {
        precondition(
            (1...15).contains(slot),
            "DeviceSlot.slot must be 1–15; slot 0 is permanently reserved "
            + "for legacy pre-registry HLCs that used nodeID 0."
        )
        self.slot = slot
        self.epoch = epoch
        self.deviceUUID = deviceUUID
        self.lastActiveHLC = lastActiveHLC
        self.claimedAt = claimedAt
    }
}
