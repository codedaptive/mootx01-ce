// HLC.swift
//
// Hybrid Logical Clock per cookbook § 5.2.
//
// HLC gives partial ordering across replicas of an estate without
// requiring synchronized clocks. Every audit row carries an HLC
// timestamp; comparison is lexicographic on (physical, logical,
// node) and total within an estate.
//
// This is the mechanism that lets two replicas of an estate
// (e.g. iPhone + Mac sharing via CloudKit) exchange audit log
// entries in any order and project to identical visible state.
// The convergence proof in cookbook § 5.4 depends on HLC
// providing a total ordering that all replicas agree on.
//
// CONSTITUTIONAL: HLC supersedes v0.35's wall-clock `updatedAt`
// ordering. Existing v0.35 audit rows are upgraded at migration
// by treating `updatedAt` as physical_time, logical_count = 0,
// and node_id = legacy_node_id (cookbook § 16.2).

import Foundation

/// Hybrid Logical Clock timestamp. Comparable via lexicographic
/// (physical, logical, node) order.
///
/// `physicalTime`: wall-clock milliseconds since Unix epoch. May
///   be skewed across replicas; HLC tolerates skew up to the
///   logical-component cap.
///
/// `logicalCount`: monotonic counter that increments when
///   physical time does not advance (or when receiving a
///   message with a higher physical time than ours).
///
/// `nodeID`: per-replica identifier so two replicas with
///   identical (physical, logical) still order deterministically.
///   Typically the low 32 bits of a UUID-derived hash.
public struct HLC: Hashable, Sendable, Codable, Comparable {
    public let physicalTime: Int64
    public let logicalCount: Int32
    public let nodeID: Int32

    public init(physicalTime: Int64, logicalCount: Int32, nodeID: Int32) {
        self.physicalTime = physicalTime
        self.logicalCount = logicalCount
        self.nodeID = nodeID
    }

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        if lhs.physicalTime != rhs.physicalTime {
            return lhs.physicalTime < rhs.physicalTime
        }
        if lhs.logicalCount != rhs.logicalCount {
            return lhs.logicalCount < rhs.logicalCount
        }
        return lhs.nodeID < rhs.nodeID
    }

    public static let zero = HLC(physicalTime: 0, logicalCount: 0, nodeID: 0)

    // MARK: - Adapter API used by Block 2a/2b reference files
    //
    // These extensions let Block 2a/2b code use the canonical HLC
    // without further drift. The `nodeId` (camelCase 'd') label is
    // accepted as an alias for the canonical `nodeID` so files
    // authored before the package landed compile unchanged.

    /// Alias initializer using `nodeId` (camelCase 'd'). Forwards
    /// to the canonical `nodeID` field.
    public init(physicalTime: Int64, logicalCount: Int32, nodeId: Int32) {
        self.init(physicalTime: physicalTime,
                  logicalCount: logicalCount,
                  nodeID: nodeId)
    }

    /// Advance the logical counter by one; physical clock and
    /// node id are preserved.
    public func advanced() -> HLC {
        return HLC(physicalTime: self.physicalTime,
                   logicalCount: self.logicalCount &+ 1,
                   nodeID: self.nodeID)
    }

    /// Physical time, converted from the canonical milliseconds-
    /// since-epoch representation to whole seconds.
    public func physicalSecondsSinceEpoch() -> Int64 {
        return self.physicalTime / 1000
    }

    /// Pack to a canonical 8-byte representation per cookbook
    /// § 12.3 (wire-format for tier contribution fingerprints):
    ///
    ///   top 8 bits     = nodeID (low 8 bits)
    ///   next 16 bits   = logicalCount (low 16 bits)
    ///   bottom 40 bits = physicalTime (low 40 bits)
    ///
    /// 40 bits of milliseconds covers ~34 years. The 16-byte
    /// wireBytes form is the lossless format; `packed` is the
    /// lossy compact form federation messages use.
    public var packed: UInt64 {
        let node = UInt64(UInt8(truncatingIfNeeded: self.nodeID))
        let logical = UInt64(UInt16(truncatingIfNeeded: self.logicalCount))
        let phys = UInt64(self.physicalTime) & 0xFF_FFFF_FFFF
        return (node << 56) | (logical << 40) | phys
    }

    /// Recover an HLC from its 8-byte packed form. Inverse of
    /// `packed`.
    public init(packed: UInt64) {
        let node = Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: (packed >> 56) & 0xFF)))
        let logical = Int32(UInt16(truncatingIfNeeded: (packed >> 40) & 0xFFFF))
        let phys = Int64(packed & 0xFF_FFFF_FFFF)
        self.init(physicalTime: phys, logicalCount: logical, nodeID: node)
    }
}

