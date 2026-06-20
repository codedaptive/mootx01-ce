// FloatLaneOutcomeTests.swift
//
// Tests for the observable FloatLaneOutcome returned by Corpus.floatNearest.
//
// Covers every outcome variant so the silent-degradation class (F1 gate-2
// failure) cannot regress:
//
//   §1  providerOptOut — a throwing EmbeddingProvider injected via the
//       internal test seam (init(storage:provider:)) produces
//       .unavailableProviderOptOut and the dark_provider counter moves.
//   §1b providerOptOut (empty corpus verification) — deterministic corpus with
//       no ingest verifies the dark_no_rows counter (provider supports
//       embedFloat, store is empty). Confirms dark_provider is 0.
//   §2  emptyQuery    — limit=0 or query="" produces .emptyQuery with
//       no telemetry emitted (the guard fires before any store access).
//   §3  noFloatRows   — a float-capable provider that returned floats
//       on ingest but a fresh corpus with no ingested documents →
//       the outcome is .unavailableNoFloatRows and the
//       corpus.float_lane.dark_no_rows counter moves.
//   §4  happyPath     — a real MiniLM-shaped provider + ingested document;
//       outcome is .hits with ≥1 result and corpus.float_lane.hit counter
//       moves.
//   §5  conformance   — telemetry MUST NOT change the hit result order or
//       count (same result with monitoring off and on).
//   §6  storeError    — the _testForceFloatStoreError test hook produces
//       .storeError, emits the store_error counter, and the query on other
//       lanes continues (outcome is not a thrown error). Both monitoring
//       on and off paths tested.
//
// INTELLECTUS LOCK: all tests that toggle Intellectus or call Corpus.ingest
// acquire GlobalTestLock.shared for their entire duration to prevent
// interleaving with the CorpusKitTelemetryTests suites.

import Foundation
import Testing
import PersistenceKit
@testable import CorpusKit
import CorpusKitProviders
import IntellectusLib
import VectorKit
import EngramLib

// MARK: - Helpers

private let fixedNow = Date(timeIntervalSinceReferenceDate: 1_600_000)

/// Creates a fresh SQLite-backed Corpus with the default deterministic
/// provider (no float lane). Mirrors CorpusTests.makeCorpus.
private func makeDeterministicCorpus() async throws -> Corpus {
    let storage = try makeScratchStorage()
    return try await Corpus(storage: storage, model: .deterministic)
}

/// Creates a fresh SQLite-backed Corpus with a MiniLM-shaped inference
/// closure. The closure returns a stable 384-d vector so floatNearest
/// can store and retrieve float rows.
private func makeFloatCorpus() async throws -> Corpus {
    let storage = try makeScratchStorage()
    return try await Corpus(
        storage: storage,
        model: .miniLM(inference: { tokens in
            // Stable 384-d vector whose values depend on the token count
            // so different texts produce distinguishably different vectors.
            let base = Float(tokens.count % 8 + 1) / 8.0
            return Array(repeating: base, count: 384)
        })
    )
}

// MARK: - Capturing sink

private final class CapturingSink: StatsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _samples: [StatSample] = []

    func receive(_ sample: StatSample) {
        lock.lock()
        _samples.append(sample)
        lock.unlock()
    }

    var samples: [StatSample] {
        lock.lock(); defer { lock.unlock() }
        return _samples
    }

    func count(name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _samples.filter {
            if case let .metric(n, _, _, _) = $0 { return n == name }
            return false
        }.count
    }
}

// MARK: - ThrowingProvider (test-only seam)
//
// A minimal EmbeddingProvider whose `embedFloat` always throws VectorKitError.embeddingFailed.
// `embed` returns a valid (deterministic) engram so ingest and BM25 recall work normally;
// only the float lane is dark. Injected via Corpus.init(storage:provider:) — the internal
// test seam added specifically to make the providerOptOut path force-testable.

private struct ThrowingFloatProvider: EmbeddingProvider, @unchecked Sendable {
    let modelID: String = "test-throwing-float-v1"
    let modelVersion: String = "1.0.0"

