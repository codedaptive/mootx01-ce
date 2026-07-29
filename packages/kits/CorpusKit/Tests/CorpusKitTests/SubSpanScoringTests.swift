// SubSpanScoringTests.swift
//
// Tests for SubSpanScoring (MISSION_11X_RECALL_GAP_01 Item 1).
//
// Coverage:
//   §1  subSpanRanges — deterministic segmentation unit tests.
//         Verifies UTF-8 byte-offset calculation, window/stride arithmetic,
//         and overlap stitching. Cross-port contract: Rust twin must produce
//         bit-identical ranges for the same inputs.
//   §2  cosineSimilarity — inline L2-normalized dot product unit tests.
//         Covers identical, orthogonal, opposite, and zero vectors.
//   §3  score() — empty-input fast-path guard.
//         Empty query or empty candidateIDs → empty dict without hitting the
//         source or provider.
//   §4  score() — provider without a float lane (embedFloat throws).
//         Verifies silent degradation: empty dict returned, no crash.
//   §5  Sub-span rescue fixture (the 1.0.x scenario).
//         A saturated corpus where whole-doc cosine fails to separate but
//         sub-span max-cosine ranks the true answer first. Uses a
//         text-routing mock provider and a MapContentSource.
//   §6a CorpusDocumentStore integration — CorpusContentEngine.scoreSubSpans.
//         Verifies the engine delegates correctly and returns scored results.
//   §6b Custom CorpusContentSource integration — SubSpanScoring.score() direct.
//         Exercises the source-protocol path (the GLK LocusKit-backed adapter
//         profile) without a real SQL store.
//
// Model / provider helpers:
//   FirstTokenRoutingProvider  — routes embedFloat by text prefix; "target…"
//                                returns vec_A = [1.0, 0.0], others vec_B.
//   ThrowingFloatProvider      — embedFloat always throws; used in §4.
//   MapContentSource           — in-memory CorpusContentSource (dict-backed).
//
// Ingest tests (§6a) hold GlobalTestLock.shared for telemetry isolation.

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

// MARK: - Mock providers

/// Routes `embedFloat` by text prefix.
///
/// "target…" → vec_A = [1.0, 0.0] (the "query direction").
/// Anything else → vec_B = [0.0, 1.0] (orthogonal).
///
/// Cosine(vec_A, vec_A) = 1.0 → normalized (1+1)/2 = 1.0.
/// Cosine(vec_A, vec_B) = 0.0 → normalized (0+1)/2 = 0.5.
///
/// The rescue fixture exploits the sub-span whose extracted text starts
/// with "target" to surface cosine 1.0 even when the whole-doc text does
/// not start with "target" (whole-doc → vec_B → cosine 0.5 with query).
private struct FirstTokenRoutingProvider: EmbeddingProvider, @unchecked Sendable {
    let modelID = "test-first-token-routing-v1"
    let modelVersion = "1.0.0"

    // Two orthogonal unit directions in 2-d space.
    static let vecA: [Float] = [1.0, 0.0]  // "target" direction
    static let vecB: [Float] = [0.0, 1.0]  // "noise" direction

    /// Not exercised by SubSpanScoring — stub satisfies protocol requirement.
    func embed(_ text: String) async throws -> Engram {
        throw VectorKitError.embeddingFailed(
            "FirstTokenRoutingProvider: embed() not needed for sub-span tests")
    }

    /// Returns vec_A for texts that start with the ASCII prefix "target",
    /// vec_B for everything else. Empty → empty (provider opt-out for empty).
    func embedFloat(_ text: String) async throws -> [Float] {
        guard !text.isEmpty else { return [] }
        return text.hasPrefix("target") ? Self.vecA : Self.vecB
    }
}

/// Float-lane opt-out provider: `embedFloat` always throws.
///
/// Used in §4 to verify that `SubSpanScoring.score()` returns an empty dict
/// when the provider cannot produce float embeddings (silent degradation).
private struct ThrowingFloatProvider: EmbeddingProvider, @unchecked Sendable {
    let modelID = "test-throwing-float-v1"
    let modelVersion = "1.0.0"

