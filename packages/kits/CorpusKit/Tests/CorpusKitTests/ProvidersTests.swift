// ProvidersTests.swift

import Testing
import CorpusKit
import CorpusKitProviders
import EngramLib

@Suite("Providers")
struct ProvidersTests {

    @Test func deterministicTokenizerEmptyInputProducesPad() {
        let t = DeterministicTokenizer()
        let tokens = t.tokenize("")
        #expect(tokens.count == 1)
        #expect(tokens.first == t.padTokenID)
    }

    @Test func deterministicTokenizerStableAcrossCalls() {
        let t = DeterministicTokenizer()
        let a = t.tokenize("hello world")
        let b = t.tokenize("hello world")
        #expect(a == b)
    }

    @Test func tokenizerTruncatesAtMaxTokens() {
        let t = DeterministicTokenizer(maxTokens: 5)
        let text = (0..<20).map { "word\($0)" }.joined(separator: " ")
        let tokens = t.tokenize(text)
        #expect(tokens.count == 5)
    }

    @Test func miniLMProviderProjectsToEngram() async throws {
        let provider = MiniLMTextProvider(inference: { _ in
            // 384-d pooled vector for the v1 MiniLM-L6 shape.
            Array(repeating: Float(0.1), count: 384)
        })
        let e1 = try await provider.embed("first text")
        let e2 = try await provider.embed("first text")
        #expect(e1 == e2, "same input must produce same engram")
    }

    @Test func providersHaveDistinctProjectionSeeds() async throws {
        let mini = MiniLMTextProvider(inference: { _ in Array(repeating: Float(0.5), count: 384) })
        let mpnet = MPNetTextProvider(inference: { _ in Array(repeating: Float(0.5), count: 768) })
        let e1 = try await mini.embed("test")
        let e2 = try await mpnet.embed("test")
        #expect(e1 != e2, "different providers must produce different engrams (seed difference)")
    }

    @Test func emptyStringReturnsZeroEngramAllProviders() async throws {
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

        #expect(m == Engram.zero, "MiniLM: empty input must return Engram.zero")
        #expect(p == Engram.zero, "MPNet: empty input must return Engram.zero")
        #expect(g == Engram.zero, "Gemma: empty input must return Engram.zero")
    }
}