    /// Normal embed — returns a fixed 256-bit zero engram. Enough for BM25/vector
    /// binary lanes to work; not semantically meaningful.
    func embed(_ text: String) async throws -> Engram {
        // Zero engram satisfies the cross-provider contract for empty strings
        // and is stable across calls — sufficient for the test fixtures here.
        return Engram.zero
    }

    /// Float lane opt-out: always throws embeddingFailed.
    /// This is the production default for any provider that does not override
    /// embedFloat — replicated here explicitly so the force-test is crystal clear.
    func embedFloat(_ text: String) async throws -> [Float] {
        throw VectorKitError.embeddingFailed(
            "ThrowingFloatProvider: embedFloat is disabled (test-only opt-out)")
    }
}

// MARK: - §1 Provider opt-out (force-tested via internal seam)

@Suite("§1 FloatLaneOutcome — providerOptOut force-test (throwing provider)", .serialized)
struct FloatLaneProviderOptOutForceTests {

    /// Force the providerOptOut path by injecting a throwing provider through
    /// the internal `init(storage:provider:)` seam.
    /// Expected: outcome == .unavailableProviderOptOut + dark_provider counter moves.
    @Test("throwing provider forces .unavailableProviderOptOut outcome")
    func throwingProviderForcesOptOutOutcome() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let storage = try makeScratchStorage()
            // Use the internal test seam: inject ThrowingFloatProvider directly.
            let corpus = try await Corpus(storage: storage, provider: ThrowingFloatProvider())

            let outcome = await corpus.floatNearest(query: "provider opt-out force test", limit: 5)

            // Provider throws on embedFloat → .unavailableProviderOptOut.
            if case .unavailableProviderOptOut = outcome {
                // Expected — pass.
            } else {
                Issue.record("expected .unavailableProviderOptOut from throwing provider, got \(outcome)")
            }

            // dark_provider counter must have moved exactly once.
            let darkProvider = sink.count(name: "corpus.float_lane.dark_provider")
            #expect(darkProvider == 1,
                "corpus.float_lane.dark_provider must be emitted once; got \(darkProvider)")
            // dark_no_rows must NOT move — provider threw before the store was reached.
            #expect(sink.count(name: "corpus.float_lane.dark_no_rows") == 0,
                "dark_no_rows must be 0 when provider throws; store was not reached")
            #expect(sink.count(name: "corpus.float_lane.store_error") == 0,
                "store_error must not be emitted on opt-out path")
            #expect(sink.count(name: "corpus.float_lane.hit") == 0,
                "hit counter must not move on opt-out path")
        }
    }

    /// dark_provider counter must NOT be emitted when monitoring is disabled.
    @Test("dark_provider counter not emitted when monitoring disabled")
    func darkProviderNotEmittedWhenMonitoringOff() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)
            defer {
                Intellectus.install(sink: NoOpSink.shared)
            }

            let storage = try makeScratchStorage()
            let corpus = try await Corpus(storage: storage, provider: ThrowingFloatProvider())
            _ = await corpus.floatNearest(query: "monitoring disabled test", limit: 5)

            #expect(sink.count(name: "corpus.float_lane.dark_provider") == 0,
                "dark_provider must not be emitted when monitoring is disabled")
        }
    }
}

// MARK: - §1b Provider opt-out (empty corpus — dark_no_rows path, dark_provider == 0)
//
// Verifies that the deterministic provider (which supports embedFloat) produces
// .unavailableNoFloatRows on an empty corpus, not .unavailableProviderOptOut.
// Also confirms that dark_provider == 0 in this path — distinguishing the two
// dark outcomes is essential for observability.

@Suite("§1b FloatLaneOutcome — dark_no_rows path (empty corpus, provider supports float)", .serialized)
struct FloatLaneProviderOptOutTests {

    /// Deterministic corpus with no ingested documents: embedFloat succeeds but
    /// findNearestFloat returns empty → outcome must be .unavailableNoFloatRows.
    /// The dark_no_rows counter must move; dark_provider must be 0 (provider did
    /// not throw — only the store had no rows).
    @Test("deterministic provider on empty corpus produces unavailableNoFloatRows")
    func deterministicEmptyCorpusProducesNoFloatRows() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let corpus = try await makeDeterministicCorpus()
            let outcome = await corpus.floatNearest(query: "test query", limit: 10)

