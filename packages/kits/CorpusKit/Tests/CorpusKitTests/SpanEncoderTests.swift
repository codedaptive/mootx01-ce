// SpanEncoderTests.swift
//
// The span encoder over a fake inference closure, the factory's failure
// contract, and the WordPiece tokenizer the factory builds.
//
// Failure modes: a prefix that is not applied (the closure would see the
// bare text's ids), a vector returned without L2 normalisation, a batch
// boundary that drops or reorders spans, a factory throw of the wrong
// class (the lifecycle's one log line would then name the wrong cause),
// and a WordPiece split that disagrees with the reference tokenizer.

import Testing
import Foundation
import SynapseKit
@testable import CorpusKit
@testable import CorpusKitProviders

/// Records every token-id array the fake inference closure receives.
private actor TokenRecorder {
    var seen: [[Int32]] = []
    func record(_ ids: [Int32]) { seen.append(ids) }
}

/// A pooled vector derived from the ids so two different inputs differ and
/// the raw vector is NOT unit-length (norm is checked after encoding).
private func fakePooled(_ ids: [Int32], dim: Int) -> [Float] {
    (0..<dim).map { d in Float((Int(ids[d % ids.count]) % 13) + 1 + d) }
}

private func norm(_ v: [Float]) -> Float {
    v.reduce(0) { $0 + $1 * $1 }.squareRoot()
}

private func spec(dim: Int, queryPrefix: String, docPrefix: String) -> EncoderModelSpec {
    EncoderModelSpec(
        modelID: "fake-w60", modelVersion: "0", dim: dim,
        queryPrefix: queryPrefix, docPrefix: docPrefix, pooling: .mean,
        tokenizerHash: "", windowWords: 60, overlapDivisor: 2, maxSpans: 32, maxSequence: 128)
}

@Suite("ProviderSpanEncoder over a fake inference closure")
struct SpanEncoderFakeInferenceTests {

    @Test("encodeQuery applies the query prefix and returns a unit vector")
    func queryPrefixAndNorm() async throws {
        let recorder = TokenRecorder()
        let tokenizer = DeterministicTokenizer()
        let provider = MiniLMTextProvider(
            modelID: "fake-w60", modelVersion: "0", tokenizer: tokenizer,
            inference: { ids in await recorder.record(ids); return fakePooled(ids, dim: 8) })
        let encoder = ProviderSpanEncoder(
            spec: spec(dim: 8, queryPrefix: "query: ", docPrefix: "passage: "),
            inference: EmbeddingProviderSpanInference(provider), batchSize: 2)

        let vector = try await encoder.encodeQuery("painting in brazil")
        #expect(vector.count == 8)
        #expect(abs(norm(vector) - 1) < 1e-5)
        // The closure must have seen the ids of the PREFIXED text.
        #expect(await recorder.seen == [tokenizer.tokenize("query: painting in brazil")])
        #expect(await recorder.seen.first != tokenizer.tokenize("painting in brazil"))
    }

    @Test("encodeSpans prefixes every span, keeps order across batch boundaries, normalises each")
    func spansPrefixOrderAndNorm() async throws {
        let recorder = TokenRecorder()
        let tokenizer = DeterministicTokenizer()
        let provider = MiniLMTextProvider(
            modelID: "fake-w60", modelVersion: "0", tokenizer: tokenizer,
            inference: { ids in await recorder.record(ids); return fakePooled(ids, dim: 8) })
        let encoder = ProviderSpanEncoder(
            spec: spec(dim: 8, queryPrefix: "query: ", docPrefix: "passage: "),
            inference: EmbeddingProviderSpanInference(provider), batchSize: 2)

        let spans = ["one two", "three four", "five"]      // 3 spans, batch 2 → 2 + 1
        let vectors = try await encoder.encodeSpans(spans)
        #expect(vectors.count == 3)
        for v in vectors { #expect(abs(norm(v) - 1) < 1e-5) }
        #expect(await recorder.seen == spans.map { tokenizer.tokenize("passage: " + $0) })
        // Distinct spans → distinct vectors (the fake keys off the ids).
        #expect(vectors[0] != vectors[1])
    }

    @Test("an empty span encodes to the zero vector, not a throw")
    func emptySpanIsZero() async throws {
        let provider = MiniLMTextProvider(
            modelID: "fake-w60", modelVersion: "0",
            inference: { ids in fakePooled(ids, dim: 8) })
        let encoder = ProviderSpanEncoder(
            spec: spec(dim: 8, queryPrefix: "", docPrefix: ""),
            inference: EmbeddingProviderSpanInference(provider))
        let vectors = try await encoder.encodeSpans([""])
        #expect(vectors == [[Float](repeating: 0, count: 8)])
    }

    @Test("a seam vector of the wrong dimension is inferenceFailed")
    func dimensionMismatchThrows() async {
        let provider = MiniLMTextProvider(
            modelID: "fake-w60", modelVersion: "0",
            inference: { ids in fakePooled(ids, dim: 8) })
        let encoder = ProviderSpanEncoder(
            spec: spec(dim: 9, queryPrefix: "", docPrefix: ""),
            inference: EmbeddingProviderSpanInference(provider))
        await #expect(throws: EncoderError.self) {
            _ = try await encoder.encodeQuery("x")
        }
    }
}

