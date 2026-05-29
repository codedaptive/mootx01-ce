import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
import SubstrateTypes

/// Estate audit and history API. Per spec § 7.8.7.
///
/// Three methods sit on `Estate` here: two flavours of `auditTrail`
/// (per-row and time-range) and a historical `bitmapState`
/// reconstruction. All three are async-throws to match the rest of
/// the verb surface and to keep `DrawerStore` access inside the
/// actor's isolation boundary.
///
/// The XOR-fold reconstruction in `bitmapState` re-implements the
/// spec § 6.8 formula inline rather than calling
/// `BitmapEvaluator.reconstructBitmap` — that helper is `private` on
/// `BitmapEvaluator` and the mission explicitly chose not to broaden
/// its visibility. Holding the two implementations apart costs ~6
/// lines of duplication and avoids a cross-file private->internal
/// rewrite that would expand the mission's blast radius.
public extension Estate {

    // MARK: - auditTrail

    /// All bitmap audit rows for a single row, ordered by timestamp
    /// ascending. Returns an empty array when no mutations have been
    /// recorded for that row — capture itself is an INSERT, not a
    /// mutation, so a freshly-captured drawer's trail is empty until
    /// its first `withdraw` / `mutateAdjective` / `mutateOperational`
    /// call.
    ///
    /// The row's audit history — the sealed audit events in HLC order
    /// (DECISION_CLOCK_TRIANGLE_TIME_MODEL: the audit log is the source
    /// of truth; events are snapshots, not deltas). Empty until the
    /// row's first gated mutation.
    ///
    /// - Parameter rowID: the drawer's stable id (a UUID).
    /// - Returns: the row's audit events in HLC order.
    ///
    /// The cross-row wall-clock window form (`auditTrail(since:until:)`)
    /// was dropped in the audit-log migration: it queried a wall-clock
    /// range, which is not a fold/ordering axis in the HLC model (§11).
    func auditTrail(rowID: RowID) async throws -> [AuditEvent] {
        let rowUuid = try DrawerStore.requireUuid(rowID, label: "rowID")
        return try await store.auditEventsForRow(rowUuid)
    }

    // MARK: - bitmapState

    /// Reconstruct the bitmap state of a row at a specific HLC.
    ///
    /// Folds the row's audit log via `AuditLogFold.projectStateAt`
    /// (cookbook § 5.3): events at or before `asOf` are replayed in
    /// HLC order starting from the genesis capture event, producing
    /// the projected `(adjective, operational, provenance)` snapshot.
    /// State is keyed on HLC, not wall-clock
    /// (DECISION_CLOCK_TRIANGLE_TIME_MODEL §11: wall-clock is not a
    /// fold axis).
    ///
    /// All three bitmap columns are reconstructed from the same fold
    /// because each `AuditEvent` carries the after-snapshot for all
    /// columns; the audit log is a single sequence per row, not a
    /// per-column partition.
    ///
    /// - Parameters:
    ///   - rowID: the drawer's stable id.
    ///   - asOf: the HLC at which to reconstruct state.
    /// - Returns: a `BitmapState` snapshot at `asOf`.
    /// - Throws: `LocusKitError.drawerNotFound` when the row has no
    ///   events at or before `asOf` (it did not exist yet at that
    ///   point — the genesis capture event is the earliest fact in
    ///   the log).
    func bitmapState(rowID: RowID, asOf: HLC) async throws -> BitmapState {
        // State is reconstructed by folding the audit log in HLC order
        // (DECISION_CLOCK_TRIANGLE_TIME_MODEL: state evolves in ingest-HLC
        // order; wall-clock is not a fold axis — §11 rejected dual-clock
        // projection). The old XOR-fold over bitmap_audit deltas is
        // replaced by AuditLogFold.projectStateAt, the substrate primitive.
        let rowUuid = try DrawerStore.requireUuid(rowID, label: "rowID")
        let events = try await store.auditEventsForRow(rowUuid)
        guard let projected = AuditLogFold.projectStateAt(
            rowId: rowUuid, nounType: .drawer, events: events, asOf: asOf)
        else {
            // No events at or before `asOf` — the row did not exist yet.
            throw LocusKitError.drawerNotFound(id: rowID)
        }
        return BitmapState(
            rowID: rowID, asOf: asOf,
            adjectiveBitmap: projected.adjectiveBitmap,
            operationalBitmap: projected.operationalBitmap,
            provenanceBitmap: projected.provenanceBitmap
        )
    }

}