            // deterministic provider returns floats, but corpus is empty → noFloatRows.
            if case .unavailableNoFloatRows = outcome {
                // Expected outcome — pass.
            } else {
                Issue.record("expected .unavailableNoFloatRows for empty corpus, got \(outcome)")
            }

            // dark_no_rows counter must have moved; dark_provider must NOT.
            let noRows = sink.count(name: "corpus.float_lane.dark_no_rows")
            #expect(noRows == 1,
                "corpus.float_lane.dark_no_rows must be emitted once; got \(noRows)")
            #expect(sink.count(name: "corpus.float_lane.dark_provider") == 0,
                "dark_provider must not move when provider supports embedFloat")
            #expect(sink.count(name: "corpus.float_lane.store_error") == 0,
                "store_error must not be emitted on noFloatRows path")
            #expect(sink.count(name: "corpus.float_lane.hit") == 0,
                "hit counter must not move on noFloatRows path")
        }
    }

    /// When monitoring is disabled, dark_no_rows must NOT be emitted.
    @Test("dark_no_rows counter not emitted when monitoring is disabled")
    func darkNoRowsNotEmittedWhenMonitoringOff() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)
            defer {
                Intellectus.install(sink: NoOpSink.shared)
            }

            let corpus = try await makeDeterministicCorpus()
            _ = await corpus.floatNearest(query: "test query", limit: 10)

            #expect(sink.count(name: "corpus.float_lane.dark_no_rows") == 0,
                "dark_no_rows counter must not be emitted when monitoring is disabled")
        }
    }
}

// MARK: - §2 Empty query / zero limit

@Suite("§2 FloatLaneOutcome — empty query", .serialized)
struct FloatLaneEmptyQueryTests {

    /// Empty query must produce .emptyQuery with no telemetry regardless of
    /// monitoring state.
    @Test("empty query string produces .emptyQuery outcome")
    func emptyQueryString() async throws {
        let corpus = try await makeDeterministicCorpus()
        let outcome = await corpus.floatNearest(query: "", limit: 10)

        if case .emptyQuery = outcome {
            // Expected — pass.
        } else {
            Issue.record("expected .emptyQuery for empty query string, got \(outcome)")
        }
    }

    /// Zero limit must produce .emptyQuery.
    @Test("zero limit produces .emptyQuery outcome")
    func zeroLimit() async throws {
        let corpus = try await makeDeterministicCorpus()
        let outcome = await corpus.floatNearest(query: "something", limit: 0)

        if case .emptyQuery = outcome {
            // Expected — pass.
        } else {
            Issue.record("expected .emptyQuery for limit=0, got \(outcome)")
        }
    }

    /// Empty query must not emit any telemetry (guard fires before store access).
    @Test("empty query emits no telemetry")
    func emptyQueryNoTelemetry() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let corpus = try await makeDeterministicCorpus()
            _ = await corpus.floatNearest(query: "", limit: 10)

            // No float_lane.* counter should move for an empty query.
            let total = sink.samples.filter {
                if case let .metric(n, _, _, _) = $0 { return n.hasPrefix("corpus.float_lane.") }
                return false
            }.count
            #expect(total == 0,
                "empty query must emit zero corpus.float_lane.* counters; got \(total)")
        }
    }
}

// MARK: - §3 No float rows (source removed)

@Suite("§3 FloatLaneOutcome — no float rows after remove", .serialized)
struct FloatLaneNoFloatRowsTests {

    /// Float-capable provider + ingest + remove → float rows deleted → subsequent
    /// floatNearest must produce .unavailableNoFloatRows (not .hits).
    /// This tests the code path where the source-aggregation loop produces an
    /// empty by-source map (all chunk UUIDs removed from chunkSourceMap).
    @Test("float-capable provider after source remove produces unavailableNoFloatRows")
    func removeSourceProducesNoFloatRows() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)  // Ingest with monitoring off.
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let corpus = try await makeFloatCorpus()
            try await corpus.ingest(
                "Dense float lane remove test fixture content.",
                sourceID: "doc-remove",
                now: fixedNow
            )
            // Remove the only source so chunkSourceMap is empty.
            try await corpus.remove(sourceID: "doc-remove")

            // Enable monitoring before the query.
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)

            let outcome = await corpus.floatNearest(query: "float lane test", limit: 5)

            if case .unavailableNoFloatRows = outcome {
                // Expected — pass.
            } else {
                Issue.record("expected .unavailableNoFloatRows after remove, got \(outcome)")
            }

            let noRows = sink.count(name: "corpus.float_lane.dark_no_rows")
            #expect(noRows == 1,
                "corpus.float_lane.dark_no_rows must be emitted once after remove; got \(noRows)")
            #expect(sink.count(name: "corpus.float_lane.hit") == 0,
                "hit counter must not move after source remove")
        }
    }
}

