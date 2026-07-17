// ColumnHLCMap.swift
//
// Per-column HLC map for the fieldLevelLWW conflict policy.
//
// Stores one PackedHLC per column name. Used in two ways:
//
//   1. On the wire (SyncRecord.columnHLCs): the sender stamps the HLC
//      at which each column was last written. The receiver applies a
//      column only when the incoming HLC is >= the local column HLC
//      (newest-per-column LWW).
//
//   2. In the outbox (OutboxEntry.columnHLCsData): outbox coalescing
//      merges two entries for the same (table, row) by keeping the
//      highest HLC per column so that no column update is silently
//      discarded when a hot row is written faster than the push cycle.
//
// WHY `entries` key (not a flat dictionary at the top level):
// Matches the SyncValueMap convention. Both Swift JSONEncoder and
// Rust serde_json encode struct fields by name, so the outer struct
// ensures the JSON shape is {entries: {...}} in both legs — a flat
// dictionary would encode identically today but using a named wrapper
// makes the wire format explicit and extensible (future: version field).
//
// WHY array/blob columns are atomic:
// fieldLevelLWW applies "column iff incoming HLC >= local HLC" per
// column. For scalar (text, int, float, uuid, timestamp) columns this
// is straightforward field-level granularity. For array and blob
// columns the entire value is treated as a single atomic unit — the
// whole column wins or loses as one, because there is no sub-field
// addressing protocol. This is correct: array/blob columns are
// already stored as opaque blobs in PersistenceKit rows.
//
// WHY PackedHLC (not a bare Int64):
// PackedHLC is the existing stable Codable wire type for HLC values.
// Using it here ensures the JSON encoding is identical to HLC fields
// elsewhere on the wire (cross-port parity, C-8).

import Foundation
import SubstrateTypes

// MARK: - ColumnHLCMap

/// Compact column→HLC map for the `fieldLevelLWW` conflict policy.
///
/// Each entry maps a column name to the packed HLC at which that column
/// was last written. A nil entry means the receiver has not yet seen
/// any write for that column under fieldLevelLWW (treat as "negative
/// infinity" — any incoming HLC wins).
///
/// `Codable` with an `entries` key so the JSON wire shape is:
/// ```json
/// {"entries": {"columnA": {"physicalTime":…,"logicalCount":…,"nodeID":…}}}
/// ```
/// This matches the Rust `ColumnHLCMap { entries: BTreeMap<String, PackedHLC> }`
/// serialisation for cross-port parity (C-8).
public struct ColumnHLCMap: Sendable, Codable, Equatable {

    /// Explicit CodingKeys matching the wire key and the Rust struct field name.
    private enum CodingKeys: String, CodingKey {
        case entries
    }

    /// Column name → packed HLC. Keys are application column names exactly as
    /// they appear in PersistenceKit rows.
    public var entries: [String: PackedHLC]

    public init(entries: [String: PackedHLC] = [:]) {
        self.entries = entries
    }

    // MARK: - Merge (outbox coalescing)

    /// Merge two ColumnHLCMaps, keeping the highest HLC per column.
    ///
    /// Used by outbox coalescing: when a newer outbox entry for the
    /// same (table, row) replaces a stale one, the column HLC maps are
    /// merged so that columns present only in the older entry are not
    /// silently discarded.
    ///
    /// Commutativity: `a.merge(with: b)` and `b.merge(with: a)` produce
    /// the same result because we pick the maximum HLC per column using
    /// lexicographic comparison (PackedHLC implements Comparable via
    /// physicalTime > logicalCount > nodeID).
    ///
    /// - Parameter other: The other map to merge with.
    /// - Returns: A new map containing all columns from both maps, with
    ///   the higher HLC for each column where both maps have an entry.
    public func merge(with other: ColumnHLCMap) -> ColumnHLCMap {
        var result = entries
        for (column, otherHLC) in other.entries {
            if let existing = result[column] {
                // Keep the higher HLC. PackedHLC.Comparable uses
                // (physicalTime, logicalCount, nodeID) lexicographic order.
                if otherHLC > existing {
                    result[column] = otherHLC
                }
            } else {
                result[column] = otherHLC
            }
        }
        return ColumnHLCMap(entries: result)
    }

    // MARK: - Stamp (capture-time recording)

    /// Return a new ColumnHLCMap stamping all given column keys with `hlc`.
    ///
    /// Used by the outbox observer when capturing a local write:
    /// because `TableChange` does not carry per-column identity (only the
    /// full row snapshot is available), ALL value columns present in the
    /// change are stamped with the capture HLC. This is correct but coarse
    /// — a future refinement could stamp only the actually-changed columns
    /// when `TableChange` gains `changedColumns` support in PersistenceKit.
    ///
    /// - Parameters:
    ///   - keys: Column names to stamp.
    ///   - hlc: The HLC to assign to all stamped columns.
    /// - Returns: A new map with every key mapped to `hlc`.
    public static func stampAll(keys: some Sequence<String>, hlc: PackedHLC) -> ColumnHLCMap {
        var entries: [String: PackedHLC] = [:]
        for key in keys {
            entries[key] = hlc
        }
        return ColumnHLCMap(entries: entries)
    }

    // MARK: - Convenience

    public var isEmpty: Bool { entries.isEmpty }
}

// MARK: - PackedHLC Comparable

/// Lexicographic ordering for PackedHLC: physicalTime first, then
/// logicalCount, then nodeID. Used by ColumnHLCMap.merge to pick the
/// highest HLC per column.
///
/// Cross-port parity: Rust's `PartialOrd` on `PackedHLC` (derives via
/// struct field order: physical_time, logical_count, node_id) produces
/// the same ordering because the struct fields are declared in the same
/// order in both legs.
extension PackedHLC: Comparable {
    public static func < (lhs: PackedHLC, rhs: PackedHLC) -> Bool {
        if lhs.physicalTime != rhs.physicalTime { return lhs.physicalTime < rhs.physicalTime }
        if lhs.logicalCount != rhs.logicalCount { return lhs.logicalCount < rhs.logicalCount }
        return lhs.nodeID < rhs.nodeID
    }
}
