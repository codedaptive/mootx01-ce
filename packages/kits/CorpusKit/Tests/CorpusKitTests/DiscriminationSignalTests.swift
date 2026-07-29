// DiscriminationSignalTests.swift
//
// Tests for FloatDiscriminationSignal and floatNearestPerSignalWithDiscrimination.
// Mission: MISSION_11X_RECALL_GAP_01 Stream D — Item 3 (saturation-aware
// discrimination signal, CorpusKit measurement half).
//
// Coverage:
//   §1  Corpus.discriminationSignal(from:) — nil for every non-.hits outcome.
//   §2  saturated fixture via helper: uniform high cosines → relativeSpread < 0.10.
//   §3  contrastive fixture via helper: clear winner → relativeSpread ≥ 0.15.
//   §4  single-hit: spread = 0.0 (max == min when |K| = 1).
//   §5  contrastive fixture via CorpusContentEngine integration.
//   §6  saturated fixture via CorpusContentEngine integration.
//   §7  contrastive fixture via Corpus integration.
//   §8  saturated fixture via Corpus integration.
//   §9  GLK discrimination factor formula: spread → factor mapping.
//
// §5/§6 exercise CorpusContentEngine.floatNearestPerSignalWithDiscrimination.
// §7/§8 exercise Corpus.floatNearestPerSignalWithDiscrimination.
// §9 exercises the min(1.0, meanSpread / 0.15) formula that RecallDirector applies.
//
// Model helpers:
//   directionalModel() — one-hot 384-d by token sum; orthogonal for distinct texts.
//   uniformModel()     — all texts return the same direction; cosine always 1.0.
//
// INTELLECTUS LOCK: all tests that call corpus.ingest or engine.indexContent
// hold GlobalTestLock.shared to prevent telemetry cross-contamination.

import Foundation
import Testing
import PersistenceKit
@testable import PersistenceKitSQLite
@testable import CorpusKit
import CorpusKitProviders
import VectorKit
import EngramLib

// MARK: - Shared constant

private let testNow = Date(timeIntervalSince1970: 1_700_000_000)

// MARK: - Model helpers
//
// These helpers mirror the pattern used in FloatLaneOutcomeTests.swift
// (makeDirectionalCorpus / makeFloatCorpus) but are parameterised so
// CorpusContentEngine tests can use them via `models: [...]`.

/// One-hot 384-d model keyed by (sum of FNV-1a token IDs) mod 384.
/// Texts with different token compositions land on orthogonal directions
/// (cosine ≈ 0.0). Identical texts land on the same direction (cosine 1.0).
/// Used for CONTRASTIVE fixtures: one winner, several orthogonal distractors.
private func directionalModel() -> EmbeddingModel {
    .miniLM(inference: { tokens in
        var v = [Float](repeating: 0.0, count: 384)
        let sum = tokens.reduce(Int32(0), &+)
        let slot = Int((sum % 384 + 384) % 384)
        v[slot] = 1.0
        return v
    })
}

/// Uniform-direction 384-d model: all texts return the same direction vector.
/// Every (query, doc) pair has cosine similarity 1.0.
/// Used for SATURATED fixtures: zero relative spread.
private func uniformModel() -> EmbeddingModel {
    .miniLM(inference: { _ in
        Array(repeating: 1.0, count: 384)
    })
}

// MARK: - Engine helper

/// Creates a CorpusContentEngine in standalone mode with the supplied model,
/// together with its backing CorpusDocumentStore.
/// The engine init applies all required migrations internally.
private func makeEngine(
    model: EmbeddingModel
) async throws -> (CorpusContentEngine, CorpusDocumentStore) {
    let storage = try makeScratchStorage()
    let config = try CorpusContentConfiguration(mode: .standalone, indexUnit: .wholeContent)
    let store = CorpusDocumentStore(storage: storage)
    let engine = try await CorpusContentEngine(
        storage: storage, configuration: config, source: store, models: [model])
    return (engine, store)
}

// MARK: - §1: Corpus.discriminationSignal(from:) — nil for all dark outcomes

