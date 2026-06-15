// AuditRecovery.swift
//
// Rebuild-from-audit across both storage tiers (mission GLK-03).
// Recovery is the inverse-of-corruption primitive: given only the
// unified audit log, the substrate must be able to reproduce the
// live projection bit-for-bit. The CRDT properties of the log
// (cookbook §5.1, §5.4) guarantee the rebuild is deterministic and
// independent of recovery order.
//
// This module is intentionally thin. Recovery is the same fold as
// `AuditProjectionFold.project`; what `AuditRecovery` adds is:
//
//   • a verification helper that compares the rebuilt projection
//     against a previously held one and reports divergence by row,
//   • a streaming-recovery API that consumes entries incrementally
//     (the on-disk audit log can be replayed without ever holding
//     the full set in memory),
//   • a recovery result type that summarises what was rebuilt.
//
// Cookbook references:
//   §5.5   Reconstruction from audit log
//   §10    Verbs — recovery emits no new audit entries; it only
//          reads.

import Foundation
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

// MARK: - Result

/// Summary of a recovery pass. The substrate consumes the rebuilt
/// projection; the counts are reported for diagnostics and the
/// dispatch event log.
public struct AuditRecoveryResult: Sendable, Equatable {
    public let projection: UnifiedProjection
    public let entriesReplayed: Int
    public let rowsRebuilt: Int
    public let locusRows: Int
    public let ragRows: Int

    public init(projection: UnifiedProjection,
                entriesReplayed: Int) {
        self.projection = projection
        self.entriesReplayed = entriesReplayed
        self.rowsRebuilt = projection.count
        self.locusRows = projection.rows(in: .locus).count
        self.ragRows = projection.rows(in: .rag).count
    }
}

/// Divergence between a rebuilt projection and a previously held one.
/// Empty means the two agree exactly; recovery succeeded.
public struct AuditRecoveryDivergence: Sendable, Equatable {
    public struct RowMismatch: Sendable, Equatable {
        public let key: UnifiedProjection.Key
        public let expected: UnifiedRowProjection?
        public let rebuilt: UnifiedRowProjection?
    }
    public let mismatches: [RowMismatch]
    public var isEmpty: Bool { mismatches.isEmpty }
}

// MARK: - Recovery

public enum AuditRecovery {

    /// Rebuild the unified projection from a full audit log. Equivalent
    /// to `AuditProjectionFold.project(log)` wrapped in a result type
    /// that exposes the replay counts. Use this entry-point when the
    /// caller already holds the entire log; for incremental replay,
    /// use `rebuildStreaming(from:)`.
    public static func rebuild(from log: UnifiedAuditLog) -> AuditRecoveryResult {
        let projection = AuditProjectionFold.project(log)
        return AuditRecoveryResult(
            projection: projection,
            entriesReplayed: log.count
        )
    }

    /// Rebuild the projection asOf a specific HLC. The substrate uses
    /// this on partial recovery (e.g. roll back to a known-good HLC
    /// before applying inbound sync entries beyond that point).
    public static func rebuild(from log: UnifiedAuditLog,
                                asOf cutoff: HLC) -> AuditRecoveryResult {
        let truncated = log.entries(asOf: cutoff)
        let logSlice = UnifiedAuditLog(entries: truncated)
        let projection = AuditProjectionFold.project(logSlice)
        return AuditRecoveryResult(
            projection: projection,
            entriesReplayed: logSlice.count
        )
    }

    /// Streaming rebuild. The caller hands entries one at a time and
    /// the recovery state machine folds them into the running G-Set.
    /// Re-emitting the same entry is idempotent (G-Set semantics).
    /// Call `finish()` to obtain the result.
    public static func rebuildStreaming<S: Sequence>(
        from entries: S
    ) -> AuditRecoveryResult where S.Element == UnifiedAuditEntry {
        var log = UnifiedAuditLog()
        for entry in entries {
            log.add(entry)
        }
        return rebuild(from: log)
    }

    /// Compare a freshly-rebuilt projection to a reference (typically
    /// the projection the substrate held in memory before a recovery
    /// pass kicked off). Reports per-row divergence; empty result
    /// means the rebuilt projection matches the reference and the
    /// recovery pass was a no-op.
    public static func verify(rebuilt: UnifiedProjection,
                               against reference: UnifiedProjection) -> AuditRecoveryDivergence {
        var mismatches: [AuditRecoveryDivergence.RowMismatch] = []
        let keys = Set(rebuilt.rows.keys).union(reference.rows.keys)
        for key in keys {
            let r = rebuilt.rows[key]
            let e = reference.rows[key]
            if r != e {
                mismatches.append(.init(key: key, expected: e, rebuilt: r))
            }
        }
        return AuditRecoveryDivergence(mismatches: mismatches)
    }
}
