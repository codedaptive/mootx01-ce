// ChestRebin.swift — the chest re-bin duty (ADR-026; GENIUSLOCUSKIT_SPEC
// § DUTY_LIFECYCLE "Chest re-bin is a Class B duty", LocusKit spec § 12).
//
// A room is owed a re-bin when any of its containers (a chest, or the room
// itself while it holds drawers directly) is at or above
// `ChestPlacement.capacity`. One batch re-bins `chestRebinBatch` such rooms
// whole through `Estate.rebinRoom`: one sort, one transaction, one audit
// event. Afterwards the room's anomaly rosters are reconciled: rows of
// containers the re-bin retired are deleted, and every container still
// standing is marked owed so the sweep re-reads its membership. New chests
// have no row and are owed by construction.
//
// The anomaly sweep never scores a container at capacity (it skips it and
// leaves it to this duty), so `mootx01 drain` settles this duty before the
// sweep and a finished estate has no oversized container.

import EngramLib
import Foundation
import LocusKit
import MootProductIdentity
import OSLog
import QueueKit

public extension GeniusLocusKit {

    /// The rooms owed a re-bin: any container at or above capacity.
    func chestRebinOwedRooms(_ handle: EstateHandle) async throws -> [(wing: String, room: String)] {
        let estate = try estate(for: handle)
        var owed: [(wing: String, room: String)] = []
        for entry in try await estate.roomLevelFingerprints() {
            let containers = try await estate.containers(in: entry.wing, room: entry.room)
            if containers.contains(where: { $0.count >= ChestPlacement.capacity }) {
                owed.append((entry.wing, entry.room))
            }
        }
        return owed
    }

    /// One re-bin batch: up to `limit` owed rooms, each re-binned whole.
    /// Returns the rooms re-binned; the duty queue carries the rest forward.
    func runChestRebinBatch(_ handle: EstateHandle, limit: Int, now: Date) async throws -> Int {
        let estate = try estate(for: handle)
        let checkpoints = try await factCheckpoints(handle)
        var rebinned = 0
        for (wing, room) in try await chestRebinOwedRooms(handle).prefix(max(0, limit)) {
            let before = Set(try await estate.containers(in: wing, room: room).map { $0.chestNodeId.lowercased() })
            try await estate.rebinRoom(wing: wing, room: room, now: now)
            let after = try await anomalyContainers(estate: estate, wing: wing, room: room)
            let standing = Set(after.map { $0.0.nodeId.lowercased() })
            for retired in before.subtracting(standing) {
                _ = try await checkpoints.delete(id: Self.anomalySweepRosterID(containerNodeId: retired),
                                                 stream: Self.anomalySweepStream)
            }
            for (container, _) in after {
                try await markAnomalySweepContainerDirty(container, for: handle, now: now)
            }
            rebinned += 1
        }
        if rebinned > 0 {
            Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit")
                .debug("chestRebinBatch: \(rebinned, privacy: .public) room(s) re-binned")
        }
        return rebinned
    }
}
