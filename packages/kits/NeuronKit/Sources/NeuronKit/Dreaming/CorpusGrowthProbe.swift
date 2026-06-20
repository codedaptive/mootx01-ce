// CorpusGrowthProbe.swift
//
// Seam for the dreaming daemon's auto-reindex step: a protocol the daemon
// calls to (1) read the current corpus chunk count and (2) trigger a full
// basis retrain when corpus growth crosses a threshold.
//
// ── Design rationale ─────────────────────────────────────────────────────
// Distributional embedding bases (RI / PPMI / LSA / NMF) train on the
// vocabulary present at first ingest and never grow incrementally — their
// basis is frozen until an explicit `reindex`. Terms ingested AFTER the
// last retrain are OOV (out-of-vocabulary) and produce only zero-vectors
// in the dense recall lane, silently missing novel content. The daemon is
// the natural auto-trigger: it already runs on a background cadence and
// has access to the GLK seam surface. Adding the growth probe here keeps
// the retrain policy inside the autonomic governor (NeuronKit) where it
// belongs, rather than in app code or the GLK verb surface.
//
// ── Separation from existing seams ───────────────────────────────────────
// `DreamingSubstrateReader` and `DreamingProposalSink` are untouched so
// their Rust conformance contracts remain stable. The probe is a separate
// injected seam — optional (nil = no auto-reindex, correct for test fakes
// that do not wire a Corpus) — so existing tests need no changes.
//
// ── B-1 compliance ───────────────────────────────────────────────────────
// The production adapter (`EstateCorpusGrowthProbe`) calls GLK through
// the two new Brain-layer methods `corpusChunkCount(handle:)` and
// `reindexCorpus(handle:now:)` — both B-1-compliant GLK surface calls.
// The daemon never touches CorpusKit directly.

import Foundation
import GeniusLocusKit
import OSLog

// MARK: - Auto-reindex threshold

/// Corpus growth required to trigger an auto-reindex.
///
/// When the live chunk count exceeds `lastReindexChunkCount` by at least
/// this many chunks, the dreaming daemon calls `CorpusGrowthProbe.reindex`.
///
/// Vocabulary coverage rationale: distributional embeddings (RI / PPMI /
/// LSA / NMF) are trained on the full vocabulary at training time. Each
/// new chunk may introduce novel terms; 25 chunks is a practical "enough
/// vocabulary drift has accumulated" threshold that balances two costs:
///   - Too low: frequent, expensive full-corpus retrains for tiny gains.
///   - Too high: long windows of OOV terms degrading dense recall quality.
/// 25 is the documented starting value; callers with denser or sparser
/// ingestion patterns may override via the `threshold` parameter on
/// `DreamingDaemon.init`.
public let autoReindexGrowthThreshold: Int = 25

// MARK: - Protocol

/// Read-and-trigger seam for corpus auto-reindex (NEURONKIT_SPEC § 3.1
/// auto-reindex extension).
///
/// Injected into `DreamingDaemon`. The daemon calls `chunkCount()` at
/// every cycle to measure growth since the last retrain, then calls
/// `reindex(now:)` when growth crosses `autoReindexGrowthThreshold`.
/// `EstateCorpusGrowthProbe` is the production adapter; in-memory fakes
/// satisfy this protocol in tests.
public protocol CorpusGrowthProbe: Sendable {

    /// Current chunk count for the probe's estate corpus. Returns 0 when
    /// no Corpus is wired (e.g. a LocusOnly estate), so the growth delta
    /// is always zero and the gate never fires for un-wired estates.
    func chunkCount() async throws -> Int

    /// Trigger a full basis retrain on the probe's estate corpus.
    ///
    /// - Parameter now: Deterministic timestamp from the caller (never
    ///   `Date()` inside the engine; CLAUDE.md determinism rule).
    func reindex(now: Date) async throws
}

// MARK: - Production adapter

/// Production `CorpusGrowthProbe` that delegates to `GeniusLocusKit`'s
/// two Brain-layer corpus methods. Lives in NeuronKit — it imports both
/// NeuronKit (`CorpusGrowthProbe`) and GeniusLocusKit, which are the
/// only two packages that see both the protocol and the GLK surface.
public struct EstateCorpusGrowthProbe: CorpusGrowthProbe {

    private let handle: EstateHandle
    private let kit: GeniusLocusKit

    private static let log = Logger(
        subsystem: "com.mootx01.kit",
        category: "NeuronKit"
    )

    /// Construct a probe over the addressed estate.
    ///
    /// - Parameters:
    ///   - handle: The estate whose Corpus growth this probe tracks.
    ///   - kit: The GeniusLocusKit actor that owns the estate registry.
    public init(handle: EstateHandle, kit: GeniusLocusKit) {
        self.handle = handle
        self.kit = kit
    }

    /// Current chunk count via `GeniusLocusKit.corpusChunkCount(handle:)`.
    public func chunkCount() async throws -> Int {
        try await kit.corpusChunkCount(handle: handle)
    }

    /// Full basis retrain via `GeniusLocusKit.reindexCorpus(handle:now:)`.
    public func reindex(now: Date) async throws {
        try await kit.reindexCorpus(handle: handle, now: now)
        Self.log.info(
            "auto-reindex: corpus retrained for estate \(handle.estateUUID, privacy: .public)"
        )
    }
}
