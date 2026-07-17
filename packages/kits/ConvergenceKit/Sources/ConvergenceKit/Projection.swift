// Projection.swift
//
// Pure column projection helpers for the sync boundary (R2).
//
// Operational stores carry derived columns that are recomputed locally on
// every device (scores, caches, materialised explanations). Because the
// outbox is observer-fed and observers fire on every write, derived-column
// recomputes would otherwise become outbound traffic proportional to local
// compute — a sync storm. Projection eliminates that storm at the source.
//
// Two enforcement points per backend:
//   Outbound: strip before OutboxStore.append (CloudKit) or before
//             pendingOutbound.append (Federation). An update whose entire
//             value map is excluded is not enqueued at all.
//   Inbound:  strip before the conflict-policy switch in applyInbound.
//             A peer on a different manifest version may send columns this
//             manifest excludes; dropping them prevents writing derived
//             values that the receiver is about to recompute locally.

import PersistenceKit

/// Column projection utilities for the sync boundary.
///
/// All methods are pure functions: no state, no I/O. Both the CloudKit and
/// Federation backends call these helpers from their outbound and inbound
/// enforcement points.
public enum Projection {

    // MARK: - Outbound

    /// Return `values` with all keys in `excluded` removed.
    ///
    /// If `excluded` is empty, returns `values` unchanged (no allocation).
    /// Keys absent from `values` are silently ignored.
    public static func outboundStrip(
        values: [String: TypedValue],
        excluded: Set<String>
    ) -> [String: TypedValue] {
        guard !excluded.isEmpty else { return values }
        return values.filter { !excluded.contains($0.key) }
    }

    /// Returns `true` when every key in `values` is in `excluded` —
    /// i.e. stripping would leave nothing to ship.
    ///
    /// NOTE: storage backends that emit the full merged row for updates (InMemory,
    /// SQLite) always include the primary key in `values`, so this predicate never
    /// returns `true` unless the excluded set also contains the PK — an unusual
    /// configuration. For the common case (full-row observers), use
    /// `isStormKill(stripped:primaryKeyColumn:)` instead.
    public static func isAllExcluded(
        values: [String: TypedValue],
        excluded: Set<String>
    ) -> Bool {
        guard !excluded.isEmpty, !values.isEmpty else { return false }
        return values.keys.allSatisfy { excluded.contains($0) }
    }

    // MARK: - Outbound storm kill (full-row observer aware)

    /// Returns `true` when the STRIPPED values contain only the primary key and
    /// nothing else — i.e. the original update touched only excluded columns.
    ///
    /// Storage backends that emit the full merged row in `TableChange.values`
    /// always include the PK. After stripping, if only the PK remains, the
    /// update carried no sync-meaningful content: every changed column was
    /// excluded. The enqueue gate uses this predicate to suppress the record
    /// entirely (storm kill).
    ///
    /// Precondition: call with the ALREADY-STRIPPED values (output of
    /// `outboundStrip`), not the raw `change.values`. Guard on
    /// `event == .update` before calling — inserts and deletes are never
    /// suppressed.
    public static func isStormKill(
        stripped: [String: TypedValue],
        primaryKeyColumn: String
    ) -> Bool {
        guard !stripped.isEmpty else { return true }
        return stripped.keys.allSatisfy { $0 == primaryKeyColumn }
    }
}