    func embed(_ text: String) async throws -> Engram {
        throw VectorKitError.embeddingFailed(
            "ThrowingFloatProvider: embed() not used in sub-span tests")
    }

    func embedFloat(_ text: String) async throws -> [Float] {
        throw VectorKitError.embeddingFailed(
            "ThrowingFloatProvider: no float lane — embedFloat always throws")
    }
}

// MARK: - Mock content source

/// In-memory `CorpusContentSource` backed by a dictionary.
///
/// Implements only `record(for:)`, `changes(since:limit:)`, and
/// `activeContentIDs()`. SubSpanScoring.score() calls the default
/// N-serial `records(for:)` implementation on the protocol, which
/// delegates to `record(for:)`. This exercises the source-protocol
/// path that the GLK LocusKit-backed adapter also uses.
private struct MapContentSource: CorpusContentSource, @unchecked Sendable {
    let backing: [CorpusContentID: CorpusContentRecord]

    func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        backing[id]
    }

    func changes(since cursor: String?, limit: Int) async throws -> CorpusContentChangeBatch {
        .empty
    }

    func activeContentIDs() async throws -> [CorpusContentID] {
        Array(backing.keys).sorted()
    }
}

// MARK: - Engine helper (CorpusDocumentStore path)

/// Creates a standalone CorpusContentEngine backed by a CorpusDocumentStore,
/// using `directionalModel()` for the embedding provider. The engine's
/// `scoreSubSpans` delegates to SubSpanScoring.score() through
/// `slots[0].provider`, which is the model's EmbeddingProvider.
///
/// `directionalModel()` maps texts to one-hot 384-d vectors by token-sum
/// mod 384. Used in §6a to verify engine delegation, not to reproduce the
/// rescue scenario (the rescue is demonstrated with FirstTokenRoutingProvider).
private func directionalModel() -> EmbeddingModel {
    .miniLM(inference: { tokens in
        var v = [Float](repeating: 0.0, count: 384)
        let sum = tokens.reduce(Int32(0), &+)
        let slot = Int((sum % 384 + 384) % 384)
        v[slot] = 1.0
        return v
    })
}

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

// MARK: - §1: subSpanRanges — deterministic segmentation

@Suite("§1 SubSpanRanges — deterministic segmentation", .serialized)
struct SubSpanRangesTests {

    // §1a — empty text produces no ranges.
    @Test("empty text → empty ranges") func emptyText() {
        let ranges = SubSpanScoring.subSpanRanges(text: "", windowTokens: 32, overlapTokens: 8)
        #expect(ranges.isEmpty, "empty text must produce no ranges")
    }

    // §1b — text with no alphanumeric scalars produces no ranges.
    @Test("punctuation-only text → empty ranges") func punctuationOnly() {
        let ranges = SubSpanScoring.subSpanRanges(
            text: "   .,!?---   ", windowTokens: 4, overlapTokens: 0)
        #expect(ranges.isEmpty, "text with no alphanumeric tokens must produce no ranges")
    }

    // §1c — single token produces one range.
    @Test("single token → one range covering it") func singleToken() {
        let text = "hello"
        let ranges = SubSpanScoring.subSpanRanges(text: text, windowTokens: 4, overlapTokens: 0)
        #expect(ranges.count == 1, "single token must produce exactly one range")
        #expect(ranges[0].utf8Start == 0)
        // "hello" = 5 ASCII bytes
        #expect(ranges[0].utf8Length == 5)
        // Verify extraction round-trips.
        let utf8 = text.utf8
        let lo = utf8.index(utf8.startIndex, offsetBy: 0)
        let hi = utf8.index(lo, offsetBy: 5)
        let extracted = String(bytes: Array(utf8[lo..<hi]), encoding: .utf8)
        #expect(extracted == "hello")
    }

    // §1d — two tokens inside one window: single span covering both.
    @Test("two tokens inside one window → single span") func twoTokensSingleWindow() {
        // "hello world" — 2 tokens, window=4, no overlap → fits in one window.
        let text = "hello world"
        let ranges = SubSpanScoring.subSpanRanges(text: text, windowTokens: 4, overlapTokens: 0)
        #expect(ranges.count == 1, "two tokens within a 4-token window must produce one range")
        #expect(ranges[0].utf8Start == 0)
        // "hello world" = 11 bytes; span covers from byte 0 through end of "world" = 11.
        #expect(ranges[0].utf8Length == 11)
    }

