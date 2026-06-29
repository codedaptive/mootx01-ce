// GCPin.swift
//
// GC pin via snapshot-registry minimum HLC (ADR-017 §15).
//
// The maintenance vacuum must not delete tombstoned/superseded rows
// that are newer than the oldest live snapshot's HLC. This module
// provides the "minimum retainable HLC" query: the MIN(hlc) across
// all snapshots. When no snapshots exist, returns nil — meaning all
// rows are vacuumable.

import Foundation
import SubstrateTypes

// MARK: - GC Pin

/// GC pin queries on the snapshot registry.
public enum GCPin {

    /// Returns the minimum HLC across all snapshots (the GC pin boundary).
    /// Rows with HLC >= this value must not be vacuumed.
    /// Returns nil when no snapshots exist (all rows are vacuumable).
    public static func minimumRetainableHlc(
        rowStore: any RowStore
    ) async throws -> HLC? {
        let rows = try await rowStore.query(
            table: SnapshotTables.registry,
            where: nil,
            orderBy: [OrderClause(
                column: Column(table: SnapshotTables.registry, name: "hlc"),
                direction: .ascending
            )],
            limit: 1,
            offset: nil
        )
        guard let first = rows.first,
              case .hlc(let hlc) = first["hlc"]
        else { return nil }
        return hlc
    }

    /// Check whether a row at the given HLC is pinned (must not be vacuumed).
    /// A row is pinned if its HLC >= the minimum retainable HLC.
    /// When no snapshots exist, nothing is pinned (returns false).
    public static func isPinned(
        rowStore: any RowStore,
        rowHlc: HLC
    ) async throws -> Bool {
        guard let minHlc = try await minimumRetainableHlc(rowStore: rowStore) else {
            return false
        }
        // Pinned if the row's HLC is at or after the oldest snapshot's HLC.
        return rowHlc.packed >= minHlc.packed
    }
}
