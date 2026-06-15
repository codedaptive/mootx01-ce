// EnrichmentRetryReads.swift
//
// GLK brain-layer surface methods for the maintenance daemon's
// QID-pending enrichment retry path (NEURONKIT_SPEC § 3.2, Board item 14).
//
// ── Why this lives in GeniusLocusKit, not NeuronKit ──────────────────
// B-1 invariant: NeuronKit never calls LocusKit directly. The GLK actor
// is the only legal write surface. These two methods expose the two
// operations the maintenance daemon's enrichment retry path needs:
//
//   1. `qidPendingDrawers(in:limit:)` — bounded scan of active drawers
//      whose provenance enrichment-status field (bits 36-41, cookbook
//      §2.5) is set to qid_pending (value 1). B-10a: internal maintenance
//      read, no trace_limit set, no recall-trace rows written.
//
//   2. `updateEnrichmentStatus(in:rowID:newProvenance:changedBy:now:)` —
//      write the new provenance bitmap for a drawer whose Q-ID retry
//      succeeded or whose retry result is recorded. Routes through
//      `Estate.mutateProvenance` (the same path `Estate.mutate(.confirm)`
//      uses for the confirmation field), writing an audit row atomically.
//
// Enrichment-status field layout (cookbook §2.5):
//   provenance bits 36-41, 6-bit field
//   shift = 36, width = 6
//   0 = none (not yet enriched), 1 = qid_pending, 2 = qid_completed,
//   3 = closure_cached, 4-63 reserved.
//
// ── Bounded scan strategy ─────────────────────────────────────────────
// `qidPendingDrawers` applies a row-limit cap (`QID_RETRY_SCAN_CAP = 64`)
// so the retry batch is O(cap) not O(estate). The cap is intentionally
// small: Q-ID resolution is expected to be rare and the batch should
// not starve other maintenance scans. Large estates with many pending
// drawers resolve them in successive maintenance cycles.
//
// Drawers are returned in `filedAt` ascending order (the store's natural
// order), making the bounded scan deterministic: same estate + same cap
// → same rows in the same order.

import Foundation
import LocusKit

/// Cap on the number of qid-pending drawers the maintenance daemon picks
/// up in a single retry batch. Bounded so the retry scan is O(cap)
/// rather than O(estate) per cycle. 64 drawers per cycle is sufficient
/// for normal estates; large estates with many pending drawers converge
/// over successive cycles.
public let QID_RETRY_SCAN_CAP: Int = 64

public extension GeniusLocusKit {

