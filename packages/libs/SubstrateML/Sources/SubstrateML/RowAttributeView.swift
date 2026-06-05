// RowAttributeView.swift
//
// Shared row-replay shape for multi-antecedent mining (Apriori, FCA).
//
// `RowAttributeView` is a pure value type that exposes one row's
// categorical features as a sorted `[(field: UInt8, value: UInt8)]`
// list — the same `Item`-compatible shape `AssociationRuleMining`
// uses, so engines built on that primitive can consume both the
// pairwise (MatrixO) and the row-replay (RowAttributeView) inputs
// without an intermediate translation layer.
//
// Input shape: `RowAuditEntry` is the SubstrateML-native audit-entry
// type. GeniusLocusKit's `EstateAssociationRuleMining` converts its
// `UnifiedAuditEntry` stream into `RowAuditEntry` values before
// calling the factory. Keeping `RowAuditEntry` in SubstrateML avoids
// a layering inversion (SubstrateML is below GeniusLocusKit; it
// cannot import GLK types).
//
// Extraction rules (cookbook §5.3 / §6.3):
//
//   .bitmap(v)  — each set bit at position p (0..63) becomes one
//                 attribute: field = fieldPath vocab index,
//                 value = p (bit position). Mirrors F-matrix
//                 bit-decomposition from applyCapture.
//
//   .integer(n) — one attribute: field = fieldPath vocab index,
//                 value = UInt8(n & 0xFF). Low byte only; fixtures
//                 must keep values < 256.
//
//   .null       — dropped (no categorical content).
//
// The shared vocabulary is built once per `from(auditEntries:)` call
// by collecting all distinct fieldPath strings, sorting
// alphabetically, and assigning indices 0..min(N-1, 63). The
// vocabulary is NOT embedded in the returned views; it is an
// implementation detail of the factory. Callers that need consistent
// cross-call vocabularies should merge their entry lists before
// calling.
//
// FCA usage note (MX-3a): `FormalContext` materialisation calls
// `RowAttributeView.from` with the same `RowAuditEntry` input to
// build its object×attribute incidence matrix.

import Foundation
import SubstrateTypes

// MARK: - Input types

/// A typed value payload for a single audit-log field write.
/// Mirrors the relevant cases of `GeniusLocusKit.UnifiedAuditValue`
/// but lives in SubstrateML to avoid a layering inversion.
public enum RowAuditValue: Sendable, Equatable {
    /// A 64-bit bitmap. Each set bit position becomes a separate
    /// attribute in `RowAttributeView`.
    case bitmap(UInt64)

    /// An integer value. Low byte is used as the attribute value.
    case integer(Int64)

    /// Absent / tombstone — produces no attribute.
    case null
}

/// One field write from an audit log. Used as the input to
/// `RowAttributeView.from(auditEntries:)`.
///
/// GeniusLocusKit's `EstateAssociationRuleMining` converts
/// `UnifiedAuditEntry` values to `RowAuditEntry` values before
/// calling the factory. This keeps the dependency graph clean:
/// SubstrateML never imports GeniusLocusKit types.
public struct RowAuditEntry: Sendable, Equatable {
    /// The row this write belongs to.
    public let rowID: UUID

    /// Storage tier, encoded as a raw string (e.g. "locus", "rag").
    /// Matches `AuditTier.rawValue` from GeniusLocusKit so grouping
    /// semantics are preserved through the conversion.
    public let tier: String

    /// Logical name of the field being written.
    public let fieldPath: String

    /// Hybrid logical clock at write time. Used for latest-wins
    /// deduplication within a row's field history.
    public let hlc: HLC

    /// The value written to this field.
    public let value: RowAuditValue

    public init(rowID: UUID, tier: String, fieldPath: String,
                hlc: HLC, value: RowAuditValue) {
        self.rowID = rowID
        self.tier = tier
        self.fieldPath = fieldPath
        self.hlc = hlc
        self.value = value
    }
}

// MARK: - RowAttributeView

/// One row's categorical features in the flat `(field, value)` shape
/// used by `AprioriMining` and (in MX-3a) `FormalConceptAnalysis`.
///
/// Produced by `RowAttributeView.from(auditEntries:)` or by direct
/// initialisation for testing and for engines that derive views from
/// sources other than the audit log.
///
/// Attribute ordering is sorted ascending by `(field, value)` for
/// deterministic equality, hashing, and itemset operations across
/// languages.
public struct RowAttributeView: Hashable, Sendable, Equatable {

    /// The row this view describes.
    public let rowID: UUID

    /// The storage tier this row came from (raw string value).
    public let tier: String

    /// Sorted `(field, value)` attribute pairs for this row.
    ///
    /// `field` is a per-factory vocabulary index (0..63) over
    /// distinct fieldPath strings in the input batch.
    ///
    /// `value` is either a bitmap bit-position (0..63) for
    /// `.bitmap` fields or the low byte of an `.integer` value.
    public let attributes: [(field: UInt8, value: UInt8)]

