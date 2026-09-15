// CorpusContentEngine+FloatLane.swift
//
// The whole-record dense float surface of `CorpusContentEngine`: the
// per-signal nearest and farthest recall the RecallDirector's whole-record
// lane consumes, the discrimination signal, the float re-embed of one content
// record (`recomposeDenseVector`) and the forced store-error test seam.
//
// Rust twin: rust/src/content_engine/float_lane.rs.

import CorpusKit
import Foundation
import IntellectusLib
import SynapseKit

extension CorpusContentEngine {

    /// Re-embed ONLY the dense float (Lane D) vector for a single content ID.
    ///
    /// Resolves the current record from the source — picking up any newly-written
    /// `denseCompositionText` (e.g. a distillate written by the GLK distillation
    /// rider) — and writes a fresh float-vector row (vectorIndex: 1) for each
    /// active slot. Only the float (dense RI) lane is updated; BM25, binary
    /// (Hamming) vectors, coverage, and the idempotence checkpoint are untouched.
    ///
    /// **Why not the full index path?** The idempotence gate keys on the CONTENT
    /// digest (unchanged by distillation). Calling `index(force: true)` would
    /// bypass the gate but would also re-run BM25 indexing, changing IDF state for
    /// content whose text has not changed — wrong for the distillation path. This
    /// method bypasses BOTH the gate AND the BM25 path by targeting only the float
    /// lane directly. §9 BM25 isolation (SPEC_DISTILLATION_STORAGE) is preserved:
    /// the content and digest are unchanged, so BM25 scores remain byte-identical.
    /// For a corpus-wide dense-only update (basis-only retrains), use
    /// `reindex(now:laneScope:.dense)` instead of looping this method.
    ///
    /// **Concurrency:** routes through the CCE actor (not direct to `VectorStore`)
    /// so `countsAdmission` serialization is maintained against concurrent
    /// trainable-slot operations (FINDING_11X_MAINTENANCE_WALK_2026-07-28
    /// constraint 3). Returns false only when the content ID no longer resolves
    /// in the source; derived state is left unchanged in that case.
    ///
    /// - Parameters:
    ///   - id: The content ID to re-embed.
    ///   - now: The operation timestamp (passed in — never read inside the engine).
    /// - Returns: true when live content was found and re-embedded; false when
    ///   the ID no longer resolves.
    @discardableResult
    public func recomposeDenseVector(id: CorpusContentID, now: Date) async throws -> Bool {
        try validate(id: id)
        guard let record = try await source.record(for: id) else {
            return false
        }
        try await recomposeDenseFloat(record: record, now: now)
        return true
    }

    /// Dense-float-only vector upsert for one content record. Writes the float
    /// (vectorIndex: 1) row across all active slots using `effectiveDenseText`.
    /// Does NOT touch BM25, binary vectors, coverage, or the checkpoint.
    /// Called by `recomposeDenseVector` and the drain/sweep integration points.
    private func recomposeDenseFloat(record: CorpusContentRecord, now: Date) async throws {
        let unit = IndexUnit(
            key: record.id, text: record.text, denseText: record.denseCompositionText)
        var rows: [VectorPayloadInput] = []
        for slot in slots {
            let (_, floats) = try await slot.provider.embedPair(unit.effectiveDenseText)
            guard !floats.isEmpty else { continue }
            rows.append(VectorPayloadInput(
                itemID: unit.key, vectorIndex: 1,
                payload: VectorPayload(floats: floats),
                modelID: slot.provider.modelID,
                modelVersion: slot.provider.modelVersion,
                filedAt: now))
        }
        if !rows.isEmpty {
            try await vectorStore.addPayloads(rows)
        }
    }

    // MARK: - Per-signal dense float lanes (the RecallDirector seam)

    /// Per-signal dense float NEAREST recall — content-ID keyed. One
    /// `(modelID, outcome)` pair per held slot, in slot order. Hit item IDs
    /// are canonical content IDs (passage keys aggregate to their content
    /// ID before ranking).
    /// Per-signal dense float NEAREST recall.
    ///
    /// - Parameters:
    ///   - query: the natural-language query string.
    ///   - limit: the candidate-pool depth per signal.
    ///   - metric: the distance function to use. Defaults to `.cosine` so
    ///     callers that do not pass a metric (pre-floatMetric call sites) see
    ///     byte-identical behaviour — no silent behaviour change.
    public func floatNearestPerSignal(
        query: String, limit: Int, metric: FloatMetric = .cosine
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        await floatPerSignal(query: query, limit: limit, direction: .nearest, metric: metric)
    }

    /// Single-signal dense float nearest recall — the DEFAULT slot's
    /// outcome (compatibility convenience over `floatNearestPerSignal`).
    public func floatNearest(query: String, limit: Int) async -> FloatLaneOutcome {
        await floatNearestPerSignal(query: query, limit: limit).first?.outcome ?? .emptyQuery
    }

    /// Per-signal dense float FARTHEST (anti-similarity) recall.
    ///
    /// - Parameters:
    ///   - query: the natural-language query string.
    ///   - limit: the candidate-pool depth per signal.
    ///   - metric: the distance function to use. Defaults to `.cosine`.
    public func floatFarthestPerSignal(
        query: String, limit: Int, metric: FloatMetric = .cosine
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        await floatPerSignal(query: query, limit: limit, direction: .farthest, metric: metric)
    }