    // §1e — eight tokens, window=4, overlap=0: two non-overlapping ranges.
    //        This is the exact fixture used in §5 (rescue test).
    @Test("eight tokens, window=4, overlap=0 → two non-overlapping spans") func eightTokensTwoWindows() {
        // Text: "n1 n2 n3 n4 t1 t2 t3 t4"
        //  byte layout (all ASCII):
        //    "n1"(0-1) " "(2) "n2"(3-4) " "(5) "n3"(6-7) " "(8) "n4"(9-10) " "(11)
        //    "t1"(12-13) " "(14) "t2"(15-16) " "(17) "t3"(18-19) " "(20) "t4"(21-22)
        //  8 tokens; window=4, stride=4 → 2 windows.
        let text = "n1 n2 n3 n4 t1 t2 t3 t4"
        let ranges = SubSpanScoring.subSpanRanges(text: text, windowTokens: 4, overlapTokens: 0)
        #expect(ranges.count == 2, "8 tokens with window=4 overlap=0 must produce 2 ranges")
        let utf8 = text.utf8
        // Window 0: "n1 n2 n3 n4" — bytes [0, 11)
        #expect(ranges[0].utf8Start == 0)
        #expect(ranges[0].utf8Length == 11)
        let span0 = extractSpan(utf8, ranges[0])
        #expect(span0 == "n1 n2 n3 n4",
            "window 0 must extract 'n1 n2 n3 n4'; got '\(span0 ?? "nil")'")
        // Window 1: "t1 t2 t3 t4" — bytes [12, 23)
        #expect(ranges[1].utf8Start == 12)
        #expect(ranges[1].utf8Length == 11)
        let span1 = extractSpan(utf8, ranges[1])
        #expect(span1 == "t1 t2 t3 t4",
            "window 1 must extract 't1 t2 t3 t4'; got '\(span1 ?? "nil")'")
    }

    // §1f — overlap stitches adjacent windows (tokens 2–3 appear in both).
    @Test("overlap=2 creates overlapping windows") func overlapStitches() {
        // "a b c d e f" — 6 tokens, window=4, overlap=2, stride=2.
        //   Window 0: tokens[0..3] = "a b c d"
        //   Window 1: tokens[2..5] = "c d e f"
        let text = "a b c d e f"
        let ranges = SubSpanScoring.subSpanRanges(text: text, windowTokens: 4, overlapTokens: 2)
        #expect(ranges.count == 2, "6 tokens with window=4 overlap=2 must produce 2 ranges")
        // Window 0 covers "a b c d".
        let utf8 = text.utf8
        let span0 = extractSpan(utf8, ranges[0])
        #expect(span0 == "a b c d", "window 0 must cover 'a b c d'; got '\(span0 ?? "nil")'")
        // Window 1 covers "c d e f".
        let span1 = extractSpan(utf8, ranges[1])
        #expect(span1 == "c d e f", "window 1 must cover 'c d e f'; got '\(span1 ?? "nil")'")
    }

    // §1g — window larger than total tokens: one span covering all tokens.
    @Test("window > token count → single span covering all tokens") func windowLargerThanTokenCount() {
        let text = "alpha beta gamma"  // 3 tokens
        let ranges = SubSpanScoring.subSpanRanges(text: text, windowTokens: 32, overlapTokens: 8)
        #expect(ranges.count == 1, "3 tokens in a 32-token window must produce 1 range")
        let utf8 = text.utf8
        let span = extractSpan(utf8, ranges[0])
        #expect(span == "alpha beta gamma")
    }

    // §1h — ASCII digits are token characters.
    @Test("ASCII digits are token characters") func asciiDigitsAreTokens() {
        // "h2o co2" — two tokens: "h2o" and "co2" (digits are in-token).
        let text = "h2o co2"
        let ranges = SubSpanScoring.subSpanRanges(text: text, windowTokens: 4, overlapTokens: 0)
        #expect(ranges.count == 1, "h2o and co2 are single tokens; both fit in window=4")
        let utf8 = text.utf8
        let span = extractSpan(utf8, ranges[0])
        #expect(span == "h2o co2")
    }

    // Helper: extract span text from a UTF-8 view given (start, length).
    private func extractSpan(_ utf8: String.UTF8View, _ r: (utf8Start: Int, utf8Length: Int)) -> String? {
        guard r.utf8Start >= 0, r.utf8Start + r.utf8Length <= utf8.count else { return nil }
        let lo = utf8.index(utf8.startIndex, offsetBy: r.utf8Start)
        let hi = utf8.index(lo, offsetBy: r.utf8Length)
        return String(bytes: Array(utf8[lo..<hi]), encoding: .utf8)
    }
}