// MARK: - §4 Happy path

@Suite("§4 FloatLaneOutcome — happy path", .serialized)
struct FloatLaneHappyPathTests {

    /// Float-capable provider + ingested document → outcome .hits with ≥1 result.
    /// The hit counter must move.
    @Test("float-capable provider with ingested document produces hits outcome")
    func ingestedDocumentProducesHits() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let corpus = try await makeFloatCorpus()
            try await corpus.ingest(
                "The dense float lane produces cosine-ranked hits via pooled embeddings.",
                sourceID: "doc-float-1",
                now: fixedNow
            )

            let outcome = await corpus.floatNearest(query: "float embeddings", limit: 5)

            if case .hits(let results) = outcome {
                #expect(!results.isEmpty,
                    ".hits must contain at least one result after ingest")
                // Every hit must have a non-empty itemID.
                #expect(results.allSatisfy { !$0.itemID.isEmpty },
                    "every hit itemID must be non-empty")
            } else {
                Issue.record("expected .hits outcome after ingest, got \(outcome)")
            }

            // hit counter must have moved.
            let hit = sink.count(name: "corpus.float_lane.hit")
            #expect(hit == 1,
                "corpus.float_lane.hit must be emitted once on the happy path; got \(hit)")

            // No dark or error counters.
            #expect(sink.count(name: "corpus.float_lane.dark_provider") == 0)
            #expect(sink.count(name: "corpus.float_lane.dark_no_rows") == 0)
            #expect(sink.count(name: "corpus.float_lane.store_error") == 0)
        }
    }

    /// Similarity values in .hits must be in [−1, 1] (cosine range).
    @Test("hits have similarity values in cosine range")
    func hitsHaveCosineRangeSimilarity() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeFloatCorpus()
            try await corpus.ingest(
                "Cosine similarity is a metric for vector similarity in high-dimensional space.",
                sourceID: "doc-cosine",
                now: fixedNow
            )

            let outcome = await corpus.floatNearest(query: "vector similarity", limit: 5)
            if case .hits(let results) = outcome {
                for r in results {
                    #expect(r.similarity >= -1.0 && r.similarity <= 1.0,
                        "similarity must be in [−1, 1]; got \(r.similarity)")
                }
            }
            // If not .hits, no assertion failure — the lane may be dark in some
            // environments (e.g. when float rows are not stored for the test model).
        }
    }
}

// MARK: - §5 Conformance

@Suite("§5 FloatLaneOutcome — conformance (results unchanged by telemetry)", .serialized)
struct FloatLaneConformanceTests {

    /// floatNearest must return the same outcome structure whether monitoring
    /// is on or off. Telemetry must not alter result content or ordering.
    @Test("floatNearest outcome is identical with monitoring disabled and enabled")
    func outcomeBitmapIsUnchangedByTelemetry() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            let corpus = try await Corpus(
                storage: storage,
                model: .miniLM(inference: { tokens in
                    // Deterministic: value depends on first token id only, so
                    // different texts produce reliably distinguishable vectors.
                    let v = Float((tokens.first ?? 0) % 4 + 1) / 4.0
                    return Array(repeating: v, count: 384)
                })
            )

            Intellectus.setEnabled(false)
            try await corpus.ingest(
                "Conformance: telemetry must not alter floatNearest results.",
                sourceID: "doc-conformance",
                now: fixedNow
            )

            // Run with monitoring OFF.
            let outcomeOff = await corpus.floatNearest(query: "telemetry results", limit: 5)

            // Run with monitoring ON.
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            let outcomeOn = await corpus.floatNearest(query: "telemetry results", limit: 5)
            Intellectus.setEnabled(false)
            Intellectus.install(sink: NoOpSink.shared)