    /// Direct initialiser — available for tests and for downstream
    /// engines that supply their own views.
    public init(rowID: UUID, tier: String, attributes: [(field: UInt8, value: UInt8)]) {
        self.rowID = rowID
        self.tier = tier
        self.attributes = attributes.sorted {
            if $0.field != $1.field { return $0.field < $1.field }
            return $0.value < $1.value
        }
    }

    // Explicit Equatable — tuple arrays cannot auto-synthesize conformance.
    public static func == (lhs: RowAttributeView, rhs: RowAttributeView) -> Bool {
        guard lhs.rowID == rhs.rowID,
              lhs.tier == rhs.tier,
              lhs.attributes.count == rhs.attributes.count else { return false }
        for i in 0..<lhs.attributes.count {
            if lhs.attributes[i].field != rhs.attributes[i].field { return false }
            if lhs.attributes[i].value != rhs.attributes[i].value { return false }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rowID)
        hasher.combine(tier)
        for a in attributes {
            hasher.combine(a.field)
            hasher.combine(a.value)
        }
    }
}

// MARK: - Factory

public extension RowAttributeView {

    /// Build a `RowAttributeView` array from a flat list of
    /// `RowAuditEntry` values.
    ///
    /// Algorithm:
    ///
    /// 1. Build a shared vocabulary of all distinct `fieldPath`
    ///    strings, sorted alphabetically and capped at 64 (the
    ///    6-bit field-index limit of `Item`).
    ///
    /// 2. Group entries by `(tier, rowID)`.
    ///
    /// 3. Within each group, take the LATEST entry per `fieldPath`
    ///    (HLC ordering ascending — last write wins, matching the
    ///    AuditLogFold projection rule).
    ///
    /// 4. Extract attributes from each surviving entry's `value`
    ///    using the rules in the file header. Rows that produce
    ///    zero attributes are dropped.
    ///
    /// The returned array is sorted by `(tier, rowID.uuidString)`.
    ///
    /// - Parameter auditEntries: converted audit log entries (any
    ///   order; from any tier).
    /// - Returns: one `RowAttributeView` per distinct `(tier, rowID)`.
    static func from(auditEntries: [RowAuditEntry]) -> [RowAttributeView] {
        guard !auditEntries.isEmpty else { return [] }

        // Step 1 — build shared fieldPath vocabulary (max 64 entries).
        let vocab = buildVocab(from: auditEntries)

        // Step 2 — group by (tier, rowID).
        var groups: [RowGroupKey: [RowAuditEntry]] = [:]
        for entry in auditEntries {
            let key = RowGroupKey(tier: entry.tier, rowID: entry.rowID)
            groups[key, default: []].append(entry)
        }

        // Steps 3+4 — project each group to a RowAttributeView.
        var views: [RowAttributeView] = []
        views.reserveCapacity(groups.count)

        for (key, entries) in groups {
            let attrs = projectAttributes(from: entries, vocab: vocab)
            guard !attrs.isEmpty else { continue }
            views.append(RowAttributeView(
                rowID: key.rowID,
                tier: key.tier,
                attributes: attrs
            ))
        }

        // Deterministic output order.
        views.sort {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            return $0.rowID.uuidString < $1.rowID.uuidString
        }
        return views
    }
}

// MARK: - Implementation helpers

private struct RowGroupKey: Hashable {
    let tier: String
    let rowID: UUID
}

/// Build a sorted, capped vocabulary from all fieldPath strings in
/// the entry list. Maximum 64 entries (6-bit field-index limit).
private func buildVocab(from entries: [RowAuditEntry]) -> [String] {
    var seen = Set<String>()
    for e in entries { seen.insert(e.fieldPath) }
    let sorted = seen.sorted()
    return sorted.count > 64 ? Array(sorted.prefix(64)) : sorted
}

/// Select the latest-HLC entry per fieldPath within one row group,
/// then extract attributes.
private func projectAttributes(
    from entries: [RowAuditEntry],
    vocab: [String]
) -> [(field: UInt8, value: UInt8)] {
    // Latest-HLC dedup per fieldPath within this row.
    var latest: [String: RowAuditEntry] = [:]
    for entry in entries {
        if let existing = latest[entry.fieldPath] {
            if existing.hlc < entry.hlc {
                latest[entry.fieldPath] = entry
            }
        } else {
            latest[entry.fieldPath] = entry
        }
    }

    var attrs: [(field: UInt8, value: UInt8)] = []
    for (fieldPath, entry) in latest {
        guard let idx = vocab.firstIndex(of: fieldPath) else { continue }
        let field = UInt8(idx)
        switch entry.value {
        case .bitmap(let v):
            // Each set bit at position p → attribute (field, p).
            var remaining = v
            while remaining != 0 {
                let p = remaining.trailingZeroBitCount
                attrs.append((field: field, value: UInt8(p)))
                remaining &= remaining &- 1
            }
        case .integer(let n):
            // Low byte flows through as the attribute value.
            attrs.append((field: field, value: UInt8(n & 0xFF)))
        case .null:
            break
        }
    }

    return attrs.sorted {
        if $0.field != $1.field { return $0.field < $1.field }
        return $0.value < $1.value
    }
}
