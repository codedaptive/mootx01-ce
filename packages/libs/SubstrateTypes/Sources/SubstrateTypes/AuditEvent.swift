// AuditEvent.swift
//
// Phase 6.6 (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.6)
// Moved from SubstrateLib/Sources/SubstrateLib/Verbs.swift.
//
// A single audit row. Cookbook § 5.1 (G-Set CRDT). Stored by
// GSetAuditLog under HLC ordering. Pure data; the audit gate
// that admits AuditEvents (and the CRDT log that holds them)
// stay in SubstrateLib.

import Foundation

/// A single audit row. Cookbook § 5.1 (G-Set CRDT). Stored by
/// GSetAuditLog under HLC ordering.
public struct AuditEvent: Sendable {
    /// Stable unique identifier for this event. The compound key
    /// (eventID, hlc) gives append idempotence in PersistenceKit's
    /// AuditLog: receiving the same event twice (e.g. via sync)
    /// is a no-op. Generated at construction; never mutated.
    public let eventID: UUID
    public let estateUuid: UUID
    public let rowId: UUID
    public let hlc: HLC
    public let verb: String
    public let beforeBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)?
    public let afterBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)
    public let beforeLatticeAnchor: LatticeAnchor?
    public let afterLatticeAnchor: LatticeAnchor
    public let actor: String   // capture | mcp_agent | dreaming_daemon | actuator | ...

    public init(eventID: UUID = UUID(),
                estateUuid: UUID, rowId: UUID, hlc: HLC, verb: String,
                beforeBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)?,
                afterBitmaps: (adjective: Int64, operational: Int64, provenance: Int64),
                beforeLatticeAnchor: LatticeAnchor?,
                afterLatticeAnchor: LatticeAnchor,
                actor: String) {
        self.eventID = eventID
        self.estateUuid = estateUuid
        self.rowId = rowId
        self.hlc = hlc
        self.verb = verb
        self.beforeBitmaps = beforeBitmaps
        self.afterBitmaps = afterBitmaps
        self.beforeLatticeAnchor = beforeLatticeAnchor
        self.afterLatticeAnchor = afterLatticeAnchor
        self.actor = actor
    }
}
