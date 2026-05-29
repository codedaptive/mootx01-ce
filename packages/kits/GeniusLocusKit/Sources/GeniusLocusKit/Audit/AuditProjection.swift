// AuditProjection.swift
//
// Deterministic current-state and asOf projection over the unified
// audit log (mission GLK-03). The projection folds entries from both
// storage tiers in HLC order; the result is a per-(tier, rowID) state
// snapshot the substrate can compare to live storage for recovery and
// asOf reads.
//
// Cookbook references (engineering cookbook v0.36):
//   §5.1   G-Set CRDT semantics
//   §5.3   Projection rules — last-writer-wins per field-path, HLC ordered
//   §5.5   Reconstruction from audit log
//
// Cross-tier ordering: each row lives in exactly one tier (a LocusKit
// drawer UUID and a CorpusKit chunk UUID live in different namespaces).
// Projection therefore keys by `(tier, rowID)` so a UUID collision
// across tiers — pathologically possible — does not fold one tier's
// state on top of the other.

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

// MARK: - Projected state

/// State of one row as of the projection's cutoff. The fold records
/// the last value seen per `fieldPath`, the HLC of the last event that
/// affected the row, the verb that produced it, and whether the row
/// reached a tombstone state via `withdraw` / `expunge`.
public struct UnifiedRowProjection: Sendable, Equatable {
    public var tier: AuditTier
    public var rowID: UUID
    public var fields: [String: UnifiedAuditValue]
    public var lastHLC: HLC
    public var lastVerb: UnifiedAuditVerb
    public var withdrawn: Bool
    public var expunged: Bool

    public init(tier: AuditTier,
                rowID: UUID,
                fields: [String: UnifiedAuditValue] = [:],
                lastHLC: HLC = .zero,
                lastVerb: UnifiedAuditVerb = .capture,
                withdrawn: Bool = false,
                expunged: Bool = false) {
        self.tier = tier
        self.rowID = rowID
        self.fields = fields
        self.lastHLC = lastHLC
        self.lastVerb = lastVerb
        self.withdrawn = withdrawn
        self.expunged = expunged
    }
}

/// Full projection across both tiers, keyed by `(tier, rowID)`.
public struct UnifiedProjection: Sendable, Equatable {

    /// Composite key. UUID alone is not enough: cross-tier collision
    /// (a LocusKit row and a CorpusKit row sharing a UUID) would collapse
    /// the two states. The composite key keeps the namespaces disjoint.
    public struct Key: Hashable, Sendable {
        public let tier: AuditTier
        public let rowID: UUID
        public init(tier: AuditTier, rowID: UUID) {
            self.tier = tier
            self.rowID = rowID
        }
    }

    public private(set) var rows: [Key: UnifiedRowProjection]

    public init(rows: [Key: UnifiedRowProjection] = [:]) {
        self.rows = rows
    }

    public var count: Int { rows.count }
    public var isEmpty: Bool { rows.isEmpty }

    /// Live (non-tombstoned) rows only. Convenience for callers that
    /// want the visible state without inspecting `withdrawn` / `expunged`
    /// per row.
    public var liveRows: [UnifiedRowProjection] {
        rows.values.filter { !$0.withdrawn && !$0.expunged }
    }

    /// All rows belonging to one tier.
    public func rows(in tier: AuditTier) -> [UnifiedRowProjection] {
        rows.values.filter { $0.tier == tier }
    }

    public subscript(key: Key) -> UnifiedRowProjection? {
        rows[key]
    }

    public func row(tier: AuditTier, rowID: UUID) -> UnifiedRowProjection? {
        rows[Key(tier: tier, rowID: rowID)]
    }
}

// MARK: - The fold

public enum AuditProjectionFold {

    /// Project the live (current) state from a unified log.
    ///
    /// All entries participate. Convergence (cookbook §5.4) guarantees
    /// the result depends only on the set of entries, not the order
    /// they were added — internal HLC sort is what makes the fold
    /// deterministic across replicas.
    public static func project(_ log: UnifiedAuditLog) -> UnifiedProjection {
        return foldOrdered(log.orderedEntries)
    }

    /// Project the state AS OF a specific HLC. Entries strictly later
    /// than `asOf` are excluded; the result is the substrate's view at
    /// that point in time. asOf reconstruction is the recovery primitive
    /// the mission requires across both tiers.
    public static func project(_ log: UnifiedAuditLog, asOf cutoff: HLC) -> UnifiedProjection {
        return foldOrdered(log.entries(asOf: cutoff))
    }

    /// Internal fold. The caller is responsible for HLC ordering;
    /// `UnifiedAuditLog.orderedEntries` and `entries(asOf:)` both
    /// produce that ordering.
    private static func foldOrdered(_ entries: [UnifiedAuditEntry]) -> UnifiedProjection {
        var rows: [UnifiedProjection.Key: UnifiedRowProjection] = [:]
        for entry in entries {
            let key = UnifiedProjection.Key(tier: entry.tier, rowID: entry.rowID)
            var state = rows[key] ?? UnifiedRowProjection(
                tier: entry.tier, rowID: entry.rowID
            )
            // Last-writer-wins per field-path per cookbook §5.3.
            // Entries arrive in HLC order, so the final assignment per
            // field-path is the latest one.
            state.fields[entry.fieldPath] = entry.afterValue
            state.lastHLC = entry.hlc
            state.lastVerb = entry.verb
            switch entry.verb {
            case .withdraw:
                state.withdrawn = true
            case .expunge:
                // Expunge is a sticky tombstone (cookbook §10.5). Once
                // an entry has expunged this row, no later mutation may
                // un-expunge it; mutation entries after an expunge are
                // historically interesting but do not revive the row.
                state.expunged = true
            case .capture:
                // Re-capture after expunge is treated as a new instance
                // in the substrate. The projection mirrors that by
                // clearing the tombstone flags only when no expunge
                // has fired yet. If an expunge has fired, the row stays
                // expunged — the substrate would issue a new UUID for
                // the new instance.
                if !state.expunged {
                    state.withdrawn = false
                }
            default:
                break
            }
            rows[key] = state
        }
        return UnifiedProjection(rows: rows)
    }
}
