// SurfacedRecallLedger.swift — per-session record of drawer ids surfaced to the
// AI client by `moot_memory_search`.
//
// The ledger is the ARIA boundary implementation of the trace-reward wiring
// (DESIGN_TRACE_REWARD_2026-06-12). When `moot_memory_search` surfaces a
// drawer, its id is recorded here with the wall-clock time of the recall.
// When a subsequent dereference verb (`moot_withdraw_memory`,
// `moot_update_memory`, `moot_confirm_memory`, `moot_move_memory`) acts on a
// drawer id that is present in the ledger, `noteUsage` in ToolDispatch calls
// `kit.markRecallUsed` so the dreaming daemon's reward sweep later assigns
// reward 1.0.
//
// Scope of "used" (option E from the design memo = B∪C):
//   - "surfaced" = the id appeared in a `moot_memory_search` result within
//     the current stdio / HTTP session.
//   - "used" = the same id appears in a later dereference call.
//   - Graph verbs (`moot_link_memories`, `moot_connection_map`) are NOT
//     dereference verbs in v1 (read-only blind spot; accepted per design).
//
// Session scope: one ledger per `ToolDispatcher` instance, i.e., one per
// stdio connection or HTTP session. Entries are never pruned during the
// session; memory footprint is bounded by session length × average result
// set size.
//
// Structural difference from Rust: Rust wraps a `HashMap` in a `Mutex`
// for interior mutability on `&self`. Swift uses an `actor` for the same
// guarantee — serial execution, no data races, Sendable conformance.
// Behavioral semantics are identical: `recordSurfaced` overwrites any
// existing entry for the same id (last surfaced_at wins), `entry(for:)`
// returns nil when the id was never surfaced.

import Foundation

/// One entry in the session ledger.
struct LedgerEntry: Sendable {
    /// The drawer id that was surfaced.
    let drawerID: String
    /// Wall-clock time when the drawer was surfaced by `moot_memory_search`.
    /// Stored as a `Date` so callers can pass it directly to GLK.
    let surfacedAt: Date
}

/// Session-scoped ledger of drawer ids that were returned to the AI client
/// by `moot_memory_search`. Thread-safe via Swift actor isolation.
///
/// Use `recordSurfaced(_:at:)` after a `moot_memory_search` call.
/// Use `entry(for:)` from a dereference verb to retrieve the entry that
/// enables reward-trace marking.
actor SurfacedRecallLedger: Sendable {

    // map: drawerID → LedgerEntry (last surfacedAt wins on duplicates)
    private var inner: [String: LedgerEntry] = [:]

    /// Create a new empty ledger.
    init() {}

    /// Record that `drawerIDs` were just surfaced by `moot_memory_search`.
    ///
    /// `at` is the wall-clock time of the recall. Any existing entry for the
    /// same id is overwritten with the latest `surfacedAt` so the retention
    /// window stays current.
    func recordSurfaced(_ drawerIDs: [String], at surfacedAt: Date) {
        for id in drawerIDs {
            inner[id] = LedgerEntry(drawerID: id, surfacedAt: surfacedAt)
        }
    }

    /// Look up the ledger entry for `drawerID`. Returns `nil` if the id was
    /// never surfaced in this session.
    func entry(for drawerID: String) -> LedgerEntry? {
        inner[drawerID]
    }

    /// Returns true if `drawerID` was surfaced in this session.
    func contains(_ drawerID: String) -> Bool {
        inner[drawerID] != nil
    }
}
