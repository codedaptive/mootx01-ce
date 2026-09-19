// CorpusGrowthProbe.swift
//
// Seam for the dreaming daemon's auto-reindex step: a protocol the daemon
// calls to (1) read the current vocabulary anchor via `vocabAnchor()` and
// (2) trigger a full basis retrain via `reindex(now:)` when vocabulary
// growth crosses the configured fraction/floor threshold.
//
// ── Which providers are retrained ─────────────────────────────────────────
// This probe triggers `GeniusLocusKit.reindexCorpus`, which retrains whatever
// providers are registered in the estate's Corpus. `CorpusEnsemble.defaultEnsemble()`
// returns RI and LSA — so this probe retrains both providers on every retrain cycle.
//
// ── Design rationale ─────────────────────────────────────────────────────
// Distributional embedding bases (RI / LSA) train on the
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
// the two Brain-layer methods `corpusVocabAnchor(handle:)` and
// `reindexCorpus(handle:now:)` — both B-1-compliant GLK surface calls.
// The daemon never touches CorpusKit directly.

import Foundation
import GeniusLocusKit
import OSLog

// MARK: - Auto-reindex threshold (vocabulary-growth trigger, P3 item 5)

/// Fractional vocabulary growth required to trigger an auto-reindex.
///
/// The retrain trigger fires on VOCABULARY drift, not raw chunk count:
/// distributional embeddings (RI / LSA) freeze their vocabulary at
/// training time, so what degrades dense recall is novel TERMS going OOV, not
/// chunks per se. The maintained counts table (P3) makes the live vocabulary
/// size a cheap, always-current read, so the gate measures the fraction by which
/// the vocabulary has grown since the last retrain.
///
/// When `(liveVocab − lastReindexVocab)` reaches `lastReindexVocab × this
/// fraction` (or the absolute floor below, whichever is larger), the dreaming
/// daemon calls `CorpusGrowthProbe.reindex`. 0.10 (10% vocabulary growth) is the
/// documented starting value — proportional, so a large corpus tolerates more
/// absolute drift before the expensive full retrain, while a small one retrains
/// sooner. Callers may override via `DreamingDaemon.init`.
public let autoReindexVocabGrowthFraction: Double = 0.10

/// Absolute floor on new vocabulary terms before an auto-reindex, regardless of
/// the fraction. Dominates at small vocabularies, where a 10% fraction would be
/// a handful of terms and cause thrashing; also the effective cold-start gate.
/// 25 new terms is the documented starting value; overridable via
/// `DreamingDaemon.init`.
public let autoReindexVocabGrowthFloor: Int = 25

// MARK: - Protocol

/// Read-and-trigger seam for corpus auto-reindex (NEURONKIT_SPEC § 3.1
/// auto-reindex extension).
///
/// Injected into `DreamingDaemon`. The daemon calls `vocabAnchor()` at
/// every cycle to measure vocabulary growth since the last retrain, then calls
/// `reindex(now:)` when growth crosses the vocab-growth fraction/floor.
/// `EstateCorpusGrowthProbe` is the production adapter; in-memory fakes
/// satisfy this protocol in tests.
public protocol CorpusGrowthProbe: Sendable {

    /// Current maintained vocabulary anchor for the probe's estate corpus — the
    /// maximum maintained vocabulary size across its trainable providers. Returns
    /// 0 when no Corpus is wired (e.g. a LocusOnly estate) or no trainable
    /// provider is present, so the growth delta is always zero and the gate never
    /// fires for un-wired estates.
    func vocabAnchor() async throws -> Int

    /// Trigger a full basis retrain on the probe's estate corpus.
    ///
    /// - Parameter now: Deterministic timestamp from the caller (never
    ///   `Date()` inside the engine; CLAUDE.md determinism rule).
    /// - Returns: `true` for a full retrain, `false` when a backstop was
    ///   reached and the serving basis was kept (F11: DEGRADED). The caller
    ///   (`DreamingDaemon.check_corpus_growth`-equivalent gate) must not
    ///   advance its vocabulary baseline on `false`, so a degraded retrain
    ///   re-fires on the next cycle instead of the drift it hit the backstop
    ///   under being silently accepted as caught up.
    @discardableResult
    func reindex(now: Date) async throws -> Bool
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
        subsystem: NeuronKitLogging.subsystem,
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

    /// Current vocabulary anchor via `GeniusLocusKit.corpusVocabAnchor(handle:)`.
    public func vocabAnchor() async throws -> Int {
        try await kit.corpusVocabAnchor(handle: handle)
    }

    /// Full basis retrain via `GeniusLocusKit.reindexCorpus(handle:now:)`.
    /// Returns GLK's own completed/degraded outcome unchanged (F11).
    @discardableResult
    public func reindex(now: Date) async throws -> Bool {
        let completed = try await kit.reindexCorpus(handle: handle, now: now)
        Self.log.info(
            "auto-reindex: corpus retrained for estate \(handle.estateUUID, privacy: .public) (completed: \(completed, privacy: .public))"
        )
        return completed
    }
}
