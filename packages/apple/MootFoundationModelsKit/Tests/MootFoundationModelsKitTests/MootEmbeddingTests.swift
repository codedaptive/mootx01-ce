import Testing
import Foundation
@testable import MootFoundationModelsKit

// MARK: - Embedding seam tests
//
// The provider protocol and its pure math are tested deterministically; the
// real NLContextualEmbedding adapter is exercised only when its model assets
// are on this machine (they download on demand — CI must not depend on them).

@Suite("MootEmbeddingProvider — the replaceable embedding lane seam")
struct MootEmbeddingTests {

    @Test("mean pooling averages token vectors component-wise")
    func meanPooling() {
        let pooled = ContextualEmbeddingProvider.meanPool([
            [1, 2, 3],
            [3, 4, 5],
        ])
        #expect(pooled == [2, 3, 4])
    }

    @Test("mean pooling of nothing is empty, not a crash or a zero-guess")
    func meanPoolingEmpty() {
        #expect(ContextualEmbeddingProvider.meanPool([]).isEmpty)
    }

    @Test("a mock provider round-trips through the protocol surface")
    func mockProvider() async throws {
        let provider: any MootEmbeddingProvider = MockEmbeddingProvider(dimension: 4)
        let vectors = try await provider.embed(["one", "two"])
        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { $0.count == provider.dimension })
        // Deterministic: same text, same vector.
        let again = try await provider.embed(["one"])
        #expect(again[0] == vectors[0])
    }

    @Test(
        "NLContextualEmbedding adapter embeds real text",
        .enabled(if: ContextualEmbeddingProvider.assetsAreAvailable()))
    func contextualEmbeddingLive() async throws {
        let provider = try ContextualEmbeddingProvider()
        let vectors = try await provider.embed(["the quick brown fox", "a memory drawer"])
        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { $0.count == provider.dimension && $0.count > 0 })
        #expect(vectors[0] != vectors[1], "different sentences must not collapse to one vector")
    }
}

/// Deterministic test double: hash-seeded unit-scale components.
private struct MockEmbeddingProvider: MootEmbeddingProvider {
    let identifier = "mock"
    let dimension: Int

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            (0..<dimension).map { i in
                Float((abs(text.hashValue &+ i) % 1000)) / 1000.0
            }
        }
    }
}