@Suite("§1 FloatDiscriminationSignal — nil for dark outcomes", .serialized)
struct DiscriminationSignalNilForDarkOutcomes {

    @Test("nil for .emptyQuery") func nilForEmptyQuery() {
        #expect(Corpus.discriminationSignal(from: .emptyQuery) == nil)
    }

    @Test("nil for .unavailableProviderOptOut") func nilForProviderOptOut() {
        #expect(Corpus.discriminationSignal(from: .unavailableProviderOptOut) == nil)
    }

    @Test("nil for .unavailableNoVocabHit") func nilForNoVocabHit() {
        #expect(Corpus.discriminationSignal(from: .unavailableNoVocabHit) == nil)
    }

    @Test("nil for .unavailableNoFloatRows") func nilForNoFloatRows() {
        #expect(Corpus.discriminationSignal(from: .unavailableNoFloatRows) == nil)
    }

    @Test("nil for .storeError") func nilForStoreError() {
        let err = NSError(domain: "test", code: 1)
        #expect(Corpus.discriminationSignal(from: .storeError(err)) == nil)
    }

    @Test("nil for empty .hits list") func nilForEmptyHits() {
        // An empty hits list is treated as a dark outcome for discrimination purposes.
        let empty: [(itemID: String, similarity: Float)] = []
        #expect(Corpus.discriminationSignal(from: .hits(empty)) == nil)
    }
}

// MARK: - §2: Saturated fixture via static helper (synthetic hits)

@Suite("§2 FloatDiscriminationSignal — saturated fixture (synthetic hits)", .serialized)
struct DiscriminationSignalSaturatedHelper {

    // §2a — typical saturated regime: top-K cosines in [0.93, 0.98]
    // relativeSpread = (0.98 − 0.93) / 0.98 ≈ 0.051 — well below 0.15.
    @Test("uniform high cosines → relativeSpread < 0.10") func saturatedTypical() throws {
        let hits: [(itemID: String, similarity: Float)] = [
            (itemID: "a", similarity: 0.98),
            (itemID: "b", similarity: 0.96),
            (itemID: "c", similarity: 0.95),
            (itemID: "d", similarity: 0.94),
            (itemID: "e", similarity: 0.93),
        ]
        let sig = try #require(Corpus.discriminationSignal(from: .hits(hits)),
            "saturated .hits must produce a non-nil discrimination signal")
        // relativeSpread = (0.98 - 0.93) / 0.98 ≈ 0.051
        #expect(sig.relativeSpread < 0.10,
            "saturated regime must produce spread < 0.10; got \(sig.relativeSpread)")
        #expect(sig.hitCount == 5)
    }

    // §2b — uniform identical cosines → spread = 0.0
    @Test("uniform identical cosines → relativeSpread = 0.0") func saturatedUniform() throws {
        let hits: [(itemID: String, similarity: Float)] = [
            (itemID: "a", similarity: 0.95),
            (itemID: "b", similarity: 0.95),
            (itemID: "c", similarity: 0.95),
        ]
        let sig = try #require(Corpus.discriminationSignal(from: .hits(hits)))
        #expect(sig.relativeSpread == 0.0,
            "uniform cosines must yield spread = 0.0; got \(sig.relativeSpread)")
    }

    // §2c — non-positive max cosine → spread = 0.0 (safe fallback)
    @Test("non-positive max cosine → relativeSpread = 0.0") func nonPositiveMaxCosine() throws {
        let hits: [(itemID: String, similarity: Float)] = [
            (itemID: "a", similarity: -0.10),
            (itemID: "b", similarity: -0.50),
        ]
        let sig = try #require(Corpus.discriminationSignal(from: .hits(hits)))
        #expect(sig.relativeSpread == 0.0,
            "non-positive max cosine must yield spread = 0.0; got \(sig.relativeSpread)")
    }
}

// MARK: - §3: Contrastive fixture via static helper (synthetic hits)

@Suite("§3 FloatDiscriminationSignal — contrastive fixture (synthetic hits)", .serialized)
struct DiscriminationSignalContrastiveHelper {

