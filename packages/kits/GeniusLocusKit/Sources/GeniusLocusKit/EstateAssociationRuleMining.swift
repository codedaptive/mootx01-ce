// EstateAssociationRuleMining.swift
//
// Wires pairwise ARM and multi-antecedent Apriori mining to live
// GeniusLocusKit estates (mission MX-2).
//
// Two entry points:
//
//   mineAssociationRules(estate:thresholds:)
//     Reads the estate's registered `MatrixTier`, adapts its
//     `coOccurrence` map to a `MatrixO`, and delegates to
//     `mineAssociationRules(matrix:activeRowCount:thresholds:)` in
//     SubstrateML. Returns `[AssociationRule]`.
//
//   mineAprioriRules(estate:thresholds:)
//     Reads the current audit log via `currentAuditLog(in:)`,
//     converts each entry to `RowAuditEntry`, builds `RowAttributeView`
//     rows, and delegates to `AprioriMining.mine(rows:thresholds:)`.
//     Returns `[AprioriRule]`.
//
// Approximations (documented in MX-2 Blast Radius Report,
// INTENTIONALLY_LEFT items):
//
//   - MatrixTier.coOccurrence stores only upper-triangle pairs (no
//     diagonal). Single-item support O[A,A] is estimated as
//     `liveRowCount` (an upper bound). Confidence and lift are
//     therefore conservative lower bounds. Full correctness requires a
//     separate mission that extends MatrixTier to store diagonal counts.
//
//   - Multi-bit `.bitmap`, `.string`, and `.bytes` coordinate values
//     cannot be projected losslessly into the 6-bit Item model and are
//     skipped during adaptation. Only `.integer` and single-bit
//     `.bitmap` (bit-position) coordinates produce ARM items.
//
// Extension pattern: `public extension GeniusLocusKit` places these
// methods in the same module as the actor, giving access to
// `internal var matrixTiers` and `internal func auditLog(for:)`.
// This is the same pattern used by MaintenanceReads, RecallDirector,
// and all other Brain-layer extensions.

import Foundation
import OSLog
import SubstrateML
import SubstrateTypes

// MARK: - Public mining surface

public extension GeniusLocusKit {

    // MARK: Pairwise ARM

    /// Mine pairwise association rules from the estate's registered matrix tier.
    ///
    /// Returns an empty array — not an error — when no `MatrixTier` has
    /// been registered for the estate (a fresh estate with no prior
    /// `registerMatrixTier(_:for:)` call is silent, not broken).
    ///
    /// See file-header comment for documented approximations.
    ///
    /// - Parameters:
    ///   - estate: handle for the target estate.
    ///   - thresholds: minimum support and confidence gates.
    /// - Returns: rules sorted ascending on packed `(antecedent, consequent)`
    ///   key, matching the SubstrateML ARM emission order.
    func mineAssociationRules(
        estate: EstateHandle,
        thresholds: MiningThresholds
    ) -> [AssociationRule] {
        guard let tier = matrixTiers[estate] else { return [] }
        let (matrix, rowCount) = adaptToMatrixO(tier)
        // Explicit module qualification avoids name shadowing by the
        // instance method `mineAssociationRules(estate:thresholds:)`
        // defined in the same extension.
        return SubstrateML.mineAssociationRules(matrix: matrix,
                                                activeRowCount: rowCount,
                                                thresholds: thresholds)
    }

    // MARK: Apriori

    /// Hard ceiling on the number of audit entries materialized for Apriori
    /// mining. `orderedEntries` is HLC-ascending; we take the most-recent
    /// `maxAuditEntriesForMining` via `suffix(_:)`.
    ///
    /// Rationale for 50,000:
    ///   - Each UnifiedAuditEntry is ~150–200 bytes. 50,000 entries ≈ 10 MB
    ///     of raw Array allocation before Apriori work, well within a
    ///     single-call memory budget for a local server.
    ///   - A real human-driven estate producing 10 mutations per drawer
    ///     at 1,000 drawers yields ~10,000 entries — safely under the cap.
    ///   - Automated/adversarial loads that replay unbounded lifetime history
    ///     are bounded to the most-recent 50,000 events, keeping mining
    ///     latency and allocation predictable regardless of estate age.
    ///   - Apriori's RowAttributeView layer applies last-HLC-wins deduplication
    ///     per (tier, row, field), so the effective row count is much smaller
    ///     than 50,000 in practice; the cap is a materialization guard, not
    ///     an accuracy floor.
    ///
    /// Mirrors Rust's `MAX_APRIORI_AUDIT_ENTRIES` const in `coordinator.rs`.
    static let maxAuditEntriesForMining: Int = 50_000

