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
        return entries
    }

    /// Map the substrate's free-form verb string onto the unified
    /// log's verb enum. Unknown verbs collapse to `.mutate` (the safe
    /// default for "a bitmap changed").
    private static func verb(for s: String) -> UnifiedAuditVerb {
        switch s {
        case "capture":           return .capture
        case "withdraw":          return .withdraw
        case "expunge":           return .expunge
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