@Suite("SpanEncoderFactory — failure contract")
struct SpanEncoderFactoryTests {

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc-factory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("missing model directory is modelUnavailable")
    func missingDirectory() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc-factory-missing-\(UUID().uuidString)")
        do {
            _ = try await SpanEncoderFactory.make(spec: .floor, modelDirectory: missing)
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
    func hashMismatch() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vocab = Data("[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n".utf8)
        try vocab.write(to: dir.appendingPathComponent("vocab.txt"))
        do {
            _ = try await SpanEncoderFactory.make(spec: .floor, modelDirectory: dir)
            Issue.record("factory must throw on a hash mismatch")
        } catch let error as EncoderError {
            #expect(error == .tokenizerMismatch(
                expected: EncoderModelSpec.floor.tokenizerHash,
                actual: SpanEncoderFactory.hexDigest(of: vocab)))
        } catch {
            Issue.record("expected EncoderError, got \(error)")
        }
    }

    @Test("matching vocab hash but no compiled model is modelUnavailable (hash check runs first)")
    func matchingHashNoModel() async throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vocab = Data("[PAD]\n[UNK]\n[CLS]\n[SEP]\nhello\n".utf8)
        try vocab.write(to: dir.appendingPathComponent("vocab.txt"))
        let matching = EncoderModelSpec(
            modelID: "fake-w60", modelVersion: "0", dim: 384, queryPrefix: "", docPrefix: "",
            pooling: .mean, tokenizerHash: SpanEncoderFactory.hexDigest(of: vocab),
            windowWords: 60, overlapDivisor: 2, maxSpans: 32, maxSequence: 256)
        do {
            _ = try await SpanEncoderFactory.make(spec: matching, modelDirectory: dir)
            Issue.record("factory must throw when no model file exists")
        } catch let error as EncoderError {
            guard case .modelUnavailable = error else {
                Issue.record("expected modelUnavailable, got \(error)"); return
            }
        } catch {
            Issue.record("expected EncoderError, got \(error)")
        }
    }

    @Test("hexDigest is lowercase SHA-256 hex")
    func hexDigestKnownAnswer() {
        // sha256("abc") — the FIPS 180 known answer.
        #expect(SpanEncoderFactory.hexDigest(of: Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite("WordPieceTokenizer")
struct WordPieceTokenizerTests {

    private let vocab = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "hello", "world", "##ing", "play", "!"]

    @Test("greedy longest match with ## continuation, [CLS]/[SEP] framing, punctuation split")
    func referenceSplit() throws {
        let tokenizer = try WordPieceTokenizer(vocabularyLines: vocab, vocabID: "t", maxTokens: 32)
        #expect(tokenizer.tokenize("Hello playing world!") == [2, 4, 7, 6, 5, 8, 3])
    }

    @Test("accents are stripped and an undecomposable word is [UNK]")
    func accentsAndUnknown() throws {
        let tokenizer = try WordPieceTokenizer(vocabularyLines: vocab, vocabID: "t", maxTokens: 32)
        #expect(tokenizer.tokenize("héllo zzz") == [2, 4, 1, 3])
    }

    @Test("truncation keeps [SEP] and fits maxTokens")
    func truncation() throws {
        let tokenizer = try WordPieceTokenizer(vocabularyLines: vocab, vocabID: "t", maxTokens: 4)
        #expect(tokenizer.tokenize("hello world hello world") == [2, 4, 5, 3])
    }

    @Test("a vocabulary without the special tokens is rejected")
    func missingSpecials() {
        #expect(throws: CorpusKitError.self) {
            _ = try WordPieceTokenizer(vocabularyLines: ["hello", "world"], vocabID: "t", maxTokens: 8)
        }
    }
}
