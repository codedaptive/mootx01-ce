import Testing
import SubstrateML
import EngramLib
@testable import VectorKit

/// Mock provider used to verify protocol conformance. Honors the
/// EmbeddingProvider empty-input contract: Engram.zero for the empty
/// string, a fixed non-zero engram otherwise. The concrete provider
/// is FloatSimHashEmbeddingProvider; this mock exists only to check
/// the protocol surface independent of the projection path.
private struct MockEmbeddingProvider: EmbeddingProvider {
    let modelID: String = "mock-v1"
    let modelVersion: String = "1.0.0"

    func embed(_ text: String) async throws -> Engram {
        // Empty-input contract: every conformer returns the
        // substrate's canonical zero engram for the empty string.
        guard !text.isEmpty else { return Engram.zero }
        return Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE)
    }
}

@Suite("EmbeddingProvider")
struct EmbeddingProviderTests {

    /// The mock type conforms to `EmbeddingProvider`. Compile-time
    /// guarantee plus a runtime existential check.
    @Test func testMockConformsToProtocol() {
        let provider: any EmbeddingProvider = MockEmbeddingProvider()
        #expect((provider as Any?) != nil)
    }

    /// Model identity fields are non-empty. Per spec I-4 these are
    /// part of every stored record; an empty value would corrupt the
    /// model-tagging contract.
    @Test func testModelIdentityFieldsAreNonEmpty() {
        let provider = MockEmbeddingProvider()
        #expect(!provider.modelID.isEmpty)
        #expect(!provider.modelVersion.isEmpty)
    }

    /// `embed(_:)` returns an `Engram` for a normal input.
    @Test func testEmbedReturnsEngram() async throws {
        let provider = MockEmbeddingProvider()
        let engram = try await provider.embed("hello world")
        // Non-empty input returns the mock's fixed non-zero engram.
        #expect(engram == Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE))
    }

    /// Empty input returns the substrate's canonical zero engram.
    /// This is the cross-provider contract on EmbeddingProvider:
    /// empty strings collide on the same Hamming-distance-0 partition
    /// regardless of which provider produced them.
    @Test func testEmbedEmptyStringReturnsZeroEngram() async throws {
        let provider = MockEmbeddingProvider()
        let engram = try await provider.embed("")
        #expect(engram == Engram.zero)
    }
}