// MARK: - §2: cosineSimilarity — inline dot-product unit tests

@Suite("§2 cosineSimilarity — inline L2-normalized dot product", .serialized)
struct CosineSimilarityTests {

    // §2a — identical unit vectors → 1.0
    @Test("identical unit vectors → cosine 1.0") func identical() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [1.0, 0.0, 0.0]
        let c = SubSpanScoring.cosineSimilarity(a, b)
        #expect(abs(c - 1.0) < 0.0001, "identical vectors must produce cosine 1.0; got \(c)")
    }

    // §2b — orthogonal unit vectors → 0.0
    @Test("orthogonal unit vectors → cosine 0.0") func orthogonal() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [0.0, 1.0]
        let c = SubSpanScoring.cosineSimilarity(a, b)
        #expect(abs(c) < 0.0001, "orthogonal vectors must produce cosine 0.0; got \(c)")
    }

    // §2c — opposite unit vectors → -1.0
    @Test("opposite unit vectors → cosine -1.0") func opposite() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [-1.0, 0.0]
        let c = SubSpanScoring.cosineSimilarity(a, b)
        #expect(abs(c - (-1.0)) < 0.0001, "opposite vectors must produce cosine -1.0; got \(c)")
    }

    // §2d — non-unit vectors: cosine is L2-normalized, so scale doesn't matter.
    @Test("non-unit same-direction vectors → cosine 1.0") func nonUnitSameDirection() {
        let a: [Float] = [2.0, 0.0]
        let b: [Float] = [5.0, 0.0]
        let c = SubSpanScoring.cosineSimilarity(a, b)
        #expect(abs(c - 1.0) < 0.0001, "scaled same-direction vectors must produce cosine 1.0; got \(c)")
    }

    // §2e — zero vector → 0.0 (safe fallback, no divide by zero).
    @Test("zero vector → cosine 0.0 (safe fallback)") func zeroVector() {
        let a: [Float] = [1.0, 0.0]
        let z: [Float] = [0.0, 0.0]
        let c = SubSpanScoring.cosineSimilarity(a, z)
        #expect(c == 0.0, "zero-norm vector must produce cosine 0.0 (safe fallback); got \(c)")
    }

    // §2f — empty vectors → 0.0 (length mismatch guard).
    @Test("empty vectors → cosine 0.0") func emptyVectors() {
        let c = SubSpanScoring.cosineSimilarity([], [])
        #expect(c == 0.0, "empty vectors must produce cosine 0.0; got \(c)")
    }

    // §2g — mismatched lengths → 0.0 (guard fires).
    @Test("mismatched-length vectors → cosine 0.0") func mismatchedLength() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [1.0, 0.0, 0.0]
        let c = SubSpanScoring.cosineSimilarity(a, b)
        #expect(c == 0.0, "mismatched-length vectors must produce cosine 0.0; got \(c)")
    }
}

// MARK: - §3: score() — empty-input fast-path

@Suite("§3 score() — empty-input guard returns empty dict", .serialized)
struct ScoreEmptyInputTests {

    // §3a — empty query string → empty dict without hitting provider.
    @Test("empty query → empty dict") func emptyQuery() async {
        // The throwing provider is never called: the guard fires first.
        let provider = ThrowingFloatProvider()
        let source = MapContentSource(backing: ["a": makeRecord("a", text: "hello world")])
        let result = await SubSpanScoring.score(
            query: "", candidateIDs: ["a"], source: source, provider: provider)
        #expect(result.isEmpty, "empty query must return empty dict without calling provider")
    }

