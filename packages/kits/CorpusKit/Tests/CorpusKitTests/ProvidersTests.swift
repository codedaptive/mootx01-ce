// ProvidersTests.swift

import XCTest
import CorpusKit
import CorpusKitProviders
import EngramLib

final class ProvidersTests: XCTestCase {

    func testDeterministicTokenizerEmptyInputProducesPad() {
        let t = DeterministicTokenizer()
        let tokens = t.tokenize("")
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first, t.padTokenID)
    }

    func testDeterministicTokenizerStableAcrossCalls() {
        let t = DeterministicTokenizer()
        let a = t.tokenize("hello world")
        let b = t.tokenize("hello world")
        XCTAssertEqual(a, b)
    }

    func testTokenizerTruncatesAtMaxTokens() {
        let t = DeterministicTokenizer(maxTokens: 5)
        let text = (0..<20).map { "word\($0)" }.joined(separator: " ")
        let tokens = t.tokenize(text)
        XCTAssertEqual(tokens.count, 5)
    }

    func testMiniLMProviderProjectsToEngram() async throws {
        let provider = MiniLMTextProvider(inference: { _ in
            // 384-d pooled vector for the v1 MiniLM-L6 shape.
            Array(repeating: Float(0.1), count: 384)
        })
        let e1 = try await provider.embed("first text")
        let e2 = try await provider.embed("first text")
        XCTAssertEqual(e1, e2, "same input must produce same engram")
    }

    func testProvidersHaveDistinctProjectionSeeds() async throws {
        let mini = MiniLMTextProvider(inference: { _ in Array(repeating: Float(0.5), count: 384) })
        let mpnet = MPNetTextProvider(inference: { _ in Array(repeating: Float(0.5), count: 768) })
        let e1 = try await mini.embed("test")
        let e2 = try await mpnet.embed("test")
        XCTAssertNotEqual(e1, e2, "different providers must produce different engrams (seed difference)")
    }

    func testEmptyStringReturnsZeroEngramAllProviders() async throws {
        // VectorKit.EmbeddingProvider contract: empty input MUST return
        // Engram.zero. The text providers short-circuit before invoking
        // the inference closure — a closure that throws unconditionally
        // must never be reached on empty input. Covers MiniLM, MPNet,
        // and EmbeddingGemma in one assertion set.
        struct InferenceShouldNotBeCalled: Error {}
        let throwing: @Sendable ([Int32]) async throws -> [Float] = { _ in
            throw InferenceShouldNotBeCalled()
        }

        let mini  = MiniLMTextProvider(inference: throwing)
        let mpnet = MPNetTextProvider(inference: throwing)
        let gemma = EmbeddingGemmaProvider(inference: throwing)

        let m = try await mini.embed("")
        let p = try await mpnet.embed("")
        let g = try await gemma.embed("")

        XCTAssertEqual(m, Engram.zero, "MiniLM: empty input must return Engram.zero")
        XCTAssertEqual(p, Engram.zero, "MPNet: empty input must return Engram.zero")
        XCTAssertEqual(g, Engram.zero, "Gemma: empty input must return Engram.zero")
    }
}