/// Per-replica HLC generator. Thread-safe via the actor isolation
/// of the substrate's audit-writer; the reference here is the
/// pure-state machine.
///
/// Three operations follow the HLC paper (Kulkarni et al., 2014):
///
///   send(now):              "I'm emitting an event at wall time `now`."
///   receive(remote, now):   "I'm consuming an event; advance local."
///   currentTime():          read-only snapshot.
public struct HLCGenerator: Sendable {
    public let nodeID: Int32
    private var lastPhysical: Int64
    private var lastLogical: Int32

    public init(nodeID: Int32, lastPhysical: Int64 = 0,
                lastLogical: Int32 = 0) {
        self.nodeID = nodeID
        self.lastPhysical = lastPhysical
        self.lastLogical = lastLogical
    }

    /// Generate a timestamp for a locally-originated event. `now`
    /// is the current wall-clock time in milliseconds.
    public mutating func send(now: Int64) -> HLC {
        if now > lastPhysical {
            lastPhysical = now
            lastLogical = 0
        } else {
            // Physical clock didn't advance; bump logical.
            lastLogical &+= 1
        }
        return HLC(physicalTime: lastPhysical,
                   logicalCount: lastLogical,
                   nodeID: nodeID)
    }

    /// Update local state from a remote timestamp received over
    /// the network (e.g. CloudKit sync), then generate the local
    /// timestamp at which we processed the receive. `now` is our
    /// current wall-clock.
    public mutating func receive(remote: HLC, now: Int64) -> HLC {
        let maxPhysical = max(max(lastPhysical, remote.physicalTime), now)
        if maxPhysical == lastPhysical && maxPhysical == remote.physicalTime {
            // Both ours and theirs are at maxPhysical; logical is
            // max + 1.
            lastLogical = max(lastLogical, remote.logicalCount) &+ 1
        } else if maxPhysical == lastPhysical {
            lastLogical &+= 1
        } else if maxPhysical == remote.physicalTime {
            lastLogical = remote.logicalCount &+ 1
        } else {
            // maxPhysical == now: physical advanced.
            lastLogical = 0
        }
        lastPhysical = maxPhysical
        return HLC(physicalTime: lastPhysical,
                   logicalCount: lastLogical,
                   nodeID: nodeID)
    }

    /// Read-only snapshot of the current generator state.
    public func currentTime() -> HLC {
        return HLC(physicalTime: lastPhysical,
                   logicalCount: lastLogical,
                   nodeID: nodeID)
    }
}

// MARK: - Properties
//
//   monotonic per replica: every send() returns an HLC > previous.
//   causality preserved:    if A → B (send before receive),
//                           then HLC(A) < HLC(B).
//   total order:            any two HLCs compare unambiguously
//                           via Comparable.
//   skew tolerance:         physical-clock skew up to ~Int32.max
//                           milliseconds (~25 days); beyond that
//                           logical counter saturates and
//                           causality assertions weaken.
//
// In practice the substrate runs an NTP-synchronized wall clock
// across replicas; skew is bounded by seconds and HLC behaves
// indistinguishably from wall-clock with conflict resolution.

// MARK: - Serialization
//
// Wire format is 16 bytes: 8 bytes physicalTime LE + 4 bytes
// logicalCount LE + 4 bytes nodeID LE.

extension HLC {
    public var wireBytes: [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8((physicalTime >> shift) & 0xFF))
        }
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8((logicalCount >> shift) & 0xFF))
        }
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8((nodeID >> shift) & 0xFF))
        }
        return bytes
    }
}