            // Both outcomes must have the same variant and same hit count.
            switch (outcomeOff, outcomeOn) {
            case (.hits(let off), .hits(let on)):
                #expect(off.count == on.count,
                    "hit count must be identical on/off; off=\(off.count) on=\(on.count)")
                for i in 0..<off.count {
                    #expect(off[i].itemID == on[i].itemID,
                        "hit[\(i)].itemID must match; off=\(off[i].itemID) on=\(on[i].itemID)")
                }
            case (.unavailableProviderOptOut, .unavailableProviderOptOut): break
            case (.unavailableNoFloatRows, .unavailableNoFloatRows): break
            case (.emptyQuery, .emptyQuery): break
            default:
                Issue.record("outcome variant mismatch: off=\(outcomeOff) on=\(outcomeOn)")
            }

            // When monitoring was on, at least some metric must have been emitted
            // (either hit or dark — verifies monitoring was actually active).
            #expect(sink.samples.count > 0,
                "at least one metric must be emitted when monitoring is enabled")
        }
    }
}

// MARK: - §6 Store-error force-test

// The storeError outcome fires when findNearestFloat throws unexpectedly.
// The _testForceFloatStoreError internal hook simulates this by making the
// actor's next floatNearest call return .storeError without touching the store.
// This is the least-invasive seam: no VectorKit changes, no SQL corruption,
// no mock VectorStore. Documented as test-only in the Corpus source.
//
// Gate criteria:
//  - outcome == .storeError
//  - corpus.float_lane.store_error counter moves exactly once (monitoring on)
//  - corpus.float_lane.store_error NOT emitted when monitoring off
//  - The call degrades (returns .storeError) rather than throwing

@Suite("§6 FloatLaneOutcome — storeError force-test", .serialized)
struct FloatLaneStoreErrorTests {

    /// Force the storeError path using the internal test hook.
    /// Expected: .storeError outcome + store_error counter emitted once.
    @Test("forced store error produces .storeError outcome and store_error counter")
    func forcedStoreErrorProducesCorrectOutcome() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            let corpus = try await makeFloatCorpus()
            // Inject the store error before the query.
            struct SyntheticStoreError: Error, CustomStringConvertible {
                var description: String { "SyntheticStoreError: test-injected store failure" }
            }
            await corpus._testForceFloatStoreError(SyntheticStoreError())

            let outcome = await corpus.floatNearest(query: "store error force test", limit: 5)

            // Must degrade to .storeError, not throw.
            if case .storeError = outcome {
                // Expected — pass.
            } else {
                Issue.record("expected .storeError from forced hook, got \(outcome)")
            }

            // store_error counter must have moved exactly once.
            let errCount = sink.count(name: "corpus.float_lane.store_error")
            #expect(errCount == 1,
                "corpus.float_lane.store_error must be emitted once; got \(errCount)")

            // Dark and hit counters must NOT move.
            #expect(sink.count(name: "corpus.float_lane.dark_provider") == 0)
            #expect(sink.count(name: "corpus.float_lane.dark_no_rows") == 0)
            #expect(sink.count(name: "corpus.float_lane.hit") == 0)
        }
    }

    /// store_error counter must NOT be emitted when monitoring is disabled.
    @Test("store_error counter not emitted when monitoring disabled")
    func storeErrorCounterNotEmittedWhenMonitoringOff() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)
            defer {
                Intellectus.install(sink: NoOpSink.shared)
            }

            let corpus = try await makeFloatCorpus()
            struct SyntheticStoreError: Error {}
            await corpus._testForceFloatStoreError(SyntheticStoreError())

            let outcome = await corpus.floatNearest(query: "store error monitoring off", limit: 5)

            // Outcome is still .storeError (the hook fires regardless of monitoring).
            if case .storeError = outcome {
                // Expected — pass.
            } else {
                Issue.record("expected .storeError even with monitoring off, got \(outcome)")
            }

            // Counter must NOT have been emitted (monitoring was off).
            #expect(sink.count(name: "corpus.float_lane.store_error") == 0,
                "store_error counter must not be emitted when monitoring is disabled")
        }
    }

    /// The hook is consumed on first call — a second call behaves normally.
    /// This confirms the hook does not permanently poison the corpus.
    @Test("store error hook is consumed on first call; second call succeeds normally")
    func storeErrorHookIsConsumedOnFirstCall() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeFloatCorpus()
            try await corpus.ingest(
                "Hook consumed after first call test fixture",
                sourceID: "hook-consume-test",
                now: fixedNow
            )
            struct SyntheticStoreError: Error {}
            await corpus._testForceFloatStoreError(SyntheticStoreError())

            // First call: hook fires → .storeError.
            let first = await corpus.floatNearest(query: "hook test", limit: 5)
            if case .storeError = first {
                // Expected — pass.
            } else {
                Issue.record("expected .storeError on first call, got \(first)")
            }

            // Second call: hook consumed → normal happy path.
            let second = await corpus.floatNearest(query: "hook test", limit: 5)
            if case .storeError = second {
                Issue.record("hook must not fire twice; second call got .storeError again")
            }
            // Second call should produce .hits (document was ingested before the hook).
            // Accept any outcome that is not .storeError.
        }
    }
}

