// Corpus+FloatLane.swift
//
// The whole-record dense float query surface of the legacy `Corpus` actor:
// nearest and farthest per-signal recall over the stored float rows
// (vectorIndex 1) and the per-signal discrimination signal. WholeRecordDense
// sidecar: compiled only under MOOTX01_WHOLE_RECORD_DENSE; the default build
// carries no float query surface and writes no float rows.
//
// The engine members this extension reads (`slots`, `vectorStore`,
// `chunkSourceMap`, `defaultProvider`, `_forcedFloatError`) are `package`
// visible for exactly this target.
//
// Rust twin: rust/src/corpus/float_lane.rs.

#if MOOTX01_WHOLE_RECORD_DENSE
import CorpusKit
import Foundation
import MootProductIdentity
import IntellectusLib
import OSLog
import SynapseKit

/// Sidecar OSLog logger (category "CorpusKit"): store errors on the float
/// lane are logged so they are never swallowed.
private let floatLaneLog = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "CorpusKit")

extension Corpus {

    /// Test-only: force `floatNearest` to return `.storeError(error)` on the next call.
    ///
    /// Intended for tests that need to verify the store-error code path (observable
    /// degradation contract §4). The error is consumed on the first `floatNearest`
    /// call after this is set; subsequent calls behave normally.
    ///
    /// Never call this in production code. Marked `internal` so it is visible to
    /// `@testable import CorpusKit` test suites and invisible to callers outside the module.
    func _testForceFloatStoreError(_ error: Error) {
        _forcedFloatError = error
    }

    /// Dense float nearest-neighbour recall (Lane D): embed `query` to its
    /// pooled float vector and rank stored chunks by cosine over the in-house
    /// `FloatBruteForceIndex`. Returns a `FloatLaneOutcome` that is always
    /// observable — dark lanes carry a typed reason, store errors are logged
    /// and counted, never swallowed.
    ///
    /// This is the cosine path the 256-bit SimHash-Hamming lane could not
    /// serve: cosine is scale-invariant, so an answer statement ranks above a
    /// near-duplicate of the question.
    ///
    /// **Degradation contract:** this method never throws. A dark lane is
    /// represented as `.unavailableProviderOptOut`, `.unavailableNoFloatRows`,
    /// or `.emptyQuery` — all expected outcomes. `.storeError` is NOT expected:
    /// the error is logged (OSLog "CorpusKit") and emitted as
    /// `corpus.float_lane.store_error` telemetry before returning so the
    /// failure is always observable. The query continues on other lanes.
    ///
    /// **Telemetry** (off by default — single `Atomic<Bool>` load when disabled):
    /// - `corpus.float_lane.hit`           — lane ran and returned ≥1 result.
    /// - `corpus.float_lane.dark_provider` — provider opted out.
    /// - `corpus.float_lane.dark_no_rows`  — no float rows stored.
    /// - `corpus.float_lane.store_error`   — unexpected store failure.
    ///
    /// - Parameters:
    ///   - query: the query text.
    ///   - limit: maximum number of matches.
    /// - Returns: a `FloatLaneOutcome` describing the result.
    public func floatNearest(query: String, limit: Int) async -> FloatLaneOutcome {
        guard limit > 0, !query.isEmpty else {
            // Empty query or zero limit — no telemetry: this is a no-op call.
            return .emptyQuery
        }

        // Test-only hook: if a forced error is installed, consume it and return
        // .storeError immediately. This exercises the observable store-error code
        // path without requiring production modifications to the vector store.
        // Both entry points consult the hook: this single-signal path, and the
        // per-signal `floatNearestPerSignal` for its DEFAULT slot (slot 0), so the
        // store-error dark contract is observable through whichever path GLK uses.
        if let forced = _forcedFloatError {
            _forcedFloatError = nil
            floatLaneLog.error("floatNearest: findNearestFloat failed — \(forced, privacy: .public)")
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .storeError(forced)
        }

        // Single-signal entry point: run the dense float lane on the DEFAULT
        // signal. The per-provider mechanics live in `floatNearest(provider:…)`
        // so `floatNearestPerSignal` can reuse them unchanged.
        return await floatNearest(provider: defaultProvider, query: query, limit: limit)
    }