    // §3b — empty candidateIDs → empty dict without hitting source.
    @Test("empty candidateIDs → empty dict") func emptyCandidateIDs() async {
        let provider = ThrowingFloatProvider()
        let source = MapContentSource(backing: ["a": makeRecord("a", text: "hello world")])
        let result = await SubSpanScoring.score(
            query: "hello", candidateIDs: [], source: source, provider: provider)
        #expect(result.isEmpty, "empty candidateIDs must return empty dict without calling source")
    }

    private func makeRecord(_ id: String, text: String) -> CorpusContentRecord {
        CorpusContentRecord(id: id, revision: 1,
            digest: CorpusContentDigest.digest(text), text: text)
    }
}

// MARK: - §4: score() — provider without float lane

@Suite("§4 score() — provider without float lane returns empty dict", .serialized)
struct ScoreNoFloatLaneTests {

    // §4a — provider that throws on embedFloat causes empty result.
    @Test("throwing embedFloat → empty dict (silent degradation)") func throwingProvider() async {
        let provider = ThrowingFloatProvider()
        let source = MapContentSource(backing: [
            "doc1": makeRecord("doc1", "this is a document"),
            "doc2": makeRecord("doc2", "another document here"),
        ])
        let result = await SubSpanScoring.score(
            query: "document", candidateIDs: ["doc1", "doc2"],
            source: source, provider: provider)
        // Provider opt-out: empty dict, no crash.
        #expect(result.isEmpty,
            "provider without float lane must return empty dict; got \(result)")
    }

    private func makeRecord(_ id: String, _ text: String) -> CorpusContentRecord {
        CorpusContentRecord(id: id, revision: 1,
            digest: CorpusContentDigest.digest(text), text: text)
    }
}

// MARK: - §5: Sub-span rescue fixture

/// The 1.0.x scenario: whole-doc cosine fails to separate the true answer
/// from distractors, but sub-span max-cosine ranks it first.
///
/// Fixture design:
///   - Provider: `FirstTokenRoutingProvider`
///     • text starting with "target" → vec_A = [1.0, 0.0]
///     • other text → vec_B = [0.0, 1.0]
///   - Query: "target" → vec_A
///   - True answer text: "noise noise noise noise target target target target"
///     • whole-doc: starts with "noise" → vec_B → cosine(A,B)=0 → norm=0.5
///     • window=4, overlap=0: window 1 = "target target target target" →
///       vec_A → cosine(A,A)=1 → norm=1.0 — the rescue sub-span
///     • max-cosine = 1.0
///   - Distractor text: "noise noise noise noise noise noise noise noise"
///     • all windows start with "noise" → vec_B → norm=0.5 for all
///     • max-cosine = 0.5
///
/// Score assertion: trueAnswer (1.0) > distractor (0.5). ✓
@Suite("§5 Sub-span rescue fixture (saturation recovery)", .serialized)
struct SubSpanRescueTests {