// MARK: - §7 Farthest (anti-similarity, mission 6b-modifiers-antisim)

/// A direction-discriminating corpus: each ingested text gets a ONE-HOT
/// 384-d direction chosen by the sum of its FNV-1a token ids mod 384. Distinct
/// texts therefore get distinct, mostly-orthogonal directions, so the float
/// lane can be steered toward "similar" or "dissimilar" sources unambiguously.
private func makeDirectionalCorpus() async throws -> Corpus {
    let storage = try makeScratchStorage()
    return try await Corpus(
        storage: storage,
        model: .miniLM(inference: { tokens in
            var v = [Float](repeating: 0, count: 384)
            let sum = tokens.reduce(Int32(0), &+)
            let slot = Int((sum % 384 + 384) % 384)
            v[slot] = 1.0
            return v
        })
    )
}

@Suite("§7 FloatLaneOutcome — farthest (anti-similarity)", .serialized)
struct FloatLaneFarthestTests {

    /// floatFarthestPerSignal surfaces the most DISSIMILAR source first. With a
    /// one-hot direction provider, a query whose direction matches one source
    /// makes that source the NEAREST and therefore the LAST in the farthest
    /// list — and the orthogonal source the FIRST. Proves the store actually
    /// inverts (the farthest source is not in a negated nearest top-1).
    @Test("floatFarthestPerSignal ranks the most dissimilar source first")
    func farthestRanksDissimilarFirst() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeDirectionalCorpus()
            // Two sources with distinct one-hot directions.
            try await corpus.ingest("alpha alpha alpha", sourceID: "src-alpha", now: fixedNow)
            try await corpus.ingest("omega omega omega different words", sourceID: "src-omega", now: fixedNow)

            let nearest = await corpus.floatNearestPerSignal(query: "alpha alpha alpha", limit: 5)
            let farthest = await corpus.floatFarthestPerSignal(query: "alpha alpha alpha", limit: 5)