    /// Bounded scan of active drawers whose enrichment status is `qid_pending`.
    ///
    /// Reads all non-tombstoned, Cluster-A drawers from the estate and filters
    /// to those whose provenance bits 36-41 equal `qid_pending` (value 1 per
    /// cookbook §2.5). Uses `Drawer.enrichmentStatus` (a public computed
    /// property on LocusKit.Drawer that decodes those bits). Limited to `limit`
    /// rows (default `QID_RETRY_SCAN_CAP`) so the maintenance daemon's retry
    /// batch is O(cap), not O(estate).
    ///
    /// B-10a: internal maintenance read — no trace_limit set, no recall-trace
    /// rows written.
    ///
    /// - Parameters:
    ///   - handle: the estate to scan.
    ///   - limit: maximum number of drawers to return.
    /// - Returns: drawers with enrichment status `qid_pending`, in `filedAt`
    ///   ascending order, capped at `limit`.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    func qidPendingDrawers(
        in handle: EstateHandle,
        limit: Int = QID_RETRY_SCAN_CAP
    ) async throws -> [Drawer] {
        let estate = try estate(for: handle)
        let all = try await estate.allDrawers()
        // Filter to active (non-tombstoned, Cluster-A) drawers with
        // enrichment-status qid_pending. `Drawer.enrichmentStatus` decodes
        // provenance bits 36-41. The `isClusterA` check mirrors
        // EstateMaintenanceReader.activeDrawers().
        let pending = all.filter { drawer in
            guard drawer.tombstonedAt == nil && drawer.state.isClusterA else {
                return false
            }
            return drawer.enrichmentStatus == .qidPending
        }
        // Deterministic ordering: filedAt ascending (store's natural order).
        // Truncate to cap; successive maintenance cycles handle the remainder.
        return Array(pending.prefix(limit))
    }

    /// Update a drawer's provenance bitmap with a new enrichment status.
    ///
    /// Writes the new provenance value via `Estate.mutateProvenance`, which
    /// atomically appends an audit row (the same path `Estate.mutate(.confirm)`
    /// uses for the confirmation field). The caller supplies `newProvenance`
    /// as the full 64-bit provenance value constructed via
    /// `BitField.writeField`.
    ///
    /// B-1 compliant: routes through `Estate.mutateProvenance` — no SQL, no
    /// direct storage handle access from the caller or from NeuronKit.
    ///
    /// Determinism: `now` is the caller-supplied timestamp; never reads `Date()`
    /// internally per CLAUDE.md.
    ///
    /// - Parameters:
    ///   - handle: the estate containing the drawer.
    ///   - rowID: the drawer whose provenance to update.
    ///   - newProvenance: the full new provenance bitmap value.
    ///   - changedBy: audit provenance — the agent driving the update.
    ///   - now: deterministic timestamp.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale;
    ///   any LocusKit storage error if the row is absent.
    func updateEnrichmentStatus(
        in handle: EstateHandle,
        rowID: RowID,
        newProvenance: Int64,
        changedBy: String,
        now: Date
    ) async throws {
        let estate = try estate(for: handle)
        try await estate.mutateProvenance(
            rowID: rowID,
            newProvenance: newProvenance,
            changedBy: changedBy,
            reason: "maintenance: enrichment-status retry",
            now: now
        )
    }

    /// Complete an accepted enrichment proposal — the terminal resolution of
    /// the Q-ID-completion workflow.
    ///
    /// When an enrichment proposal (`ProposalKind.enrichment`, filed by the
    /// maintenance daemon for a drawer whose Q-ID deterministic inference
    /// could not resolve) is accepted with a human/agent-supplied Q-ID, this
    /// method completes the resolution in two atomic, audited writes:
    ///
    ///   1. Write the resolved Q-ID into the drawer's lattice anchor
    ///      (`Estate.reanchorAnchor`), preserving the existing MDCC code and
    ///      facets — the "anchor updates" half of the acceptance wire.
    ///   2. Flip the drawer's enrichment-status field (provenance bits 36-41)
    ///      from `qidProposed` (4) to `qidCompleted` (2)
    ///      (`Estate.mutateProvenance`) — the "provenance bits flip" half.
    ///
    /// After this call the drawer is fully resolved: its anchor carries the
    /// Q-ID and its enrichment status is terminal `qidCompleted`. The drawer
    /// is not re-picked by `qidPendingDrawers` (it never was, once moved to
    /// `qidProposed`), so the Q-ID-completion pipeline ends here.
    ///
    /// B-1 compliant: both writes route through estate verbs — no SQL, no
    /// direct storage handle access.
    ///
    /// Determinism: `now` is the caller-supplied timestamp; never reads
    /// `Date()` internally per CLAUDE.md.
    ///
    /// - Parameters:
    ///   - handle: the estate containing the drawer.
    ///   - rowID: the drawer whose enrichment proposal was accepted.
    ///   - wikidataQID: the resolved Q-ID supplied by the proposal acceptor.
    ///   - changedBy: audit provenance — the agent driving the resolution.
    ///   - now: deterministic timestamp.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale;
    ///   `LocusKitError.drawerNotFound` if the drawer is absent.
    func resolveEnrichmentProposal(
        in handle: EstateHandle,
        rowID: RowID,
        wikidataQID: String,
        changedBy: String,
        now: Date
    ) async throws {
        let estate = try estate(for: handle)
        // Read the drawer's current anchor so the existing MDCC code and
        // facets are preserved — only the Q-ID is being filled in.
        guard let drawer = try await estate.getDrawers(ids: [rowID]).first else {
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "resolveEnrichmentProposal: drawer not found: \(rowID)")
        }
        let resolvedAnchor = LatticeAnchor(
            udcCode: drawer.udcCode,
            udcFacets: drawer.udcFacets,
            wikidataQID: wikidataQID,
            wikidataQidsSecondary: drawer.wikidataQidsSecondary
        )
        // 1. Anchor update — write the resolved Q-ID into the anchor.
        try await estate.reanchorAnchor(
            rowID: rowID,
            toLattice: resolvedAnchor,
            changedBy: changedBy,
            now: now
        )
        // 2. Provenance flip — qidProposed (4) → qidCompleted (2). Preserve all
        //    other provenance bits by masking out bits 36-41 and OR-ing in 2.
        let statusMask: Int64 = 0x3F << 36
        let newProvenance = (drawer.provenance & ~statusMask)
            | (Int64(EnrichmentStatus.qidCompleted.rawValue) << 36)
        try await estate.mutateProvenance(
            rowID: rowID,
            newProvenance: newProvenance,
            changedBy: changedBy,
            reason: "enrichment proposal accepted: Q-ID resolved",
            now: now
        )
    }
}
