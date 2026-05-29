import XCTest
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

final class EmbeddingProviderTests: XCTestCase {

    /// The mock type conforms to `EmbeddingProvider`. Compile-time
    /// guarantee plus a runtime existential check.
    func testMockConformsToProtocol() {
        let provider: any EmbeddingProvider = MockEmbeddingProvider()
        XCTAssertNotNil(provider)
    }

    /// Model identity fields are non-empty. Per spec I-4 these are
    /// part of every stored record; an empty value would corrupt the
    /// model-tagging contract.
    func testModelIdentityFieldsAreNonEmpty() {
        let provider = MockEmbeddingProvider()
        XCTAssertFalse(provider.modelID.isEmpty)
        XCTAssertFalse(provider.modelVersion.isEmpty)
    }

    /// `embed(_:)` returns an `Engram` for a normal input.
    func testEmbedReturnsEngram() async throws {
        let provider = MockEmbeddingProvider()
        let engram = try await provider.embed("hello world")
        // Non-empty input returns the mock's fixed non-zero engram.
        XCTAssertEqual(engram, Engram(blocks: 0xDEAD, 0xBEEF, 0xCAFE, 0xBABE))
    }

    /// Empty input returns the substrate's canonical zero engram.
    /// This is the cross-provider contract on EmbeddingProvider:
    /// empty strings collide on the same Hamming-distance-0 partition
    /// regardless of which provider produced them.
    func testEmbedEmptyStringReturnsZeroEngram() async throws {
        let provider = MockEmbeddingProvider()
        let engram = try await provider.embed("")
        XCTAssertEqual(engram, Engram.zero)
    }
}
