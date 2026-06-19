// EventLagPairs.swift
//
// Lag-bucketed event-pair read over the unified audit log
// (dormant-surfaces mission, Part 3).
//
// `glkEventLagPairs` reads the estate's in-memory UnifiedAuditLog
// and returns the entries in the exact input shape TemporalCausalityFold
// consumes: a HLC-ascending sequence of TemporalAuditEntry values, each
// carrying field-value coordinates derived from the entry's after-value.
//
// The caller (NeuronKit) passes this slice to
// `TemporalCausalityFold.fold(entries:windowMinutes:startWatermark:)`
// to produce the (antecedent, consequent, lagBucket) delta pairs that
// populate the T matrix.
//
// Conversion rules mirror MatrixTier.rebuildTemporal exactly:
//   .bitmap(v)  → "bitmap:\(v)"
//   .string(s)  → "string:\(s)"
//   .integer(v) → "integer:\(v)"
//   .bytes(b)   → "bytes:\(b.count)"
//   .null       → empty coord list (entry advances watermark, no pairs)
//
// Only capture and expunge verbs contribute field coordinates; all other
// verbs produce an empty coord list.
//
// Ordering: HLC-ascending (orderedEntries is already sorted that way).
// Within the same HLC, stability is inherited from orderedEntries sort —
// secondary sort is (rowID UUID string representation), giving deterministic
// ordering even for simultaneously-issued entries.

import Foundation
import SubstrateML
import SubstrateTypes

public extension GeniusLocusKit {

    /// Returns the estate's audit entries in the input shape
    /// `TemporalCausalityFold` consumes, filtered to `window`.
    ///
    /// The result is a HLC-ascending sequence of `TemporalAuditEntry`
    /// values, each carrying the (field, value) coordinates from the
    /// entry's after-value. Only `capture` and `expunge` verbs produce
    /// non-empty coordinate lists; all other verbs yield an empty list
    /// and advance the fold watermark without contributing to T.
    ///
    /// Pass the result directly to
    /// `TemporalCausalityFold.fold(entries:windowMinutes:startWatermark:)`
    /// to obtain the (antecedent, consequent, lagBucket) delta pairs.
    ///
    /// - Parameters:
    ///   - handle: Open estate handle.
    ///   - window: Closed date range; only entries whose HLC physicalTime
    ///     falls within `window` (converted to ms-since-epoch) are included.
    ///   - lagBuckets: Log-spaced minute boundaries for the T matrix.
    ///     Defaults to `MatrixTier.lagBuckets` ([1,2,4,8,16,32,64,128]).
    ///     The caller uses this value as the `windowMinutes` floor when
    ///     calling the fold; it does not change which entries are returned.
    ///   - allowedRowIDs: When non-nil, only audit entries whose `rowID`
    ///     is in this set contribute to the result. Used by the Precedence
    ///     recipe to implement Option A — pre-filter drawers by `eventTime`
    ///     before gathering their causal audit pairs (Bob's ruling, Wave C).
    ///     Drawers without an explicit eventTime use `filedAt` as the
    ///     fallback (resolved eagerly at capture time). Pass `nil` (the
    ///     default) to include entries from all drawers.
    /// - Returns: HLC-ascending `[TemporalAuditEntry]` for the window.
    /// - Throws: `.estateNotOpen` if the handle is not in the registry.
    func glkEventLagPairs(
        in handle: EstateHandle,
        window: ClosedRange<Date>,
        lagBuckets: [Int] = MatrixTier.lagBuckets,
        allowedRowIDs: Set<String>? = nil
    ) async throws -> [TemporalAuditEntry] {
        guard registry[handle] != nil else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        guard let log = auditLogs[handle] else {
            // No audit log means no entries have been fed yet — return empty
            // rather than throwing; an empty return is correct for a fresh estate.
            return []
        }

        // Convert Date window bounds to physicalTime (ms since Unix epoch).
        // HLC.physicalTime is Int64 milliseconds since Unix epoch.
        let lowerMs = Int64(window.lowerBound.timeIntervalSince1970 * 1_000)
        let upperMs = Int64(window.upperBound.timeIntervalSince1970 * 1_000)

        // orderedEntries is already sorted HLC-ascending (physicalTime ASC,
        // then logicalCount ASC, then nodeID ASC), so no re-sort needed.
        let temporalEntries: [TemporalAuditEntry] = log.orderedEntries
            .filter { entry in
                // HLC window gate: retain entries whose ingest clock falls
                // within the requested window.
                guard entry.hlc.physicalTime >= lowerMs &&
                      entry.hlc.physicalTime <= upperMs else { return false }
                // Drawer-level eventTime gate (Option A): when allowedRowIDs is
                // provided, only entries from those drawers participate. Callers
                // that do not supply the parameter get all-drawers behaviour.
                if let allowed = allowedRowIDs {
                    // Drawer.id is a String; UnifiedAuditEntry.rowID is a UUID.
                    // Compare lowercased UUID strings for consistency.
                    return allowed.contains(entry.rowID.uuidString.lowercased())
                }
                return true
            }
            .map { entry in
                // Only capture and expunge verbs contribute field coordinates
                // to the T matrix. Other verbs (recall, mutate, etc.) advance
                // the watermark but produce no causal pairs.
                guard entry.verb == .capture || entry.verb == .expunge else {
                    return TemporalAuditEntry(hlc: entry.hlc, fieldCoords: [])
                }
                let coords: [TemporalFieldCoord]
                switch entry.afterValue {
                case .bitmap(let v):
                    // Full bitmap as one coordinate — mirrors MatrixTier.rebuildTemporal.
                    coords = [TemporalFieldCoord(
                        fieldPath: entry.fieldPath,
                        valueRepr: "bitmap:\(v)")]
                case .string(let s):
                    coords = [TemporalFieldCoord(
                        fieldPath: entry.fieldPath,
                        valueRepr: "string:\(s)")]
                case .integer(let v):
                    coords = [TemporalFieldCoord(
                        fieldPath: entry.fieldPath,
                        valueRepr: "integer:\(v)")]
                case .bytes(let b):
                    // Byte payloads contribute a size-only coord; raw bytes are
                    // not used as T-matrix coordinates (too high-cardinality).
                    coords = [TemporalFieldCoord(
                        fieldPath: entry.fieldPath,
                        valueRepr: "bytes:\(b.count)")]
                case .null:
                    // Null after-value: the entry advances the watermark but
                    // contributes no coordinate to any pair.
                    coords = []
                }
                return TemporalAuditEntry(hlc: entry.hlc, fieldCoords: coords)
            }

        return temporalEntries
    }
}
