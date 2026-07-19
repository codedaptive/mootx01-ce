// FieldLWWMerge.swift
//
// Pure, stateless merge logic for the `fieldLevelLWW` conflict policy.
//
// COMMUTATIVITY GUARANTEE:
// `merge(...)` is commutative: applying record A then record B, or
// record B then record A, produces the same final state per column.
//
// Proof sketch: for each column, the result is the value from whichever
// record has the higher HLC. If the HLCs are equal (true tie), the
// incoming record loses and the local state is preserved — both orderings
// converge on the same value because a tie is broken identically in
// both directions (local always preferred on tie, i.e., strict ">=").
//
// WHY strict >= for apply (not >):
// "Apply column iff incoming HLC >= local HLC" means the incoming
// record wins ties. A strict > would mean neither side wins on a
// perfect tie — both replicas would keep their current value and
// the tie is never resolved. >= ensures at least one side can advance.
//
// TOMBSTONE INTERPLAY (edit-beats-delete):
// A tombstone HLC beats a local column HLC only when the tombstone
// HLC is >= ALL local column HLCs. If even one local column has an HLC
// strictly greater than the tombstone, the row was edited after the
// delete — the edit wins and the row is preserved. This is the
// "edit-beats-delete" rule. An empty local column HLC map means the
// row has never been field-LWW written; tombstone wins unconditionally.
//
// WHY NOT compare the tombstone to the row-grain HLC from _ck_sync_meta:
// _ck_sync_meta stores the row-grain HLC of the last full-row write.
// Under fieldLevelLWW, individual columns may have been written at
// different times. A tombstone that arrived between two column writes
// should beat the earlier write but lose to the later one. The row-grain
// HLC cannot express this — it is the HLC of the last SyncRecord that
// wrote the row, which may itself have been a partial fieldLevelLWW
// apply. Column-grain HLCs are the only correct comparison.
//
// WHY array/blob columns merge atomically:
// See ColumnHLCMap.swift — no sub-field addressing protocol exists.
// The whole column value wins or loses as one unit.

import Foundation
import PersistenceKit
import SubstrateTypes

// MARK: - FieldLWWMerge

/// Pure, stateless merge logic for the `fieldLevelLWW` conflict policy.
///
/// All functions are static. No state is held; inputs and outputs are
/// value types. This makes the merge trivially testable and composable.
public enum FieldLWWMerge {

    // MARK: - Column merge