    @Test("sub-span max-cosine ranks true answer above distractors")
    func rescueFixture() async throws {
        let provider = FirstTokenRoutingProvider()

        // true answer: 4 "noise" tokens + 4 "target" tokens.
        // With window=4, overlap=0: two windows.
        //   Window 0 → "noise noise noise noise" → vec_B → norm 0.5
        //   Window 1 → "target target target target" → vec_A → norm 1.0
        let trueAnswerText = "noise noise noise noise target target target target"

        // distractors: only "noise" tokens; no "target" sub-span.
        let distractor1Text = "noise noise noise noise noise noise noise noise"
        let distractor2Text = "noise noise noise noise noise noise noise noise"

        let source = MapContentSource(backing: [
            "true_answer":  makeRecord("true_answer",  trueAnswerText),
            "distractor1":  makeRecord("distractor1",  distractor1Text),
            "distractor2":  makeRecord("distractor2",  distractor2Text),
        ])

        let results = await SubSpanScoring.score(
            query: "target",
            candidateIDs: ["true_answer", "distractor1", "distractor2"],
            source: source,
            provider: provider,
            windowTokens: 4,
            overlapTokens: 0)

        // All three candidates must appear: both vec_A cosine 1.0 (norm 1.0)
        // and vec_B cosine 0.0 (norm 0.5) are > 0.
        let trueScore      = try #require(results["true_answer"],
            "true_answer must appear in scored results")
        let distScore1     = try #require(results["distractor1"],
            "distractor1 must appear in scored results")
        let distScore2     = try #require(results["distractor2"],
            "distractor2 must appear in scored results")

        // True answer must score above the distractors.
        #expect(trueScore > distScore1,
            "true_answer (\(trueScore)) must outscore distractor1 (\(distScore1))")
        #expect(trueScore > distScore2,
            "true_answer (\(trueScore)) must outscore distractor2 (\(distScore2))")

        // Exact score assertions: true answer = 1.0, distractors = 0.5.
        #expect(abs(trueScore - 1.0) < 0.001,
            "true_answer sub-span cosine must normalize to 1.0; got \(trueScore)")
        #expect(abs(distScore1 - 0.5) < 0.001,
            "distractor1 cosine 0.0 must normalize to 0.5; got \(distScore1)")
    }

    // §5b — candidate absent from source is not scored (absent ≠ 0.0 in dict).
    @Test("candidate absent from source is omitted from result") func absentCandidateOmitted() async {
        let provider = FirstTokenRoutingProvider()
        let source = MapContentSource(backing: [
            "present": makeRecord("present", "target target"),
        ])
        let results = await SubSpanScoring.score(
            query: "target",
            candidateIDs: ["present", "absent_id"],
            source: source,
            provider: provider,
            windowTokens: 4, overlapTokens: 0)
        // "present" must be scored; "absent_id" must be omitted.
        #expect(results["present"] != nil,
            "candidate present in source must appear in results")
        #expect(results["absent_id"] == nil,
            "candidate absent from source must be omitted (implicit 0.0)")
    }

    // §5c — effectiveDenseText is used when denseCompositionText is set.
    @Test("effectiveDenseText (denseCompositionText) is used for embedding") func dualTextEmbedding() async throws {
        let provider = FirstTokenRoutingProvider()
        // text = "noise content" (starts with "noise" → vec_B)
        // denseCompositionText = "target enrichment" (starts with "target" → vec_A)
        // query = "target" → vec_A
        // Sub-span scoring uses effectiveDenseText = denseCompositionText,
        // so the score should be high (cosine 1.0 → norm 1.0).
        let record = CorpusContentRecord(
            id: "dual_text",
            revision: 1,
            digest: CorpusContentDigest.digest("noise content"),
            text: "noise content",
            denseCompositionText: "target enrichment")
        let source = MapContentSource(backing: ["dual_text": record])
        let results = await SubSpanScoring.score(
            query: "target",
            candidateIDs: ["dual_text"],
            source: source,
            provider: provider,
            windowTokens: 4, overlapTokens: 0)
        let score = try #require(results["dual_text"],
            "dual_text with denseCompositionText=target… must be scored")
        // denseCompositionText "target enrichment" → vec_A → cosine 1.0 → norm 1.0.
        #expect(abs(score - 1.0) < 0.001,
            "effectiveDenseText must be used; expected score 1.0, got \(score)")
    }

    private func makeRecord(_ id: String, _ text: String) -> CorpusContentRecord {
        CorpusContentRecord(id: id, revision: 1,
            digest: CorpusContentDigest.digest(text), text: text)
    }
}

// MARK: - §6a: CorpusDocumentStore integration

/// Exercises `CorpusContentEngine.scoreSubSpans(query:candidateIDs:)`:
/// the engine wires `self.source` (CorpusDocumentStore) and
/// `slots[0].provider` (the model's EmbeddingProvider) to SubSpanScoring.score.
///
/// Uses `directionalModel()` — the same provider used in DiscriminationSignalTests.
/// The fixture verifies that indexed content is reachable via scoreSubSpans and
/// that the scored candidate is returned. The rescue-quality assertion (true answer
/// ranks first) is fully covered in §5; this section focuses on delegation fidelity.
@Suite("§6a CorpusContentEngine — scoreSubSpans delegation", .serialized)
struct ContentEngineScoreSubSpansTests {