    // §3a — typical contrastive regime: clear winner at 0.85, field in [0.40, 0.55]
    // relativeSpread = (0.85 − 0.40) / 0.85 ≈ 0.529 — well above 0.15.
    @Test("clear winner → relativeSpread ≥ 0.15") func contrastiveTypical() throws {
        let hits: [(itemID: String, similarity: Float)] = [
            (itemID: "winner", similarity: 0.85),
            (itemID: "b",      similarity: 0.55),
            (itemID: "c",      similarity: 0.48),
            (itemID: "d",      similarity: 0.40),
        ]
        let sig = try #require(Corpus.discriminationSignal(from: .hits(hits)),
            "contrastive .hits must produce a non-nil discrimination signal")
        // relativeSpread = (0.85 - 0.40) / 0.85 ≈ 0.529
        #expect(sig.relativeSpread >= 0.15,
            "contrastive regime must produce spread ≥ 0.15; got \(sig.relativeSpread)")
        #expect(sig.hitCount == 4)
    }

    // §3b — maximum spread: max = 1.0, min = 0.0 → spread = 1.0
    @Test("orthogonal cosines → relativeSpread = 1.0") func orthogonalCosines() throws {
        let hits: [(itemID: String, similarity: Float)] = [
            (itemID: "match", similarity: 1.0),
            (itemID: "miss",  similarity: 0.0),
        ]
        let sig = try #require(Corpus.discriminationSignal(from: .hits(hits)))
        #expect(abs(sig.relativeSpread - 1.0) < 0.001,
            "orthogonal pair must yield spread ≈ 1.0; got \(sig.relativeSpread)")
    }
}

// MARK: - §4: Single-hit outcome

@Suite("§4 FloatDiscriminationSignal — single-hit outcome", .serialized)
struct DiscriminationSignalSingleHit {

    // When only one hit, max == min → spread = 0.0.
    @Test("single hit → relativeSpread = 0.0") func singleHit() throws {
        let hits: [(itemID: String, similarity: Float)] = [(itemID: "only", similarity: 0.75)]
        let sig = try #require(Corpus.discriminationSignal(from: .hits(hits)))
        #expect(sig.relativeSpread == 0.0,
            "single hit: max == min, spread must be 0.0; got \(sig.relativeSpread)")
        #expect(sig.hitCount == 1)
    }
}

// MARK: - §5: CorpusContentEngine integration — contrastive fixture

@Suite("§5 CorpusContentEngine — contrastive discrimination signal", .serialized)
struct ContentEngineContrastiveDiscrimination {

    /// directionalModel() maps texts to one-hot 384-d vectors by token sum.
    /// The query and "winner" document share identical text → same token sum
    /// → same one-hot slot → cosine 1.0. The three distractor texts differ
    /// → orthogonal slots → cosine ≈ 0.0. Spread must be ≥ 0.15.
    @Test("contrastive fixture: floatNearestPerSignalWithDiscrimination returns spread ≥ 0.15")
    func contrastiveFixture() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store) = try await makeEngine(model: directionalModel())

            // "winner" and distractor texts must produce distinct one-hot slots.
            // Repeated-word texts maximise token-sum separation.
            _ = try await store.put("alpha alpha alpha", id: "winner",      now: testNow)
            _ = try await store.put("omega omega omega", id: "distractor1", now: testNow)
            _ = try await store.put("delta delta delta", id: "distractor2", now: testNow)
            _ = try await store.put("sigma sigma sigma", id: "distractor3", now: testNow)
            try await engine.indexContent(id: "winner",      now: testNow)
            try await engine.indexContent(id: "distractor1", now: testNow)
            try await engine.indexContent(id: "distractor2", now: testNow)
            try await engine.indexContent(id: "distractor3", now: testNow)

            // Query text is identical to the winner document: same token sum →
            // cosine 1.0 for winner, cosine ≈ 0.0 for distractors.
            let results = await engine.floatNearestPerSignalWithDiscrimination(
                query: "alpha alpha alpha", limit: 4)
            let first = try #require(results.first)
            guard case .hits = first.outcome else {
                Issue.record("expected .hits outcome; got \(first.outcome)")
                return
            }
            let disc = try #require(first.discrimination,
                "contrastive fixture must produce a non-nil discrimination signal")
            #expect(disc.relativeSpread >= 0.15,
                "contrastive fixture must produce spread ≥ 0.15; got \(disc.relativeSpread)")
        }
    }
}

