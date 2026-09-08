// PairScorerFactoryTests.swift
//
// The factory's failure contract (same order as the span encoder factory),
// the CoreML input preparation for pairs, and, when the packaged assets are
// present, the loaded classifier's logits against the lab's reference
// fixture. Assets are never in git: set `MOOT_CROSS_ENCODER_ASSETS` to a
// build-all output root (with `apple/` and `linux/`) to enable the last
// suite; it skips otherwise.
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

@Suite("Packaged cross encoder (MOOT_CROSS_ENCODER_ASSETS)")
struct PackagedCrossEncoderTests {

    /// Reference logits from the lab fixture (PyTorch FP32, CPU).
    private static let reference: [(query: String, span: String, logit: Float)] = [
        (CrossEncoderFixture.capital, CrossEncoderFixture.paris0, 8.089582443237305),
        (CrossEncoderFixture.capital, CrossEncoderFixture.paris1, -2.3964743614196777),
        (CrossEncoderFixture.capital, CrossEncoderFixture.berlin, -3.6770708560943604),
        (CrossEncoderFixture.boiling, CrossEncoderFixture.water, 9.275367736816406),
        (CrossEncoderFixture.boiling, CrossEncoderFixture.cat, -11.256487846374512),
        (CrossEncoderFixture.pet, CrossEncoderFixture.cat, 8.426995277404785),
        (CrossEncoderFixture.pet, CrossEncoderFixture.paris0, -11.166393280029297),
    ]

    @Test("the loaded classifier reproduces the reference logits within 1e-3")
    func referenceLogits() async throws {
        guard let dir = packagedAppleDirectory else { return }
        let scorer = try PairScorerFactory.make(profile: .minilmL6, modelDirectory: dir)
        for (query, span, expected) in Self.reference {
            let logits = try await scorer.score(query: query, spans: [span])
            #expect(logits.count == 1)
            #expect(abs(logits[0] - expected) < 1e-3, "\(query) / \(span): \(logits[0]) vs \(expected)")
        }
        // Batched scoring returns the same values in span order.
        let batch = try await scorer.score(
            query: CrossEncoderFixture.capital,
            spans: [CrossEncoderFixture.paris0, CrossEncoderFixture.paris1, CrossEncoderFixture.berlin])
        #expect(batch.count == 3)
        #expect(abs(batch[0] - 8.089582443237305) < 1e-3)
        #expect(abs(batch[2] - -3.6770708560943604) < 1e-3)
    }
}
#endif
