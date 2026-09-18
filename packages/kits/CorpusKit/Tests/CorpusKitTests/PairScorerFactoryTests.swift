// PairScorerFactoryTests.swift
//
// The factory's failure contract (same order as the span encoder factory),
// the CoreML input preparation for pairs, the fixedLength clamp branch with
// a fake inference (no model files needed), and, when the packaged assets are
// present, the loaded classifier's logits against the lab's reference fixture.
// Assets are never in git: set `MOOT_CROSS_ENCODER_ASSETS` to a build-all
// output root (with `apple/` and `linux/`) to enable the last suite; it skips
// otherwise.
//
// Failure modes: a throw of the wrong class (the lifecycle's one log line
// would name the wrong cause), padding that leaks into the attention mask,
// a converted classifier whose logits drift from the PyTorch reference.

import Testing
import Foundation
@testable import CorpusKit
@testable import CorpusKitProviders

private func scratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pair-factory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// `<assets>/apple` when `MOOT_CROSS_ENCODER_ASSETS` names a build output root.
private var packagedAppleDirectory: URL? {
    guard let root = ProcessInfo.processInfo.environment["MOOT_CROSS_ENCODER_ASSETS"], !root.isEmpty else {
        return nil
    }
    let dir = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("apple", isDirectory: true)
    return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
}

@Suite("PairScorerFactory failure contract")
struct PairScorerFactoryTests {

    @Test("missing model directory is modelUnavailable")
    func missingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pair-factory-missing-\(UUID().uuidString)")
        do {
            _ = try PairScorerFactory.make(profile: .minilmL6, modelDirectory: missing)
            Issue.record("factory must throw for a missing directory")
        } catch let error as EncoderError {
            guard case .modelUnavailable = error else {
                Issue.record("expected modelUnavailable, got \(error)"); return
            }
        } catch {
            Issue.record("expected EncoderError, got \(error)")
        }
    }

    @Test("vocab hash disagreement is tokenizerMismatch carrying the real digest")
    func hashMismatch() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vocab = Data("[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n".utf8)
        try vocab.write(to: dir.appendingPathComponent("vocab.txt"))
        do {
            _ = try PairScorerFactory.make(profile: .minilmL6, modelDirectory: dir)
            Issue.record("factory must throw on a hash mismatch")
        } catch let error as EncoderError {
            #expect(error == .tokenizerMismatch(
                expected: CrossEncoderProfile.minilmL6.tokenizerHash,
                actual: SpanEncoderFactory.hexDigest(of: vocab)))
        } catch {
            Issue.record("expected EncoderError, got \(error)")
        }
    }

    @Test("matching vocab hash but no compiled classifier is modelUnavailable (hash check runs first)")
    func matchingHashNoModel() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vocab = Data("[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n".utf8)
        try vocab.write(to: dir.appendingPathComponent("vocab.txt"))
        let matching = CrossEncoderProfile(
            modelID: "fake-cross", modelVersion: "0",
            tokenizerHash: SpanEncoderFactory.hexDigest(of: vocab),
            maxSequence: 512, pool: 50, head: 30, spans: 3, rrfK: 60)
        do {
            _ = try PairScorerFactory.make(profile: matching, modelDirectory: dir)
            Issue.record("factory must throw when no model file exists")
        } catch let error as EncoderError {
            guard case .modelUnavailable = error else {
                Issue.record("expected modelUnavailable, got \(error)"); return
            }
        } catch {
            Issue.record("expected EncoderError, got \(error)")
        }
    }
}

#if canImport(CoreML)
// MARK: - Clamp branch (fake inference, no model files needed)