    /// Dense float recall for ONE provider — the per-signal mechanics shared by
    /// `floatNearest`/`floatNearestPerSignal` (nearest) and
    /// `floatFarthestPerSignal` (farthest, anti-similarity).
    ///
    /// Embeds `query` via `provider.embedFloat`, ranks stored chunks for that
    /// provider's modelID by cosine over the in-house `FloatBruteForceIndex`,
    /// aggregates chunk hits to source (drawer) level, and returns an observable
    /// `FloatLaneOutcome`. The telemetry counters and the degradation contract
    /// are identical regardless of direction.
    ///
    /// `direction` selects the objective (mission 6b-modifiers-antisim):
    ///   - `.nearest`  — surface the most SIMILAR sources. The store returns the
    ///     nearest chunks (`findNearestFloat`); a source's similarity is its
    ///     BEST (max) chunk cosine; sources rank similarity DESCENDING. This is
    ///     byte-identical to the pre-antisim behaviour (default).
    ///   - `.farthest` — surface the most DISSIMILAR sources ("find things
    ///     UNLIKE this"). The store returns the farthest chunks
    ///     (`findFarthestFloat`); a source's dissimilarity is its WORST (min)
    ///     chunk cosine; sources rank similarity ASCENDING. The max→min
    ///     inversion is required: a source's anti-similarity is governed by its
    ///     LEAST-similar chunk, the mirror of nearest's best-chunk rule.
    private func floatNearest(
        provider: any EmbeddingProvider,
        query: String,
        limit: Int,
        direction: SearchDirection = .nearest
    ) async -> FloatLaneOutcome {
        // Attempt to embed the query text via the float lane.
        //
        // Three distinct paths:
        //   1. Result is non-empty → proceed with the probe vector.
        //   2. Result is empty ([] from an untrained provider, or text that
        //      tokenises to nothing) → structural opt-out. Emit the
        //      dark_provider counter and return .unavailableProviderOptOut.
        //   3. Throw SynapseKitError.embedFloatVocabMiss → the provider HAS a
        //      trained basis but all query tokens are OOV. This is a vocabulary
        //      coverage miss, not a structural opt-out. Return
        //      .unavailableNoVocabHit with its own counter so callers observe
        //      the correct dark-lane reason.
        //   4. Any other throw → structural opt-out (same as path 2).
        //
        // Path 2 and 4 share the dark_provider counter. Path 3 has its own
        // dark_vocabMiss counter (corpus.float_lane.dark_vocab_miss).
        let probe: [Float]
        do {
            let result = try await provider.embedFloat(query)
            guard !result.isEmpty else {
                // Provider returned an empty vector (untrained distributional
                // provider, or text that produces no tokens). Classify as
                // structural opt-out: the provider cannot produce a float vector
                // for structural reasons, not because of vocabulary coverage.
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_provider",
                    value: 1.0,
                    tags: ["kit": "CorpusKit"],
                    ts: Date().timeIntervalSince1970
                ))
                return .unavailableProviderOptOut
            }
            probe = result
        } catch SynapseKitError.embedFloatVocabMiss {
            // Trained distributional provider: basis exists but query tokens
            // are all OOV. This is a vocabulary coverage miss — truthfully
            // distinct from a structural opt-out. Emit a separate counter
            // so telemetry surfaces vocabulary coverage vs. lane availability.
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_vocab_miss",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableNoVocabHit
        } catch {
            // Provider threw a non-vocabMiss error — structural opt-out (e.g.
            // the deterministic provider, or any provider without a float lane).
            // Log nothing; emit the dark_provider counter only.
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_provider",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableProviderOptOut
        }

        // Over-fetch 4× at the CHUNK granularity so that after source-level
        // aggregation we still have at least `limit` sources, mirroring
        // bm25TopKBySource's over-fetch discipline. The float index keys rows by
        // chunk.id (the vector item_id); we aggregate to sourceID below.
        let matches: [VectorMatch]
        do {
            // Direction selects which end of the cosine ranking the store
            // returns. Farthest is NOT a reordering of nearest results — the
            // dissimilar chunks are not in the nearest top-K, so the store must
            // run the farthest scan (mission 6b-modifiers-antisim).
            switch direction {
            case .nearest:
                matches = try await vectorStore.findNearestFloat(
                    probe: probe, modelID: provider.modelID, limit: limit * 4)
            case .farthest:
                matches = try await vectorStore.findFarthestFloat(
                    probe: probe, modelID: provider.modelID, limit: limit * 4)
            }
        } catch {
            // Store threw — this is NOT expected. Log it via OSLog so it is
            // never silent, then emit the store_error counter for telemetry
            // dashboards and alerts.
            floatLaneLog.error("floatNearest: findNearestFloat failed — \(error, privacy: .public)")
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .storeError(error)
        }

        // Empty matches means no float rows are stored — expected dark outcome.
        guard !matches.isEmpty else {
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_no_rows",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableNoFloatRows
        }

        // Aggregate chunk-level cosine to SOURCE (drawer) level. The vector
        // item_id is the chunk uuid string; chunkSourceMap resolves it to the
        // sourceID the caller ingested under (the drawer id in the GLK context),
        // exactly as bm25TopKBySource does, so float hits hydrate back to the
        // real Drawer row.
        //   .nearest  — a source's similarity is its BEST (max) chunk cosine.
        //   .farthest — a source's anti-similarity is governed by its WORST
        //               (min) chunk cosine: a source is "unlike the query" only
        //               if even its closest chunk is far. Picking max here would
        //               surface sources that happen to have one near chunk, the
        //               opposite of the anti-similarity objective.
        // VectorMatch.distance is the cosine DISTANCE (1 − sim) quantised
        // ×10_000 (FloatBruteForceIndex convention); recover sim = 1 − dist/1e4.
        var bySource: [String: Float] = [:]
        for m in matches {
            guard let chunkUUID = UUID(uuidString: m.itemID),
                  let sourceID = chunkSourceMap[chunkUUID] else { continue }
            let similarity = 1.0 - Float(m.distance) / 10_000.0
            switch direction {
            case .nearest:
                bySource[sourceID] = max(bySource[sourceID] ?? -Float.greatestFiniteMagnitude, similarity)
            case .farthest:
                bySource[sourceID] = min(bySource[sourceID] ?? Float.greatestFiniteMagnitude, similarity)
            }
        }

        // After source aggregation, no results means no chunks are in the
        // chunk→source map (all chunks were removed). Treat as no-rows dark.
        guard !bySource.isEmpty else {
            Intellectus.report(.metric(
                name: "corpus.float_lane.dark_no_rows",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            return .unavailableNoFloatRows
        }

        // Sort by similarity, sourceID ascending on tie (the universal
        // deterministic tie-break), and return the top `limit`.
        //   .nearest  — similarity DESCENDING (most similar first).
        //   .farthest — similarity ASCENDING (most dissimilar first).
        // The tie-break (sourceID ascending) is identical in both directions.
        var ranked = bySource.map { (itemID: $0.key, similarity: $0.value) }
        ranked.sort { a, b in
            if a.similarity != b.similarity {
                switch direction {
                case .nearest:  return a.similarity > b.similarity
                case .farthest: return a.similarity < b.similarity
                }
            }
            return a.itemID < b.itemID
        }
        let result = Array(ranked.prefix(limit))

        // Happy path — lane ran. Emit hit counter (count = result size so
        // dashboards can see both that the lane ran and how many hits emerged).
        Intellectus.report(.metric(
            name: "corpus.float_lane.hit",
            value: Double(result.count),
            tags: ["kit": "CorpusKit"],
            ts: Date().timeIntervalSince1970
        ))
        return .hits(result)
    }

    /// Compute a `FloatDiscriminationSignal` from a `FloatLaneOutcome`.
    ///
    /// Returns non-nil only for `.hits` with at least one result. The relative spread
    /// `(maxSim − minSim) / max(maxSim, 0.001)` is computed from the FIRST and LAST
    /// elements of the already-sorted similarity list — O(1), zero extra I/O.
    ///
    /// This helper is shared by `floatNearestPerSignalWithDiscrimination` on both
    /// `Corpus` and `CorpusContentEngine` so the measurement is defined once.
    nonisolated internal static func discriminationSignal(
        from outcome: FloatLaneOutcome
    ) -> FloatDiscriminationSignal? {
        guard case .hits(let hits) = outcome, !hits.isEmpty else { return nil }
        // `.hits` is sorted nearest-first (highest cosine first) for nearest recall.
        // maxSim is hits[0].similarity; minSim is hits.last!.similarity.
        let maxSim = hits[0].similarity
        let minSim = hits[hits.endIndex - 1].similarity
        // Guard against non-positive maxSim: cosines can be negative on an
        // insufficiently trained basis; treat that regime as saturated (spread = 0).
        let spread = maxSim > 0.001 ? (maxSim - minSim) / maxSim : 0.0
        return FloatDiscriminationSignal(
            relativeSpread: max(0.0, spread),
            hitCount: hits.count)
    }

    /// Per-signal dense float nearest-neighbour recall (the 6b RRF-fusion seam).
    ///
    /// Runs the dense float lane independently for EVERY held provider slot,
    /// each queried against its own modelID float index, and returns one ranked
    /// `FloatLaneOutcome` per signal tagged by that signal's `modelID`. The
    /// outcome ordering follows slot (construction) order, so `[0]` is always
    /// the default signal.
    ///
    /// This is the seam the 6b mission's RRF/consensus fusion consumes: each
    /// signal's per-source similarity ranking is exposed separately, preserving
    /// the `FloatLaneOutcome` dark-lane observability per signal (a signal whose
    /// provider opted out reports `.unavailableProviderOptOut`; one with no rows
    /// reports `.unavailableNoFloatRows`; and so on). NO fusion happens here —
    /// the caller (6b) decides how to combine the per-signal lists.
    ///
    /// For N=1 this returns a single-element array whose only outcome equals what
    /// `floatNearest(query:limit:)` would return — same default-signal mechanics.
    ///
    /// - Parameters:
    ///   - query: the query text.
    ///   - limit: maximum number of matches per signal.
    /// - Returns: `(modelID, outcome)` pairs, one per held signal, in slot order.
    ///   An empty query or zero limit returns one `.emptyQuery` outcome per
    ///   signal (no store access), mirroring the single-signal no-op guard.
    public func floatNearestPerSignal(
        query: String,
        limit: Int
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        // No-op guard mirrors floatNearest: an empty query / zero limit yields a
        // per-signal .emptyQuery without touching the store. Returning one entry
        // per signal keeps the result shape stable (the caller can still see
        // every signal's modelID).
        guard limit > 0, !query.isEmpty else {
            return slots.map { (modelID: $0.provider.modelID, outcome: .emptyQuery) }
        }

        // Test-only hook: a forced store error is consumed for the DEFAULT slot
        // (slot 0), mirroring the single-signal `floatNearest(query:limit:)`
        // contract. GLK's dense lane consumes this method, so the store-error dark
        // contract must remain observable through the per-signal path: the default
        // signal reports `.storeError`, other slots run normally. The seam is
        // single-use and consumed here exactly as the single-signal entry does.
        var forcedDefaultStoreError: FloatLaneOutcome? = nil
        if let forced = _forcedFloatError {
            _forcedFloatError = nil
            floatLaneLog.error("floatNearestPerSignal: findNearestFloat failed (default signal) — \(forced, privacy: .public)")
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error",
                value: 1.0,
                tags: ["kit": "CorpusKit"],
                ts: Date().timeIntervalSince1970
            ))
            forcedDefaultStoreError = .storeError(forced)
        }

        var results: [(modelID: String, outcome: FloatLaneOutcome)] = []
        results.reserveCapacity(slots.count)
        for (index, slot) in slots.enumerated() {
            let provider = slot.provider
            // Slot 0 (default signal) honours the forced-error seam if installed;
            // all other slots — and slot 0 when no seam is set — run the real lane.
            let outcome: FloatLaneOutcome
            if index == 0, let forced = forcedDefaultStoreError {
                outcome = forced
            } else {
                outcome = await floatNearest(provider: provider, query: query, limit: limit)
            }
            results.append((modelID: provider.modelID, outcome: outcome))
        }
        return results
    }

    /// Per-signal dense float FARTHEST recall — the anti-similarity sibling of
    /// `floatNearestPerSignal` (mission 6b-modifiers-antisim).
    ///
    /// Runs the dense float lane in the FARTHEST direction independently for
    /// EVERY held provider slot: each signal surfaces the most DISSIMILAR
    /// sources for its modelID ("find things UNLIKE this"), ranked least-similar
    /// first. The outcome shape, dark-lane observability, telemetry counters,
    /// and slot ordering are identical to `floatNearestPerSignal`; only the
    /// ranking objective differs (the store returns the farthest chunks, and a
    /// source's score is its WORST chunk cosine — see `floatNearest(provider:…)`).
    ///
    /// This is the seam GLK's RecallShape `antiSimilarLanes` consumes: a dense
    /// lane marked anti-similar queries THIS method for its per-signal list
    /// instead of `floatNearestPerSignal`, so the dissimilar candidates flow
    /// into the same RRF/consensus fold.
    ///
    /// The forced-error test seam is NOT consulted here — it is nearest-path
    /// test infrastructure (`floatNearest`/`floatNearestPerSignal` only), so the
    /// farthest path always runs the real lane.
    ///
    /// - Parameters:
    ///   - query: the query text.
    ///   - limit: maximum number of matches per signal.
    /// - Returns: `(modelID, outcome)` pairs, one per held signal, in slot
    ///   order. An empty query or zero limit returns one `.emptyQuery` outcome
    ///   per signal (no store access), mirroring the nearest no-op guard.
    public func floatFarthestPerSignal(
        query: String,
        limit: Int
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        guard limit > 0, !query.isEmpty else {
            return slots.map { (modelID: $0.provider.modelID, outcome: .emptyQuery) }
        }

        var results: [(modelID: String, outcome: FloatLaneOutcome)] = []
        results.reserveCapacity(slots.count)
        for slot in slots {
            let provider = slot.provider
            let outcome = await floatNearest(
                provider: provider, query: query, limit: limit, direction: .farthest)
            results.append((modelID: provider.modelID, outcome: outcome))
        }
        return results
    }

    /// Per-signal dense float nearest recall WITH per-query discrimination signal.
    ///
    /// Same semantics and return shape as `floatNearestPerSignal`, but each entry
    /// carries an optional `FloatDiscriminationSignal` alongside the outcome.
    /// The discrimination signal is non-nil exactly when the outcome is `.hits` with
    /// at least one result; it is `nil` for all dark-lane outcomes.
    ///
    /// **Discrimination computation:**
    /// For each `.hits` outcome, `relativeSpread = (maxSim − minSim) / max(maxSim, 0.001)`
    /// where `maxSim` and `minSim` are the first and last cosines of the already-sorted
    /// ranked list. This is O(1) and adds no store access or embed calls.
    ///
    /// **Policy boundary:** CorpusKit computes and exposes; calling code decides.
    /// No behaviour change inside this method or anywhere in CorpusKit — measurement only.
    /// RecallDirector (GLK) is the policy consumer: it discounts the dense contribution
    /// when the lane self-reports degeneracy. Standalone CorpusKit consumers may use
    /// the signal for their own fusion decisions.
    ///
    /// - Parameters:
    ///   - query: the query text.
    ///   - limit: maximum number of matches per signal.
    /// - Returns: `(modelID, outcome, discrimination)` triples, one per held signal,
    ///   in slot order. `discrimination` is nil for non-`.hits` outcomes.
    public func floatNearestPerSignalWithDiscrimination(
        query: String,
        limit: Int
    ) async -> [(modelID: String, outcome: FloatLaneOutcome, discrimination: FloatDiscriminationSignal?)] {
        // Delegate to the existing per-signal call, then compute discrimination from
        // each `.hits` outcome's already-sorted similarity list. The existing function
        // handles the forced-error test seam and all dark-lane paths, so this wrapper
        // stays thin and does not duplicate that logic.
        let perSignal = await floatNearestPerSignal(query: query, limit: limit)
        return perSignal.map { entry in
            let discrimination: FloatDiscriminationSignal? = Self.discriminationSignal(from: entry.outcome)
            return (modelID: entry.modelID, outcome: entry.outcome, discrimination: discrimination)
        }
    }
}
#endif // MOOTX01_WHOLE_RECORD_DENSE