    /// Per-signal dense float nearest recall WITH per-query discrimination signal.
    ///
    /// Same semantics and return shape as `floatNearestPerSignal`, but each entry
    /// carries an optional `FloatDiscriminationSignal` alongside the outcome.
    /// Discrimination is non-nil exactly when the outcome is `.hits` with ≥1 result.
    ///
    /// **Measurement only:** no behaviour change inside `CorpusContentEngine`.
    /// RecallDirector (GLK) consumes the signal to discount the dense contribution
    /// when the lane self-reports degeneracy. Standalone consumers may use the signal
    /// for their own fusion decisions.
    ///
    /// See `FloatDiscriminationSignal` for the statistic definition and threshold guidance.
    ///
    /// - Parameters:
    ///   - query: the natural-language query string.
    ///   - limit: the candidate-pool depth per signal.
    ///   - metric: the distance function to use. Defaults to `.cosine`.
    public func floatNearestPerSignalWithDiscrimination(
        query: String, limit: Int, metric: FloatMetric = .cosine
    ) async -> [(modelID: String, outcome: FloatLaneOutcome, discrimination: FloatDiscriminationSignal?)] {
        let perSignal = await floatNearestPerSignal(query: query, limit: limit, metric: metric)
        return perSignal.map { entry in
            (modelID: entry.modelID,
             outcome: entry.outcome,
             discrimination: Corpus.discriminationSignal(from: entry.outcome))
        }
    }

    /// Install the single-use forced float store error (test seam).
    public func _testForceFloatStoreError(_ error: Error) {
        _forcedFloatError = error
    }

    private func floatPerSignal(
        query: String, limit: Int, direction: SearchDirection, metric: FloatMetric = .cosine
    ) async -> [(modelID: String, outcome: FloatLaneOutcome)] {
        guard limit > 0, !query.isEmpty else {
            return slots.map { (modelID: $0.provider.modelID, outcome: .emptyQuery) }
        }
        // Consume the forced-error seam for the DEFAULT slot (nearest path
        // only — same contract as the legacy engine's seam).
        var forcedDefault: FloatLaneOutcome? = nil
        if direction == .nearest, let forced = _forcedFloatError {
            _forcedFloatError = nil
            Intellectus.report(.metric(
                name: "corpus.float_lane.store_error", value: 1.0,
                tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
            forcedDefault = .storeError(forced)
        }
        var results: [(modelID: String, outcome: FloatLaneOutcome)] = []
        results.reserveCapacity(slots.count)
        for (slotIndex, slot) in slots.enumerated() {
            if slotIndex == 0, let forced = forcedDefault {
                results.append((slot.provider.modelID, forced))
                continue
            }
            let provider = slot.provider
            let probe: [Float]
            do {
                let result = try await provider.embedFloat(query)
                guard !result.isEmpty else {
                    Intellectus.report(.metric(
                        name: "corpus.float_lane.dark_provider", value: 1.0,
                        tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                    results.append((provider.modelID, .unavailableProviderOptOut))
                    continue
                }
                probe = result
            } catch SynapseKitError.embedFloatVocabMiss {
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_vocab_miss", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                results.append((provider.modelID, .unavailableNoVocabHit))
                continue
            } catch {
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_provider", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                results.append((provider.modelID, .unavailableProviderOptOut))
                continue
            }
            let matches: [VectorMatch]
            do {
                switch direction {
                case .nearest:
                    matches = try await vectorStore.findNearestFloat(
                        probe: probe, modelID: provider.modelID, limit: limit * 4, metric: metric)
                case .farthest:
                    matches = try await vectorStore.findFarthestFloat(
                        probe: probe, modelID: provider.modelID, limit: limit * 4, metric: metric)
                }
            } catch {
                Intellectus.report(.metric(
                    name: "corpus.float_lane.store_error", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                results.append((provider.modelID, .storeError(error)))
                continue
            }
            guard !matches.isEmpty else {
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_no_rows", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                results.append((provider.modelID, .unavailableNoFloatRows))
                continue
            }
            // Aggregate unit hits to canonical content IDs — DIRECT identity;
            // a passage key parses to its content ID, a whole-content key IS it.
            var byContent: [String: Float] = [:]
            for match in matches {
                let id = IndexUnitIdentity.contentID(fromItemKey: match.itemID)
                let similarity = 1.0 - Float(match.distance) / 10_000.0
                switch direction {
                case .nearest:
                    byContent[id] = max(byContent[id] ?? -Float.greatestFiniteMagnitude, similarity)
                case .farthest:
                    byContent[id] = min(byContent[id] ?? Float.greatestFiniteMagnitude, similarity)
                }
            }
            guard !byContent.isEmpty else {
                Intellectus.report(.metric(
                    name: "corpus.float_lane.dark_no_rows", value: 1.0,
                    tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
                results.append((provider.modelID, .unavailableNoFloatRows))
                continue
            }
            var ranked = byContent.map { (itemID: $0.key, similarity: $0.value) }
            ranked.sort { a, b in
                if a.similarity != b.similarity {
                    switch direction {
                    case .nearest: return a.similarity > b.similarity
                    case .farthest: return a.similarity < b.similarity
                    }
                }
                return a.itemID < b.itemID
            }
            let hits = Array(ranked.prefix(limit))
            Intellectus.report(.metric(
                name: "corpus.float_lane.hit", value: Double(hits.count),
                tags: ["kit": "CorpusKit"], ts: Date().timeIntervalSince1970))
            results.append((provider.modelID, .hits(hits)))
        }
        return results
    }
}