    @Test("scoreSubSpans returns non-empty result for indexed content")
    func delegationReturnsResult() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store) = try await makeEngine(model: directionalModel())

            _ = try await store.put("alpha alpha alpha", id: "doc1", now: testNow)
            _ = try await store.put("omega omega omega", id: "doc2", now: testNow)

            // scoreSubSpans does NOT require indexContent — it resolves records
            // directly via the source. Verify it works without prior indexContent.
            let results = await engine.scoreSubSpans(
                query: "alpha alpha alpha",
                candidateIDs: ["doc1", "doc2"])

            // Both candidates are in the source and are scored.
            // directionalModel maps texts to one-hot by token-sum:
            //   "alpha alpha alpha" and "omega omega omega" map to distinct slots,
            //   each scoring non-zero against the query.
            //
            // We assert non-empty (delegation succeeded) and that doc1 outscores
            // doc2 (query matches doc1's direction, not doc2's).
            #expect(!results.isEmpty,
                "scoreSubSpans must return scored results for content in the source")

            let score1 = results["doc1"] ?? 0.0
            let score2 = results["doc2"] ?? 0.0
            #expect(score1 > score2,
                "doc1 (matching query direction) must outscore doc2; got doc1=\(score1), doc2=\(score2)")
        }
    }

    @Test("scoreSubSpans with absent candidateIDs returns empty or partial result")
    func absentCandidatesOmitted() async throws {
        try await GlobalTestLock.shared.withLock {
            let (engine, store) = try await makeEngine(model: directionalModel())
            _ = try await store.put("alpha alpha alpha", id: "present", now: testNow)

            let results = await engine.scoreSubSpans(
                query: "alpha alpha alpha",
                candidateIDs: ["present", "nonexistent_id"])

            // "present" is in the source; "nonexistent_id" is not.
            #expect(results["present"] != nil,
                "candidate present in source must be scored")
            #expect(results["nonexistent_id"] == nil,
                "candidate absent from source must be omitted (implicit 0.0)")
        }
    }
}

// MARK: - §6b: Custom CorpusContentSource integration

/// Exercises `SubSpanScoring.score()` directly with a `MapContentSource`
/// (the custom CorpusContentSource path that GLK's LocusKit-backed adapter
/// also uses). Verifies that the N-serial default `records(for:)` implementation
/// on CorpusContentSource is exercised correctly (MapContentSource does not
/// override `records(for:)`).
@Suite("§6b Custom CorpusContentSource — source-protocol path", .serialized)
struct CustomSourceScoreTests {

    @Test("custom source path scores candidates correctly") func customSourceScoring() async throws {
        let provider = FirstTokenRoutingProvider()
        let source = MapContentSource(backing: [
            "answer": makeRecord("answer", "target target target target target target target target"),
            "noise1": makeRecord("noise1", "noise noise noise noise noise noise noise noise"),
            "noise2": makeRecord("noise2", "noise noise noise noise noise noise noise noise"),
        ])

        let results = await SubSpanScoring.score(
            query: "target",
            candidateIDs: ["answer", "noise1", "noise2"],
            source: source,
            provider: provider,
            windowTokens: 4, overlapTokens: 0)

        let answerScore = try #require(results["answer"],
            "answer must be scored by custom source path")
        let noise1Score = try #require(results["noise1"],
            "noise1 must be scored (non-zero cosine with query)")

        // "answer": all sub-spans start with "target" → vec_A → norm 1.0
        #expect(abs(answerScore - 1.0) < 0.001,
            "answer must score 1.0 via custom source; got \(answerScore)")
        // "noise1": all sub-spans → vec_B → norm 0.5
        #expect(abs(noise1Score - 0.5) < 0.001,
            "noise1 must score 0.5 via custom source; got \(noise1Score)")
        // answer must rank above noise.
        #expect(answerScore > noise1Score)
    }

    private func makeRecord(_ id: String, _ text: String) -> CorpusContentRecord {
        CorpusContentRecord(id: id, revision: 1,
            digest: CorpusContentDigest.digest(text), text: text)
    }
}