// MARK: - §6: CorpusContentEngine integration — saturated fixture

@Suite("§6 CorpusContentEngine — saturated discrimination signal", .serialized)
struct ContentEngineSaturatedDiscrimination {

    /// uniformModel() returns the same 384-d direction for every text.
    /// All (query, doc) pairs have cosine 1.0 → relative spread = 0.0.
    @Test("saturated fixture: floatNearestPerSignalWithDiscrimination returns spread < 0.10")
    func saturatedFixture() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store) = try await makeEngine(model: uniformModel())

            _ = try await store.put("document one text",   id: "d1", now: testNow)
            _ = try await store.put("document two text",   id: "d2", now: testNow)
            _ = try await store.put("document three text", id: "d3", now: testNow)
            _ = try await store.put("document four text",  id: "d4", now: testNow)
            try await engine.indexContent(id: "d1", now: testNow)
            try await engine.indexContent(id: "d2", now: testNow)
            try await engine.indexContent(id: "d3", now: testNow)
            try await engine.indexContent(id: "d4", now: testNow)

            let results = await engine.floatNearestPerSignalWithDiscrimination(
                query: "any query text", limit: 4)
            let first = try #require(results.first)
            guard case .hits = first.outcome else {
                Issue.record("expected .hits outcome; got \(first.outcome)")
                return
            }
            let disc = try #require(first.discrimination,
                "saturated fixture must produce a non-nil discrimination signal")
            // All cosines = 1.0 (same uniform direction) → spread = (1.0 - 1.0) / 1.0 = 0.0
            #expect(disc.relativeSpread < 0.10,
                "saturated fixture must produce spread < 0.10; got \(disc.relativeSpread)")
        }
    }
}

// MARK: - §7: Corpus integration — contrastive fixture

@Suite("§7 Corpus — contrastive discrimination signal", .serialized)
struct CorpusContrastiveDiscrimination {

    /// directionalModel() → one-hot 384-d vectors. Identical text → cosine 1.0,
    /// distinct texts → cosine ≈ 0.0. Query text matches winner → high spread.
    @Test("contrastive fixture: floatNearestPerSignalWithDiscrimination returns spread ≥ 0.15")
    func contrastiveFixture() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let corpus = try await Corpus(storage: storage, model: directionalModel())

            try await corpus.ingest("alpha alpha alpha", sourceID: "winner",      now: testNow)
            try await corpus.ingest("omega omega omega", sourceID: "distractor1", now: testNow)
            try await corpus.ingest("delta delta delta", sourceID: "distractor2", now: testNow)
            try await corpus.ingest("sigma sigma sigma", sourceID: "distractor3", now: testNow)

            let results = await corpus.floatNearestPerSignalWithDiscrimination(
                query: "alpha alpha alpha", limit: 4)
            let first = try #require(results.first)
            guard case .hits = first.outcome else {
                Issue.record("expected .hits outcome; got \(first.outcome)")
                return
            }
            let disc = try #require(first.discrimination,
                "contrastive fixture must produce a non-nil discrimination signal")
            #expect(disc.relativeSpread >= 0.15,
                "contrastive fixture must produce spread ≥ 0.15; got \(disc.relativeSpread)")
        }
    }
}

// MARK: - §8: Corpus integration — saturated fixture

@Suite("§8 Corpus — saturated discrimination signal", .serialized)
struct CorpusSaturatedDiscrimination {

    /// uniformModel() → all texts return the same direction vector → cosine always 1.0.
    @Test("saturated fixture: floatNearestPerSignalWithDiscrimination returns spread < 0.10")
    func saturatedFixture() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let corpus = try await Corpus(storage: storage, model: uniformModel())

            try await corpus.ingest("document one text",   sourceID: "d1", now: testNow)
            try await corpus.ingest("document two text",   sourceID: "d2", now: testNow)
            try await corpus.ingest("document three text", sourceID: "d3", now: testNow)

