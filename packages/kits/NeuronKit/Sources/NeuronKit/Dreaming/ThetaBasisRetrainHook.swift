// ThetaBasisRetrainHook.swift
//
// Seam for the dreaming daemon's THETA-gate basis-retrain duty: a protocol
// the daemon calls once per THETA cycle (daily cadence) to trigger a full
// corpus basis retrain so distributional embedding bases do not stale without
// a manual `moot_reindex`.
//
// ── Design rationale ─────────────────────────────────────────────────────
// Distributional embedding bases (RI / PPMI / LSA / NMF) freeze their
// vocabulary at training time. The corpus-growth probe (`CorpusGrowthProbe`)
// fires a retrain on vocabulary GROWTH within ALPHA cycles, but that gate
// can be silent on quiescent estates where content changes in kind rather
// than in raw word count. Attaching a daily unconditional retrain to the
// existing THETA gate (24 h cadence) ensures every live estate refreshes its
// basis at least once per day, matching the documentation's "no stale basis
// without a manual moot_reindex" promise.
//
// ── Seam idiom ───────────────────────────────────────────────────────────
// Mirrors the `CorpusGrowthProbe` injection pattern: the protocol is pure
// (no GLK import in the daemon), the production adapter (`EstateThetaBasisRetrainHook`)
// imports GeniusLocusKit and delegates through the B-1-compliant
// `GeniusLocusKit.reindexCorpus(handle:now:)` surface. The daemon stores
// it as `private let thetaRetrainHook: (any ThetaBasisRetrainHook)?` so nil
// safely disables the duty in tests that do not wire a Corpus.
//
// ── Failure handling ─────────────────────────────────────────────────────
// Retrain failures are caught and logged at the OSLog error level but do NOT
// abort the THETA cycle — a stale basis degrades dense recall; it does not
// break the daemon's proposal and diary functions.

import Foundation
import GeniusLocusKit
import OSLog

// MARK: - Protocol

/// Seam for the THETA-gate daily corpus basis retrain
/// (NEURONKIT_SPEC § 3.1 theta-retrain extension).
///
/// Injected into `DreamingDaemon`. The daemon calls `retrain(now:)` once
/// per THETA cycle regardless of whether consolidation produced proposals,
/// so the embedding basis stays current with ingested content on a daily
/// cadence. `EstateThetaBasisRetrainHook` is the production adapter; tests
/// use in-memory fakes.
///
/// - Note: A nil `thetaRetrainHook` in `DreamingDaemon.init` silently
///   disables the daily retrain (correct for LocusOnly estates and tests).
public protocol ThetaBasisRetrainHook: Sendable {

    /// Trigger a full corpus basis retrain for this hook's estate.
    ///
    /// Called once per THETA cycle, after the consolidation diary entry is
    /// written and `lastThetaRunAt` has been advanced. Failures are caught
    /// by the daemon and logged, so this method may throw without aborting
    /// the cycle.
    ///
    /// - Parameter now: Deterministic timestamp from the caller (never
    ///   `Date()` inside the engine; CLAUDE.md determinism rule).
    func retrain(now: Date) async throws
}

// MARK: - Production adapter

/// Production `ThetaBasisRetrainHook` that delegates to
/// `GeniusLocusKit.reindexCorpus(handle:now:)`.
///
/// Lives in NeuronKit — it imports both NeuronKit (the `ThetaBasisRetrainHook`
/// protocol) and GeniusLocusKit (the composition surface), which is the same
/// layering used by `EstateCorpusGrowthProbe`. The daemon never touches
/// GeniusLocusKit or CorpusKit directly.
public struct EstateThetaBasisRetrainHook: ThetaBasisRetrainHook {

    private let handle: EstateHandle
    private let kit: GeniusLocusKit

    private static let log = Logger(
        subsystem: "com.mootx01.kit",
        category: "NeuronKit"
    )

    /// Construct a hook over the addressed estate.
    ///
    /// - Parameters:
    ///   - handle: The estate whose Corpus basis this hook retrains daily.
    ///   - kit: The GeniusLocusKit actor that owns the estate registry.
    public init(handle: EstateHandle, kit: GeniusLocusKit) {
        self.handle = handle
        self.kit = kit
    }

    /// Full corpus basis retrain via `GeniusLocusKit.reindexCorpus(handle:now:)`.
    ///
    /// A nil corpus (LocusOnly estate) is handled gracefully by GLK — the
    /// method returns without error when no Corpus is registered.
    public func retrain(now: Date) async throws {
        try await kit.reindexCorpus(handle: handle, now: now)
        Self.log.info(
            "theta-retrain: corpus basis retrained for estate \(handle.estateUUID, privacy: .public)"
        )
    }
}