    /// Mine multi-antecedent Apriori rules from the estate's audit log.
    ///
    /// Calls `currentAuditLog(in:)` to refresh and snapshot the audit log,
    /// bounds the entry set to the most-recent `maxAuditEntriesForMining`
    /// entries (HLC-ascending tail), converts each entry's `afterValue` to a
    /// `RowAuditEntry`, builds `RowAttributeView` rows, and delegates to
    /// `AprioriMining.mine`.
    ///
    /// The entry cap prevents a caller-induced OOM/hang on estates with a
    /// large lifetime audit history. Dropping the oldest entries means the
    /// analysis window covers recent activity, which is the correct behavior
    /// for a recency-biased Apriori pass.
    ///
    /// - Parameters:
    ///   - estate: handle for the target estate.
    ///   - thresholds: minimum support, confidence, lift, and maxK gates.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` when the estate is
    ///   not in the registry; any error surfaced by `currentAuditLog`.
    /// - Returns: rules sorted by lift DESC, confidence DESC,
    ///   evidenceCount DESC.
    func mineAprioriRules(
        estate: EstateHandle,
        thresholds: AprioriThresholds
    ) async throws -> [AprioriRule] {
        try await mineAprioriRules(
            estate: estate,
            thresholds: thresholds,
            entryLimit: GeniusLocusKit.maxAuditEntriesForMining
        )
    }

    /// Internal entry point for `mineAprioriRules` that accepts an explicit
    /// entry limit. The public surface always passes `maxAuditEntriesForMining`;
    /// this variant exists so tests can exercise the cap at a small scale
    /// without injecting 50,000 entries.
    internal func mineAprioriRules(
        estate: EstateHandle,
        thresholds: AprioriThresholds,
        entryLimit: Int
    ) async throws -> [AprioriRule] {
        let log = try await currentAuditLog(in: estate)
        // Bound the materialization to the most-recent `entryLimit` entries.
        // orderedEntries is HLC-ascending; suffix(_:) takes the tail, which is
        // the most-recent window. Dropping the oldest entries means the analysis
        // window covers recent activity — correct for a recency-biased Apriori pass.
        // Mirrors Rust's &all_ordered[all_ordered.len() - MAX..] slice in coordinator.rs.
        let bounded = log.orderedEntries.suffix(entryLimit)
        let auditEntries = bounded.map { toRowAuditEntry($0) }
        let rows = RowAttributeView.from(auditEntries: auditEntries)
        return AprioriMining.mine(rows: rows, thresholds: thresholds)
    }
}

// MARK: - Internal helpers (same-actor access only)

private extension GeniusLocusKit {