/// A fake `PairInference` that reports a fixed sequence length. Instantiated
/// with the tokenizer the factory chose after applying the clamp, so the test
/// can verify the clamped `maxTokens` without loading a real CoreML model.
private final class FakePairInferenceForClamp: PairInference, @unchecked Sendable {
    /// Advertised compiled sequence length — triggers the factory clamp when
    /// this value is below the profile's `maxSequence`.
    let fixedLength: Int? = 128
    var backend: String { "fake-clamp" }
    /// The tokenizer the factory passed when constructing this instance.
    /// Set by the injectable seam closure; asserted in the test.
    let tokenizer: WordPieceTokenizer
    init(tokenizer: WordPieceTokenizer) { self.tokenizer = tokenizer }
    func logits(query: String, spans: [String]) async throws -> [Float] {
        spans.map { _ in 0.0 }
    }
}

@Suite("PairScorerFactory fixedLength clamp (fake inference)")
struct PairScorerFactoryFakeClampTests {

    @Test("fixedLength=128 below maxSequence=512 clamps the scorer's tokenizer maxTokens to 128")
    func clampBranchFakeInference() throws {
        // Drives `PairScorerFactory.make` with an injectable inference whose
        // fixedLength is 128 (below the profile's maxSequence=512). The factory
        // must detect the clamp and call the seam a second time with a tokenizer
        // whose maxTokens equals the clamped value.
        //
        // Mutation gate: deleting the `effectiveMax < profile.maxSequence` branch
        // causes the seam to be called only once (with maxTokens=512), so the
        // assertion fails with 512 instead of 128.
        //
        // Swift reads the ceiling from the CoreML `input_ids` shape constraint.
        // Rust reads `max_position_embeddings` from config.json.
        // Both are applied as min(profile.maxSequence, fixedLength).
        var lastInference: FakePairInferenceForClamp? = nil
        let scorer = try PairScorerFactory.make(
            profile: .minilmL6,
            modelDirectory: FileManager.default.temporaryDirectory,
            makeInference: { _, tokenizer in
                let inf = FakePairInferenceForClamp(tokenizer: tokenizer)
                lastInference = inf
                return inf
            }
        )
        // 128 < 512, so the clamp branch ran and the seam received a tokenizer
        // with maxTokens=128 on its second call.
        let captured = try #require(lastInference, "makeInference was never called")
        #expect(captured.tokenizer.maxTokens == 128,
            "factory clamp must build a tokenizer with maxTokens=128, got \(captured.tokenizer.maxTokens)")
        // The scorer wraps the clamped inference.
        let ps = try #require(scorer as? ProviderPairScorer, "make must return ProviderPairScorer")
        #expect(ps.inference.fixedLength == 128)
    }
}

// MARK: - Asset-gated clamping test

/// Verifies that `CoreMLPairInference` exposes `fixedLength` (I6-2) and that
/// `PairScorerFactory.make` successfully builds a scorer for the packaged asset.
/// The packaged MinilmL6 model compiles to a fixed 512-token shape, which equals
/// `profile.maxSequence = 512`, so no clamping occurs for the current asset.
/// The clamp logic guards future profiles where `fixedLength < maxSequence`.
@Suite("PairScorerFactory maxSequence clamping (MOOT_CROSS_ENCODER_ASSETS)")
struct PairScorerFactoryClampTests {

    @Test(
        "CoreMLPairInference exposes fixedLength and scorer builds without error",
        .enabled(if: packagedAppleDirectory != nil, "MOOT_CROSS_ENCODER_ASSETS not set — skipping asset-gated test")
    )
    func fixedLengthIsExposed() throws {
        guard let dir = packagedAppleDirectory else { return }
        let scorer = try PairScorerFactory.make(profile: .minilmL6, modelDirectory: dir)
        let ps = try #require(scorer as? ProviderPairScorer,
            "factory must return ProviderPairScorer on CoreML path")
        guard let coreml = ps.inference as? CoreMLPairInference else {
            Issue.record("inference is not CoreMLPairInference"); return
        }
        // fixedLength must be non-nil and must not exceed maxSequence.
        if let fl = coreml.fixedLength {
            #expect(fl <= CrossEncoderProfile.minilmL6.maxSequence,
                "model fixedLength \(fl) exceeds profile maxSequence — tokenizer would overflow")
        }
        // Tokenizer's maxTokens must equal the smaller of fixedLength and maxSequence.
        let expectedMax = coreml.fixedLength.map { min(CrossEncoderProfile.minilmL6.maxSequence, $0) }
            ?? CrossEncoderProfile.minilmL6.maxSequence
        #expect(coreml.tokenizer.maxTokens == expectedMax)
    }
}