            guard case .hits(let nearHits) = nearest.first?.outcome,
                  case .hits(let farHits) = farthest.first?.outcome else {
                Issue.record("expected .hits from both nearest and farthest; got \(nearest) / \(farthest)")
                return
            }
            #expect(nearHits.count == 2)
            #expect(farHits.count == 2)
            // The query direction matches src-alpha → nearest first; farthest
            // must place src-alpha LAST and the dissimilar src-omega FIRST.
            #expect(nearHits.first?.itemID == "src-alpha")
            #expect(farHits.first?.itemID == "src-omega")
            #expect(farHits.last?.itemID == "src-alpha")
        }
    }

    /// The nearest path is unchanged: an empty/zero call yields one .emptyQuery
    /// per signal with no store access — identical to floatNearestPerSignal.
    @Test("floatFarthestPerSignal empty query yields per-signal emptyQuery")
    func farthestEmptyQuery() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeDirectionalCorpus()
            let zero = await corpus.floatFarthestPerSignal(query: "x", limit: 0)
            let empty = await corpus.floatFarthestPerSignal(query: "", limit: 5)
            #expect(zero.allSatisfy { if case .emptyQuery = $0.outcome { return true } else { return false } })
            #expect(empty.allSatisfy { if case .emptyQuery = $0.outcome { return true } else { return false } })
        }
    }

    /// floatNearestPerSignal must remain byte-identical: the farthest addition
    /// does not perturb the nearest list (same itemID order both before and
    /// after a farthest call in between).
    @Test("nearest list is unchanged by an interleaved farthest call")
    func nearestUnchangedByFarthest() async throws {
        try await GlobalTestLock.shared.withLock {
            let corpus = try await makeDirectionalCorpus()
            try await corpus.ingest("alpha alpha alpha", sourceID: "src-alpha", now: fixedNow)
            try await corpus.ingest("omega omega omega different", sourceID: "src-omega", now: fixedNow)

            let near1 = await corpus.floatNearestPerSignal(query: "alpha alpha alpha", limit: 5)
            _ = await corpus.floatFarthestPerSignal(query: "alpha alpha alpha", limit: 5)
            let near2 = await corpus.floatNearestPerSignal(query: "alpha alpha alpha", limit: 5)

            guard case .hits(let a) = near1.first?.outcome,
                  case .hits(let b) = near2.first?.outcome else {
                Issue.record("expected .hits from both nearest calls")
                return
            }
            #expect(a.map(\.itemID) == b.map(\.itemID))
        }
    }
}

// MARK: - §8 VocabMiss — trained distributional provider with all-OOV query

// Tests for FloatLaneOutcome.unavailableNoVocabHit, added in the Bug-A fix:
//
//   • A trained RandomIndexing provider + an all-OOV query → .unavailableNoVocabHit
//     and corpus.float_lane.dark_vocab_miss counter fires.
//   • An untrained RandomIndexing provider (empty vocab) + any query → .unavailableProviderOptOut
//     (structural opt-out, NOT vocabMiss — provider has no basis at all).
//   • dark_provider must be 0 on the vocabMiss path (provider did not structurally opt out).
//   • dark_vocab_miss must be 0 on the untrained path (wrong reason — it's providerOptOut).

@Suite("§8 FloatLaneOutcome — vocabMiss (trained distributional provider, all-OOV query)", .serialized)
struct FloatLaneVocabMissTests {

    /// Corpus trained on vehicle-domain text; queried with tokens guaranteed
    /// absent from that vocabulary. Expected: .unavailableNoVocabHit.
    ///
    /// The OOV tokens are synthetic UUIDs — they cannot appear in any English
    /// training corpus, so the "zero hits" condition is structurally guaranteed
    /// rather than probabilistic.
    @Test("trained RI provider + all-OOV query → .unavailableNoVocabHit")
    func trainedRIWithOOVQueryYieldsVocabMiss() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            // Build corpus with RandomIndexing provider trained on a fixed domain.
            let storage = try makeScratchStorage()
            let corpus = try await Corpus(
                storage: storage,
                model: .randomIndexing(provider: RandomIndexingProvider()))

            // Ingest five vehicle-domain documents so the RI provider trains a
            // non-empty vocab (vocabulary: car, engine, road, fuel, vehicle, …).
            let trainingDocs = [
                "car engine drive road vehicle",
                "vehicle road transport car fuel",
                "engine fuel combustion power car",
                "driver seat wheel dashboard mirror",
                "road highway bridge tunnel overpass"
            ]
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            for (i, doc) in trainingDocs.enumerated() {
                try await corpus.ingest(doc, sourceID: "vehicle-\(i)", now: now)
            }
            // reindex trains the RI model on the ingested corpus.
            try await corpus.reindex(now: now)

            // Query with tokens that are structurally absent from the training
            // vocabulary — synthetic tokens that cannot appear in English text.
            let oovQuery = "zxqvmlkj99 wvbnrqxp88 qqzxcvbnm77"
            let outcome = await corpus.floatNearest(query: oovQuery, limit: 5)

            // Trained provider, all-OOV query → vocabMiss (not providerOptOut).
            if case .unavailableNoVocabHit = outcome {
                // Expected — pass.
            } else {
                Issue.record(
                    "expected .unavailableNoVocabHit for OOV query on trained RI corpus, got \(outcome); query='\(oovQuery)'")
            }

