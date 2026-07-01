// AuditBridge.swift
//
// Converts LocusKit `AuditEvent` snapshots into `UnifiedAuditEntry`
// values for the `.locus` tier. Each AuditEvent records one
// row-verb event (capture or per-column mutation); the bridge
// expands it into one UnifiedAuditEntry per column that changed,
// because the unified log's downstream consumers (MatrixTier,
// AuditProjection, EnrichmentPipeline) index by `fieldPath` per
// column.
//
// Identity, not migration: the unified id is a SHA-256 content
// address derived from the converted fields (UnifiedAuditEntry's
// computing initializer does this). Re-bridging the same event
// produces the same id and the G-Set deduplicates — `feedAuditLog`
// is idempotent.
//
// HLC: the event's own HLC is the unified entry's HLC. Earlier
// versions of this bridge synthesized an HLC from the row's
// wall-clock timestamp because LocusKit did not yet emit HLCs;
// post-F13, AuditEvent.hlc is the authoritative ingest stamp and
// passes through verbatim.

import Foundation
import LocusKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes

/// Bridges `SubstrateLib.AuditEvent` → `[UnifiedAuditEntry]` (.locus tier).
enum AuditBridge {

    /// Convert one substrate audit event into the unified-log entries
    /// it represents. One entry is emitted per column that changed
    /// (or all three columns when the event is a capture and
    /// `beforeBitmaps` is nil).
    ///
    /// Field mapping per emitted entry:
    ///   - tier:        `.locus`
    ///   - hlc:         the event's HLC, verbatim
    ///   - verb:        mapped from `event.verb` (string) to
    ///                  `UnifiedAuditVerb` (enum); unknown verbs
    ///                  collapse to `.mutate`
    ///   - rowID:       `event.rowId` (already a UUID)
    ///   - fieldPath:   one of `"adjective"` / `"operational"` /
    ///                  `"provenance"` — the column this entry
    ///                  describes
    ///   - beforeValue: `.bitmap(UInt64(bitPattern:))` of the column's
    ///                  prior value, or `.null` when the event is a
    ///                  capture (no prior state)
    ///   - afterValue:  `.bitmap(UInt64(bitPattern:))` of the column's
    ///                  new value
    ///   - originRowID: nil (no derived-mutation provenance yet)
    static func bridge(_ event: AuditEvent) -> [UnifiedAuditEntry] {
        let unifiedVerb = verb(for: event.verb)
        let after = event.afterBitmaps
        let before = event.beforeBitmaps  // nil for capture

        // For each of the three columns, decide whether to emit an
        // entry. On capture (before == nil) all three change. On a
        // mutator, only the column whose value differs.
        var entries: [UnifiedAuditEntry] = []
        for (name, afterVal, beforeVal) in [
            ("adjective",   after.adjective,   before?.adjective),
            ("operational", after.operational, before?.operational),
            ("provenance",  after.provenance,  before?.provenance),
        ] {
            // Mutator path: only emit when the column actually changed.
            if let beforeVal, beforeVal == afterVal {
                continue
            }
            let beforeValue: UnifiedAuditValue
            if let beforeVal {
                beforeValue = .bitmap(UInt64(bitPattern: beforeVal))
            } else {
                beforeValue = .null
            }
            entries.append(UnifiedAuditEntry(
                tier: .locus,
                hlc: event.hlc,
                verb: unifiedVerb,
                rowID: event.rowId,
                fieldPath: name,
                beforeValue: beforeValue,
                afterValue: .bitmap(UInt64(bitPattern: afterVal)),
                originRowID: nil
            ))
        }

        // Lattice anchor (the FDC zone) → the diffusion zone / topic-trajectory
        // motion model (ADR-DIFFUSION-001 §5, Option 3a). The anchor is already
        // on the event (before/after); bridging it through gives the
        // UnifiedAuditLog the zone time-series with no substrate change. Emit on
        // capture (no prior anchor) and whenever a reanchor changes it; a mutate
        // that leaves the anchor unchanged emits nothing here. value = .integer
        // of the UInt64 UDC code (bit-preserving round trip).
        let afterAnchor = event.afterLatticeAnchor.udcCode
        let beforeAnchor = event.beforeLatticeAnchor?.udcCode
        if beforeAnchor != afterAnchor {
            entries.append(UnifiedAuditEntry(
                tier: .locus,
                hlc: event.hlc,
                verb: unifiedVerb,
                rowID: event.rowId,
                fieldPath: "latticeAnchor",
                beforeValue: beforeAnchor.map { .integer(Int64(bitPattern: $0)) } ?? .null,
                afterValue: .integer(Int64(bitPattern: afterAnchor)),
                originRowID: nil
            ))
        }

        // Q-ID pointer → its own O/T coordinate. The UDC code alone collapses
        // to a uniform class ("Knowledge") for most prose, so co-occurrence and
        // temporal causality gain no per-content structure from it. The Q-ID is
        // the varied per-content concept the FDC classifier resolved, so emit it
        // as a distinct coordinate. Gated on a non-null Q-ID (pointer != 0) so
        // content without a resolved concept adds no uniform-zero coordinate.
        let afterQid = event.afterLatticeAnchor.qidPointer
        let beforeQid = event.beforeLatticeAnchor?.qidPointer
        if beforeQid != afterQid && (afterQid != 0 || (beforeQid ?? 0) != 0) {
            entries.append(UnifiedAuditEntry(
                tier: .locus,
                hlc: event.hlc,
                verb: unifiedVerb,
                rowID: event.rowId,
                fieldPath: "wikidataQID",
                beforeValue: (beforeQid ?? 0) != 0
                    ? .integer(Int64(bitPattern: beforeQid!)) : .null,
                afterValue: afterQid != 0
                    ? .integer(Int64(bitPattern: afterQid)) : .null,
                originRowID: nil
            ))
        }
        return entries
    }

    /// Map the substrate's free-form verb string onto the unified
    /// log's verb enum. Unknown verbs collapse to `.mutate` (the safe
    /// default for "a bitmap changed").
    ///
    /// "tombstone" is the RowVerb the AuditGate seals for an expunge
    /// (RowVerb.tombstone.rawValue == "tombstone"). It maps to
    /// `.expunge` because that is the ARIA-level verb the operation
    /// represents. The substrate uses the lower-level automaton term;
    /// the unified log uses the ARIA noun–verb vocabulary.
    ///
    /// "expungeOrphan" is written by `DrawerStore.sealExpungeOrphanAudit`
    /// when the storage half of an expunge succeeded but the cross-kit
    /// vector delete (step 2) failed. It also maps to `.expunge` so
    /// audit projection consumers see the storage-level expunge in both
    /// the success and orphan cases. Consumers that need to distinguish
    /// a clean expunge from a partial one must read the substrate audit
    /// trail directly (the verb string is preserved there as-is).
    private static func verb(for s: String) -> UnifiedAuditVerb {
        switch s {
        case "capture":           return .capture
        case "withdraw":          return .withdraw
        case "tombstone":         return .expunge   // AuditGate seals expunge as RowVerb.tombstone
        case "expungeOrphan":     return .expunge   // cross-kit delete failed; storage half succeeded
        case "expunge":           return .expunge   // legacy / direct verb string (unused by current gate)
        case "reanchor":          return .reanchor
        case "learn":             return .learn
        case "propose":           return .propose
        case "associate":         return .associate
        case "migrate":           return .migrate
        case "dreamCompact":      return .dreamCompact
        default:                  return .mutate
        }
    }
}