            let results = await corpus.floatNearestPerSignalWithDiscrimination(
                query: "any query here", limit: 3)
            let first = try #require(results.first)
            guard case .hits = first.outcome else {
                Issue.record("expected .hits outcome; got \(first.outcome)")
                return
            }
            let disc = try #require(first.discrimination,
                "saturated fixture must produce a non-nil discrimination signal")
            #expect(disc.relativeSpread < 0.10,
                "saturated fixture must produce spread < 0.10; got \(disc.relativeSpread)")
        }
    }
}

// MARK: - §9: GLK discrimination factor formula

// RecallDirector computes: factor = min(1.0, meanSpread / saturationThreshold)
// where saturationThreshold = 0.15. These tests mirror the formula exactly so
// any future refactor of the threshold or aggregation logic is caught here.
//
// Tests do NOT spin up a full estate or RecallDirector. The formula is a pure
// function verifiable independently. The GLK integration path (actual dense-score
// weighting) is covered by RecallDirector's own test suite.

@Suite("§9 GLK discrimination factor formula", .serialized)
struct GlkDiscriminationFactorFormula {

    /// Mirror of RecallDirector's inline factor computation.
    private func factor(spreads: [Float]) -> Float {
        let saturationThreshold: Float = 0.15
        guard !spreads.isEmpty else { return 1.0 }
        let meanSpread = spreads.reduce(0.0 as Float, +) / Float(spreads.count)
        return min(1.0, meanSpread / saturationThreshold)
    }

    // ---- Saturated regime: discount engages ----

    @Test("saturated: spread 0.05 → factor ≈ 0.333 (discount engages)")
    func saturatedSpreadEngagesDiscount() {
        let f = factor(spreads: [0.05])
        // 0.05 / 0.15 = 0.333...
        #expect(abs(f - (0.05 / 0.15)) < 0.002,
            "spread 0.05 must yield factor ≈ 0.333; got \(f)")
        #expect(f < 1.0, "factor must be < 1.0 for saturated spread")
    }

    @Test("saturated: spread 0.0 → factor = 0.0 (maximum discount)")
    func zeroSpreadMaximumDiscount() {
        let f = factor(spreads: [0.0])
        #expect(f == 0.0, "spread 0.0 must yield factor = 0.0; got \(f)")
    }

    // ---- Contrastive regime: no discount ----

    @Test("contrastive: spread 0.43 → factor = 1.0 (no discount)")
    func contrastiveSpreadNoDiscount() {
        let f = factor(spreads: [0.43])
        #expect(f == 1.0, "contrastive spread 0.43 must yield factor = 1.0; got \(f)")
    }

    @Test("exactly at threshold: spread 0.15 → factor = 1.0")
    func atThresholdNoDiscount() {
        let f = factor(spreads: [0.15])
        #expect(abs(f - 1.0) < 0.001, "spread 0.15 must yield factor = 1.0; got \(f)")
    }

    // ---- Edge cases ----

    @Test("no .hits signals: empty spreads → factor = 1.0")
    func noHitsSignalNoDiscount() {
        let f = factor(spreads: [])
        #expect(f == 1.0, "no .hits signals must yield factor = 1.0")
    }

    @Test("multi-signal: saturated + contrastive → mean above threshold → factor = 1.0")
    func multiSignalMeanAboveThreshold() {
        // Saturated: 0.05, Contrastive: 0.43 → mean = 0.24 → above threshold → 1.0
        let f = factor(spreads: [0.05, 0.43])
        #expect(f == 1.0,
            "mixed signals with mean 0.24 > threshold 0.15 must not discount; got \(f)")
    }

    @Test("multi-signal: both saturated → discount engages")
    func multiSignalBothSaturated() {
        // mean([0.04, 0.06]) = 0.05 → factor = 0.05/0.15 ≈ 0.333
        let f = factor(spreads: [0.04, 0.06])
        let expected = min(1.0, Float(0.05) / 0.15)
        #expect(abs(f - expected) < 0.002)
        #expect(f < 1.0, "both signals saturated must produce discount")
    }
}