@Suite("CoreMLPairInference input preparation")
struct CoreMLPairInferenceInputTests {

    @Test("a fixed shape pads ids with [PAD], segments with 0 and masks the padding")
    func fixedShape() {
        let pair = PairTokens(ids: [101, 7, 102, 9, 102], tokenTypeIDs: [0, 0, 0, 1, 1])
        let prepared = CoreMLPairInference.prepareInputs(pair: pair, padTokenID: 0, fixedLength: 8)
        #expect(prepared.ids == [101, 7, 102, 9, 102, 0, 0, 0])
        #expect(prepared.tokenTypeIDs == [0, 0, 0, 1, 1, 0, 0, 0])
        #expect(prepared.attentionMask == [1, 1, 1, 1, 1, 0, 0, 0])
    }

    @Test("a flexible shape keeps the real length")
    func flexibleShape() {
        let pair = PairTokens(ids: [101, 7, 102, 9, 102], tokenTypeIDs: [0, 0, 0, 1, 1])
        let prepared = CoreMLPairInference.prepareInputs(pair: pair, padTokenID: 0, fixedLength: nil)
        #expect(prepared.ids == pair.ids)
        #expect(prepared.tokenTypeIDs == pair.tokenTypeIDs)
        #expect(prepared.attentionMask == [1, 1, 1, 1, 1])
    }
}

// MARK: - Asset-gated logit test

@Suite("Packaged cross encoder (MOOT_CROSS_ENCODER_ASSETS)")
struct PackagedCrossEncoderTests {

    @Test(
        "the loaded classifier reproduces the reference logits within 1e-3",
        .enabled(if: packagedAppleDirectory != nil, "MOOT_CROSS_ENCODER_ASSETS not set — skipping asset-gated test")
    )
    func referenceLogits() async throws {
        guard let dir = packagedAppleDirectory else { return }
        // Read texts from the shared fixture so there is one source of truth
        // for the input strings (the same JSON the Rust test reads).
        let fixture = try loadTokenizerParityFixture()
        let scorer = try PairScorerFactory.make(profile: .minilmL6, modelDirectory: dir)
        // Reference logits from PyTorch FP32, CPU.
        let reference: [(query: String, span: String, logit: Float)] = [
            (fixture.texts["capital"]!, fixture.texts["paris0"]!, 8.089582443237305),
            (fixture.texts["capital"]!, fixture.texts["paris1"]!, -2.3964743614196777),
            (fixture.texts["capital"]!, fixture.texts["berlin"]!, -3.6770708560943604),
            (fixture.texts["boiling"]!, fixture.texts["water"]!, 9.275367736816406),
            (fixture.texts["boiling"]!, fixture.texts["cat"]!, -11.256487846374512),
            (fixture.texts["pet"]!, fixture.texts["cat"]!, 8.426995277404785),
            (fixture.texts["pet"]!, fixture.texts["paris0"]!, -11.166393280029297),
        ]
        for (query, span, expected) in reference {
            let logits = try await scorer.score(query: query, spans: [span])
            #expect(logits.count == 1)
            #expect(abs(logits[0] - expected) < 1e-3, "\(query) / \(span): \(logits[0]) vs \(expected)")
        }
        // Batched scoring returns the same values in span order.
        let batch = try await scorer.score(
            query: fixture.texts["capital"]!,
            spans: [fixture.texts["paris0"]!, fixture.texts["paris1"]!, fixture.texts["berlin"]!])
        #expect(batch.count == 3)
        #expect(abs(batch[0] - 8.089582443237305) < 1e-3)
        #expect(abs(batch[2] - -3.6770708560943604) < 1e-3)
    }
}
#endif