    /// Compute which columns from an incoming record should be applied
    /// to local storage, given the local column HLC state.
    ///
    /// For each column in `incomingValues`:
    ///   - If the incoming column HLC is not present (sender did not
    ///     send per-column HLCs), fall back to comparing the row-grain
    ///     `incomingRowHLC` to the local column HLC.
    ///   - If the incoming column HLC >= the local column HLC (or the
    ///     local column has no recorded HLC), the column is applied.
    ///   - Otherwise the column is skipped.
    ///
    /// The returned `updatedColumnHLCs` is the union of the local and
    /// incoming maps, keeping the highest HLC per column. The caller
    /// must persist this map to `ColumnHLCStore` after applying the
    /// columns to the application row.
    ///
    /// GAP 6 VERIFICATION: the `>=` comparison below relies on
    /// `PackedHLC: Comparable` (ColumnHLCMap.swift), which compares the raw
    /// `physicalTime`/`logicalCount`/`nodeID` fields lexicographically —
    /// already full-width, lossless, with no bit-packing. This function
    /// required NO CHANGE for gap 6: the defect was entirely in
    /// `localColumnHLCs`' PROVENANCE (read from `_ck_sync_meta_cols` via the
    /// formerly-truncating `ColumnHLCStore.readAll`) being compared against
    /// a lossless `incomingColumnHLC` — a width MISMATCH, not a comparison-
    /// logic bug. Once `ColumnHLCStore.readAll`/`writeAll` both use the
    /// full-width columns, `local` and `incomingColumnHLC` are both
    /// full-width `PackedHLC` values and this existing `>=` is already
    /// correct.
    ///
    /// - Parameters:
    ///   - incomingValues: Row values from the incoming SyncRecord.
    ///   - incomingColumnHLCs: Per-column HLCs from the incoming record.
    ///     May be empty when the sender does not support fieldLevelLWW
    ///     (backward-compat: treat all columns as incoming at incomingRowHLC).
    ///   - incomingRowHLC: Row-grain HLC from SyncRecord.hlc. Used as
    ///     fallback when `incomingColumnHLCs` is empty or does not have
    ///     an entry for a specific column.
    ///   - localColumnHLCs: The local per-column HLC map from ColumnHLCStore.
    ///     May be empty on first receive for this row.
    /// - Returns: A tuple of the columns to apply and the updated
    ///   per-column HLC map to persist.
    public static func merge(
        incomingValues: [String: TypedValue],
        incomingColumnHLCs: ColumnHLCMap,
        incomingRowHLC: PackedHLC,
        localColumnHLCs: ColumnHLCMap
    ) -> (columnsToApply: [String: TypedValue], updatedColumnHLCs: ColumnHLCMap) {
        var columnsToApply: [String: TypedValue] = [:]
        var updatedEntries = localColumnHLCs.entries

        for (column, value) in incomingValues {
            // Determine the HLC to compare for this column.
            // Prefer the per-column HLC from the sender; fall back to
            // the row-grain HLC when not present (backward-compat).
            let incomingColumnHLC: PackedHLC = incomingColumnHLCs.entries[column] ?? incomingRowHLC

            let localColumnHLC = localColumnHLCs.entries[column]

            let shouldApply: Bool
            if let local = localColumnHLC {
                // Apply iff incoming HLC >= local HLC.
                // Ties go to incoming (>= not >) so convergence is guaranteed
                // even when two replicas simultaneously write the same HLC.
                shouldApply = incomingColumnHLC >= local
            } else {
                // No local HLC recorded for this column — first write wins.
                shouldApply = true
            }

            if shouldApply {
                columnsToApply[column] = value
                // Update the stored HLC to the winner.
                updatedEntries[column] = incomingColumnHLC
            }
        }

        return (columnsToApply, ColumnHLCMap(entries: updatedEntries))
    }

    // MARK: - Tombstone interplay (edit-beats-delete)

    /// Decide whether an incoming tombstone should delete the local row.
    ///
    /// The tombstone wins (returns `true`, caller should delete) iff its
    /// HLC is >= ALL local per-column HLCs. If even one column has an
    /// HLC strictly greater than the tombstone, the row was edited after
    /// the delete — the edit wins and the row is preserved.
    ///
    /// WHY >= and not >:
    /// A tie (tombstoneHLC == every local column HLC) means the delete
    /// and the last edit have the same HLC — this should not happen in a
    /// correctly functioning system (HLC ticks are monotonic), but when
    /// it does the tombstone wins (>= not >) to ensure the replica
    /// eventually converges on deletion rather than staying split.
    ///
    /// WHY empty local map → tombstone wins:
    /// An empty `localColumnHLCs` means this row has never been written
    /// under fieldLevelLWW (e.g., it was created before fieldLevelLWW
    /// was enabled, or is tracked only at the row grain). In this case
    /// there are no column-grain edits to protect, so the tombstone wins
    /// unconditionally — consistent with the `lastWriterWinsByHLC`
    /// tombstone gate used for row-grain HLCs.
    ///
    /// - Parameters:
    ///   - tombstoneHLC: The HLC carried by the incoming delete record.
    ///   - localColumnHLCs: The local per-column HLC map from ColumnHLCStore.
    /// - Returns: `true` if the tombstone wins (caller should delete the row);
    ///   `false` if a local edit beats the delete (caller should keep the row).
    public static func tombstoneWins(
        tombstoneHLC: PackedHLC,
        localColumnHLCs: ColumnHLCMap
    ) -> Bool {
        // No column-grain edits on record — tombstone wins.
        if localColumnHLCs.isEmpty { return true }

        // Tombstone wins iff its HLC is >= every local column HLC.
        // A single column with a higher HLC is enough to keep the row.
        for (_, localHLC) in localColumnHLCs.entries {
            if localHLC > tombstoneHLC {
                return false // edit-beats-delete: this column was written later
            }
        }
        return true
    }
}