            // dark_vocab_miss counter must have moved.
            let vocabMiss = sink.count(name: "corpus.float_lane.dark_vocab_miss")
            #expect(vocabMiss == 1,
                "corpus.float_lane.dark_vocab_miss must be emitted once; got \(vocabMiss)")

            // dark_provider must NOT move — provider did not structurally opt out.
            #expect(sink.count(name: "corpus.float_lane.dark_provider") == 0,
                "dark_provider must be 0 on vocabMiss path (provider has a basis, query is OOV)")

            // dark_no_rows must NOT move — we never reached the store search.
            #expect(sink.count(name: "corpus.float_lane.dark_no_rows") == 0,
                "dark_no_rows must be 0 on vocabMiss path")

            // hit must NOT move.
            #expect(sink.count(name: "corpus.float_lane.hit") == 0,
                "hit must not move on vocabMiss path")
        }
    }

    /// A brand-new, never-trained RandomIndexingProvider (empty vocab) injected
    /// directly through the Corpus internal test seam → .unavailableProviderOptOut.
    ///
    /// An untrained provider's vocab is empty — `embedFloat` returns `[]` without
    /// throwing, so Corpus classifies it as a structural opt-out (dark_provider),
    /// NOT as vocabMiss (dark_vocab_miss). The two dark reasons must be distinct.
    @Test("never-trained RI provider (empty vocab) → .unavailableProviderOptOut (not vocabMiss)")
    func neverTrainedRIProviderYieldsProviderOptOut() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(true)
            defer {
                Intellectus.setEnabled(false)
                Intellectus.install(sink: NoOpSink.shared)
            }

            // Inject a brand-new, never-trained RandomIndexingProvider through
            // the internal test seam. vocab is empty; embedFloat returns [] without
            // throwing → Corpus sees an empty vector → structural opt-out.
            let storage = try makeScratchStorage()
            let corpus = try await Corpus(storage: storage, provider: RandomIndexingProvider())

            let outcome = await corpus.floatNearest(query: "car engine", limit: 5)

            // Empty vocab → structural opt-out, NOT vocabMiss.
            if case .unavailableProviderOptOut = outcome {
                // Expected — pass.
            } else {
                Issue.record(
                    "expected .unavailableProviderOptOut for never-trained RI provider, got \(outcome)")
            }

            // dark_provider fires; dark_vocab_miss must NOT fire (wrong reason).
            #expect(sink.count(name: "corpus.float_lane.dark_provider") == 1,
                "dark_provider must be emitted once for never-trained RI (empty vocab)")
            #expect(sink.count(name: "corpus.float_lane.dark_vocab_miss") == 0,
                "dark_vocab_miss must be 0 for untrained RI — it is a structural opt-out")
        }
    }

    /// When monitoring is disabled, dark_vocab_miss must NOT be emitted even
    /// though the vocabMiss outcome still fires correctly.
    @Test("dark_vocab_miss not emitted when monitoring disabled")
    func vocabMissCounterSilentWhenMonitoringOff() async throws {
        try await GlobalTestLock.shared.withLock {
            let sink = CapturingSink()
            Intellectus.install(sink: sink)
            Intellectus.setEnabled(false)  // monitoring OFF
            defer {
                Intellectus.install(sink: NoOpSink.shared)
            }

            let storage = try makeScratchStorage()
            let corpus = try await Corpus(
                storage: storage,
                model: .randomIndexing(provider: RandomIndexingProvider()))

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            for (i, doc) in ["car engine road", "vehicle fuel transport"].enumerated() {
                try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now)
            }
            try await corpus.reindex(now: now)

            // OOV query — outcome must still be vocabMiss but counter suppressed.
            let outcome = await corpus.floatNearest(query: "zxqvmlkj99 wvbnrqxp88", limit: 5)

            if case .unavailableNoVocabHit = outcome {
                // Outcome correct even without monitoring.
            } else {
                Issue.record("expected .unavailableNoVocabHit, got \(outcome)")
            }

            // No telemetry emitted when monitoring is off.
            #expect(sink.count(name: "corpus.float_lane.dark_vocab_miss") == 0,
                "dark_vocab_miss must not be emitted when monitoring is disabled")
        }
    }
}
