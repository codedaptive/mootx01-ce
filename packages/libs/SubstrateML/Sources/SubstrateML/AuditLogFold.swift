// AuditLogFold.swift
//
// Audit-log fold per cookbook § 8.15 (which refers back to § 5.3
// for the canonical specification).
//
// The substrate's audit log is a G-Set CRDT (§ 5.1, I-20). The
// current visible state of any row is a deterministic projection
// (fold) over its audit history, ordered by hybrid logical clock
// (HLC). The same projection truncated at an arbitrary HLC `T`
// yields the row's state AS OF `T`, which is the substrate's
// asOf-reconstruction primitive.
//
//   project_current(R)        = fold(events(R) sorted by HLC asc)
//   project_at(R, T)          = fold(events(R) with HLC ≤ T sorted asc)
//
// The fold is pure, deterministic, and depends only on the set
// of events (not their arrival order). Sync convergence (I-21)
// follows directly: two replicas that have exchanged all events
// project to identical state.
//
// This reference makes the fold a standalone primitive consumable
// by recall, sync-reconciliation, disaster-recovery rebuild, and
// federation asOf-replay. The verb dispatch in Verbs.swift uses
// this fold inside its `recall(asOf:)` path.
//
// Cookbook references:
//   § 5.1   G-Set CRDT (I-20)
//   § 5.3   Projection rules
//   § 5.4   Sync convergence (I-21)
//   § 5.5   Reconstruction from audit log
//   § 8.15  Audit log fold (refers back to § 5.3)

import Foundation
import SubstrateTypes

// MARK: - Projected row state
//
// The fold reconstructs three fields per row: the three bitmaps
// and the lattice anchor. Fingerprint is derived from the
// bitmaps + lattice anchor + manifest hyperplane seeds and is
// not stored on the projected state directly; the caller
// recomputes if needed.

public struct ProjectedRowState: Sendable, Equatable {
    public var rowId: UUID
    public var nounType: NounType
    public var stateRaw: UInt8
    public var adjectiveBitmap: Int64
    public var operationalBitmap: Int64
    public var provenanceBitmap: Int64
    public var latticeAnchor: LatticeAnchor
    public var tombstoned: Bool
    /// HLC of the last event that affected this row. Stable
    /// post-projection.
    public var lastEventHLC: HLC

    public init(rowId: UUID, nounType: NounType, stateRaw: UInt8,
                adjectiveBitmap: Int64, operationalBitmap: Int64,
                provenanceBitmap: Int64, latticeAnchor: LatticeAnchor,
                tombstoned: Bool, lastEventHLC: HLC) {
        self.rowId = rowId
        self.nounType = nounType
        self.stateRaw = stateRaw
        self.adjectiveBitmap = adjectiveBitmap
        self.operationalBitmap = operationalBitmap
        self.provenanceBitmap = provenanceBitmap
        self.latticeAnchor = latticeAnchor
        self.tombstoned = tombstoned
        self.lastEventHLC = lastEventHLC
    }
}

// MARK: - The fold

public enum AuditLogFold {

    /// Project a single row's current state from its audit events.
    /// Events MAY be passed in any order; the fold sorts by HLC.
    public static func projectCurrentState(
        rowId: UUID, nounType: NounType, events: [AuditEvent]
    ) -> ProjectedRowState? {
        let ordered = events.filter { $0.rowId == rowId }
                             .sorted { $0.hlc < $1.hlc }
        return foldOrdered(rowId: rowId, nounType: nounType, ordered: ordered)
    }

    /// Project a single row's state AS OF a specific HLC.
    /// Events later than `asOf` are excluded; the projection is
    /// the state the row had at that point in time.
    public static func projectStateAt(
        rowId: UUID, nounType: NounType, events: [AuditEvent], asOf: HLC
    ) -> ProjectedRowState? {
        let truncated = events.filter { $0.rowId == rowId && $0.hlc <= asOf }
                               .sorted { $0.hlc < $1.hlc }
        return foldOrdered(rowId: rowId, nounType: nounType, ordered: truncated)
    }

    /// Project the entire substrate from its audit events. Returns
    /// a dict of all rows that were captured AT OR BEFORE the
    /// `asOf` HLC (or all rows if `asOf` is nil).
    public static func projectAll(
        events: [AuditEvent], asOf: HLC? = nil,
        nounTypeFor: (UUID) -> NounType
    ) -> [UUID: ProjectedRowState] {
        let truncated: [AuditEvent]
        if let cutoff = asOf {
            truncated = events.filter { $0.hlc <= cutoff }
        } else {
            truncated = events
        }
        let sorted = truncated.sorted { $0.hlc < $1.hlc }
        var byRow: [UUID: [AuditEvent]] = [:]
        for event in sorted {
            byRow[event.rowId, default: []].append(event)
        }
        var result: [UUID: ProjectedRowState] = [:]
        for (rid, rowEvents) in byRow {
            if let proj = foldOrdered(rowId: rid,
                                        nounType: nounTypeFor(rid),
                                        ordered: rowEvents) {
                result[rid] = proj
            }
        }
        return result
    }

    // MARK: - Internal fold

    /// Apply ordered events to build the projected state.
    /// Returns nil if the row has no events (was never captured).
    private static func foldOrdered(
        rowId: UUID, nounType: NounType, ordered: [AuditEvent]
    ) -> ProjectedRowState? {
        guard let first = ordered.first else { return nil }
        var state = ProjectedRowState(
            rowId: rowId,
            nounType: nounType,
            stateRaw: UInt8(first.afterBitmaps.adjective & 0x3F),
            adjectiveBitmap: first.afterBitmaps.adjective,
            operationalBitmap: first.afterBitmaps.operational,
            provenanceBitmap: first.afterBitmaps.provenance,
            latticeAnchor: first.afterLatticeAnchor,
            tombstoned: (UInt8(first.afterBitmaps.adjective & 0x3F) == 33),
            lastEventHLC: first.hlc)
        for event in ordered.dropFirst() {
            state.adjectiveBitmap = event.afterBitmaps.adjective
            state.operationalBitmap = event.afterBitmaps.operational
            state.provenanceBitmap = event.afterBitmaps.provenance
            state.stateRaw = UInt8(event.afterBitmaps.adjective & 0x3F)
            state.latticeAnchor = event.afterLatticeAnchor
            state.tombstoned = state.tombstoned || (state.stateRaw == 33)
            state.lastEventHLC = event.hlc
        }
        return state
    }
}

// MARK: - Properties
//
//   determinism:        same event set ⇒ same projection (events
//                       are sorted internally; arrival order
//                       does not matter).
//   commutativity:      projectAll(events) == projectAll(perm(events))
//                       for any permutation perm.
//   monotone-time:      for T1 ≤ T2, projectStateAt(asOf: T1) is a
//                       "prefix" of projectStateAt(asOf: T2) in the
//                       sense that the row may have had further
//                       mutations between T1 and T2 but none before.
//   tombstone-sticky:   once `state == tombstoned` appears in the
//                       event sequence, `tombstoned` remains true
//                       in subsequent state, even if a later
//                       (illegal) event tried to revive — the
//                       projection records the fact-of-tombstone
//                       per I-22.
//
// MARK: - Cookbook references
//   § 5.1   G-Set CRDT semantics
//   § 5.3   Projection rules (canonical algorithm)
//   § 5.4   Sync convergence proof
//   § 5.5   Reconstruction (rebuild_from_audit)
//   § 8.15  Reference back to § 5.3