    /// Adapt a `MatrixTier` snapshot to a `MatrixO` for the ARM engine.
    ///
    /// Step 1: build a fieldPath vocabulary (sorted, capped at 64) from
    ///         all coordinate fieldPaths in `coOccurrence`.
    ///
    /// Step 2: project each `MatrixValueCoord` to `(field: UInt8, value: UInt8)`
    ///         using the vocabulary index as the field and the value mapping
    ///         below. Coordinates that can't be projected are skipped.
    ///
    ///   `.integer(n)` → value = `UInt8(n & 0x3F)` (low 6 bits, 0..63).
    ///   `.bitmap(v)` where `v` has exactly ONE set bit → value = bit position.
    ///   Multi-bit `.bitmap`, `.string`, `.bytes`, `.null` → skipped.
    ///
    /// Step 3: for each surviving coOccurrence entry (canonical upper-triangle
    ///         pair), emit BOTH ordered `(a, b)` and `(b, a)` cells in the
    ///         MatrixO so ARM's canonical-order scan sees both directed rules.
    ///
    /// Step 4: add diagonal `O[A,A] = liveRowCount` for each observed item.
    ///         This is a conservative upper-bound estimate (see file header).
    func adaptToMatrixO(_ tier: MatrixTier) -> (matrix: MatrixO, rowCount: Int64) {
        guard !tier.coOccurrence.isEmpty, tier.liveRowCount > 0 else {
            return (MatrixO(), 0)
        }

        // Step 1 — vocabulary.
        var pathSet = Set<String>()
        for key in tier.coOccurrence.keys {
            pathSet.insert(key.a.fieldPath)
            pathSet.insert(key.b.fieldPath)
        }
        let vocab = Array(pathSet.sorted().prefix(64))

        // Closure: project a MatrixValueCoord to CooccurrenceKey-compatible
        // (field, value) — both guaranteed in 0..63. Returns nil on skip.
        func project(_ coord: MatrixValueCoord) -> (UInt8, UInt8)? {
            guard let idx = vocab.firstIndex(of: coord.fieldPath) else { return nil }
            let field = UInt8(idx) // 0..63 because vocab is capped at 64
            switch coord.value {
            case .integer(let n):
                // Low 6 bits → safe for CooccurrenceKey's field-value precondition.
                return (field, UInt8(n & 0x3F))
            case .bitmap(let b) where b.nonzeroBitCount == 1:
                // Single-bit bitmap: bit position is the canonical Item.value
                // used by RowAttributeView for bitmap fields. Bit positions
                // are always 0..63 for a UInt64 operand.
                return (field, UInt8(b.trailingZeroBitCount))
            default:
                // Multi-bit bitmaps, strings, bytes, null: no lossless 6-bit
                // encoding exists. These coordinates are documented as
                // INTENTIONALLY_LEFT in the MX-2 Blast Radius Report.
                return nil
            }
        }

        // Steps 2 + 3: emit off-diagonal cells.
        var rawEntries: [(key: CooccurrenceKey, count: Int64)] = []
        rawEntries.reserveCapacity(tier.coOccurrence.count * 2)

        var seenItems: Set<Item> = []

        for (matKey, count) in tier.coOccurrence {
            guard let (fA, vA) = project(matKey.a),
                  let (fB, vB) = project(matKey.b) else { continue }

            let itemA = Item(field: fA, value: vA)
            let itemB = Item(field: fB, value: vB)
            guard itemA != itemB else { continue }

            seenItems.insert(itemA)
            seenItems.insert(itemB)

            // Emit both directed cells; MatrixO.init deduplicates and sorts.
            rawEntries.append((
                key: CooccurrenceKey(fieldI: fA, valueI: vA, fieldJ: fB, valueJ: vB),
                count: count
            ))
            rawEntries.append((
                key: CooccurrenceKey(fieldI: fB, valueI: vB, fieldJ: fA, valueJ: vA),
                count: count
            ))
        }

        // Step 4: diagonal O[A,A] = liveRowCount (conservative upper bound).
        let diagCount = tier.liveRowCount
        for item in seenItems {
            rawEntries.append((
                key: CooccurrenceKey(
                    fieldI: item.field, valueI: item.value,
                    fieldJ: item.field, valueJ: item.value
                ),
                count: diagCount
            ))
        }

        return (MatrixO(entries: rawEntries), tier.liveRowCount)
    }

    /// Convert one `UnifiedAuditEntry` to `RowAuditEntry` for Apriori
    /// row-replay.
    ///
    /// Uses `afterValue` (the value written by the verb) so the
    /// `RowAttributeView` factory's latest-HLC deduplication per
    /// `(tier, rowID, fieldPath)` reconstructs current row state.
    /// Expunge / withdraw verbs leave `afterValue = .null`; the factory
    /// drops those (no categorical content), effectively removing
    /// the field from the row's view.
    ///
    /// `.string` and `.bytes` map to `.null` — no canonical 6-bit Item
    /// encoding exists for these types.
    func toRowAuditEntry(_ entry: UnifiedAuditEntry) -> RowAuditEntry {
        let rowValue: RowAuditValue
        switch entry.afterValue {
        case .null:
            rowValue = .null
        case .bitmap(let v):
            rowValue = .bitmap(v)
        case .integer(let n):
            rowValue = .integer(n)
        case .string:
            // String values have no canonical 6-bit Item encoding.
            rowValue = .null
        case .bytes:
            // Byte arrays have no canonical 6-bit Item encoding.
            rowValue = .null
        }
        return RowAuditEntry(
            rowID: entry.rowID,
            tier: entry.tier.rawValue,
            fieldPath: entry.fieldPath,
            hlc: entry.hlc,
            value: rowValue
        )
    }
}
