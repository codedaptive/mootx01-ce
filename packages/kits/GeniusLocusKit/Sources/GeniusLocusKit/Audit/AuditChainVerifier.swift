// AuditChainVerifier.swift
//
// Pure integrity check over a UnifiedAuditLog (mission GLK-03).
//
// The unified log has no prevHash link between entries — each entry is
// content-addressed by a SHA-256 over its own fields (see
// UnifiedAuditLog.swift). Integrity is therefore two independent
// properties, checked per the spec comment in UnifiedAuditLog.swift:
//
//   1. Content-hash fidelity. Recompute each entry's id from its
//      fields and compare to the stored id. A mismatch means the
//      entry's bytes were altered after it was minted — a tampered or
//      corrupted entry. This is the substantive check.
//   2. HLC monotonicity. Walking the log in HLC order, no entry's HLC
//      may be strictly less than its predecessor's. `orderedEntries`
//      already sorts by HLC, so this holds by construction for a
//      well-formed log; the explicit check is a defensive guard that
//      documents the invariant and catches a future ordering bug at
//      the source rather than downstream in the projection.
//
// Output is an AuditChainReport per NEURONKIT_SPEC §3.5 / invariant
// C-12: on the first violation, `valid == false` and `firstBrokenAt`
// is the offending entry's HLC timestamp.

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

/// Verifies that a `UnifiedAuditLog`'s chain is intact. Pure — no I/O,
/// no actor access, deterministic given the log.
public enum AuditChainVerifier {

    /// Epoch sentinel for the empty-log case. The spec's
    /// `firstEntryAt` / `lastEntryAt` fields are non-optional, so an
    /// empty log reports the Unix epoch rather than a missing date.
    private static let emptySentinel = Date(timeIntervalSince1970: 0)

    /// Convert an entry's HLC physical time (milliseconds since the
    /// Unix epoch — the unit the bridge writes; see AuditBridge) into a
    /// `Date`. Pure arithmetic, no clock read.
    static func date(from hlc: HLC) -> Date {
        Date(timeIntervalSince1970: Double(hlc.physicalTime) / 1000.0)
    }

    /// Verify the log and return the integrity report.
    public static func verify(_ log: UnifiedAuditLog) -> AuditChainReport {
        let entries = log.orderedEntries

        guard let first = entries.first, let last = entries.last else {
            // Empty log: vacuously valid. No entry to date.
            return AuditChainReport(
                valid: true,
                entryCount: 0,
                firstEntryAt: emptySentinel,
                lastEntryAt: emptySentinel,
                firstBrokenAt: nil
            )
        }

        let firstAt = date(from: first.hlc)
        let lastAt = date(from: last.hlc)

        var previousHLC: HLC? = nil
        for entry in entries {
            // (2) HLC monotonicity — no reversal relative to the prior
            // entry in HLC order.
            if let prev = previousHLC, entry.hlc < prev {
                return AuditChainReport(
                    valid: false, entryCount: entries.count,
                    firstEntryAt: firstAt, lastEntryAt: lastAt,
                    firstBrokenAt: date(from: entry.hlc)
                )
            }
            previousHLC = entry.hlc

            // (1) Content-hash fidelity — recompute the id from the
            // entry's fields via the computing initializer and compare
            // to the stored id. The computing init is the same path
            // that minted the original id, so an intact entry round-trips
            // to an identical hash.
            let recomputed = UnifiedAuditEntry(
                tier: entry.tier,
                hlc: entry.hlc,
                verb: entry.verb,
                rowID: entry.rowID,
                fieldPath: entry.fieldPath,
                beforeValue: entry.beforeValue,
                afterValue: entry.afterValue,
                originRowID: entry.originRowID
            )
            if recomputed.id != entry.id {
                return AuditChainReport(
                    valid: false, entryCount: entries.count,
                    firstEntryAt: firstAt, lastEntryAt: lastAt,
                    firstBrokenAt: date(from: entry.hlc)
                )
            }
        }

        return AuditChainReport(
            valid: true, entryCount: entries.count,
            firstEntryAt: firstAt, lastEntryAt: lastAt,
            firstBrokenAt: nil
        )
    }
}
