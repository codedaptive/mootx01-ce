import XCTest
import EngramLib
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
@testable import VectorKit

/// Tests for `FloatSimHashEmbeddingProvider` — the concrete
/// EmbeddingProvider in VectorKit. Mirror of the Rust
/// simhash_provider_tests: model identity, determinism, distinct
/// seeds produce distinct engrams, inference-failure propagation,
/// and the empty-input contract (Engram.zero, closure not invoked).
final class FloatSimHashEmbeddingProviderTests: XCTestCase {

    /// Constant 384-dim vector standing in for MiniLM-shaped output.
    /// A static @Sendable closure so it can cross into the provider's
    /// @Sendable inference parameter without data-race diagnostics.
    private static let minilmInference: @Sendable (String) async throws -> [Float] = { _ in
        [Float](repeating: 0.1, count: 384)
    }

    func testModelIdentityFields() {
        let provider = FloatSimHashEmbeddingProvider(
            modelID: "minilm-v6",
            modelVersion: "1.0.0",
            projectionSeed: 0x4D49_4E4C_4D_5F76_31,
            inference: Self.minilmInference)
        XCTAssertEqual(provider.modelID, "minilm-v6")
        XCTAssertEqual(provider.modelVersion, "1.0.0")
    }

    func testEmbedIsDeterministicForSameText() async throws {
        let provider = FloatSimHashEmbeddingProvider(
            modelID: "minilm-v6",
            modelVersion: "1.0.0",
            projectionSeed: 0x4D49_4E4C_4D_5F76_31,
            inference: Self.minilmInference)
        let e1 = try await provider.embed("first text")
        let e2 = try await provider.embed("first text")
        XCTAssertEqual(e1, e2, "same input must produce the same engram")
    }

    func testDifferentSeedsProduceDifferentEngrams() async throws {
        let mini = FloatSimHashEmbeddingProvider(
            modelID: "minilm-v6", modelVersion: "1.0.0",
            projectionSeed: 0x4D49_4E4C_4D_5F76_31,
            inference: { _ in [Float](repeating: 0.5, count: 768) })
        let mpnet = FloatSimHashEmbeddingProvider(
            modelID: "mpnet-base-v2", modelVersion: "1.0.0",
            projectionSeed: 0x4D50_4E45_54_5F76_31,
            inference: { _ in [Float](repeating: 0.5, count: 768) })
        let eMini = try await mini.embed("test")
        let eMPNet = try await mpnet.embed("test")
        XCTAssertNotEqual(eMini, eMPNet,
                          "different projection seeds must produce different engrams")
    }

    func testInferenceFailurePropagates() async throws {
        struct InferenceError: Error {}
        let provider = FloatSimHashEmbeddingProvider(
            modelID: "broken", modelVersion: "0.0.0",
            projectionSeed: 0xCAFE,
            inference: { _ in throw InferenceError() })
        do {
            _ = try await provider.embed("anything")
            XCTFail("expected inference failure to propagate")
        } catch is InferenceError {
            // expected
        }
    }

    /// Empty input returns the substrate's canonical zero engram per
    /// the EmbeddingProvider contract.
    func testEmptyInputReturnsZeroEngram() async throws {
        let provider = FloatSimHashEmbeddingProvider(
            modelID: "minilm-v6", modelVersion: "1.0.0",
            projectionSeed: 0x4D49_4E4C_4D_5F76_31,
            inference: Self.minilmInference)
        let engram = try await provider.embed("")
        XCTAssertEqual(engram, Engram.zero)
    }

    /// The empty-input shortcut bypasses the inference closure
    /// entirely: a provider whose closure always throws still returns
    /// Engram.zero for the empty string.
    func testEmptyInputDoesNotInvokeInference() async throws {
        struct ShouldNotRun: Error {}
        let provider = FloatSimHashEmbeddingProvider(
            modelID: "guarded", modelVersion: "1.0.0",
            projectionSeed: 0xBEEF,
            inference: { _ in throw ShouldNotRun() })
        let engram = try await provider.embed("")
        XCTAssertEqual(engram, Engram.zero,
                       "empty input must bypass the inference closure")
    }

    /// Default `embedBatch` impl iterates `embed` sequentially.
    /// Verify count preservation, empty-entry contract (`Engram.zero`
    /// per the trait contract), and that non-empty entries return
    /// non-zero engrams. Symmetric to the Rust
    /// `embed_batch_default_impl_handles_mixed_empty_and_non_empty`.
    func testEmbedBatchDefaultImplHandlesMixedEmptyAndNonEmpty() async throws {
        let provider = FloatSimHashEmbeddingProvider(
            modelID: "minilm-v6", modelVersion: "1.0.0",
            projectionSeed: 0x4D49_4E4C_4D_5F76_31,
            inference: Self.minilmInference)

        // Empty input array -> empty output.
        let empty = try await provider.embedBatch([])
        XCTAssertTrue(empty.isEmpty)

        // Mixed array: count preserved, empty entries -> Engram.zero,
        // non-empty entries -> non-zero (constant inference vector
        // projects to a fixed non-zero engram).
        let texts = ["alpha", "", "beta", ""]
        let batch = try await provider.embedBatch(texts)
        XCTAssertEqual(batch.count, texts.count)
        XCTAssertNotEqual(batch[0], Engram.zero, "non-empty input must yield non-zero engram")
        XCTAssertEqual(batch[1], Engram.zero, "empty input must yield Engram.zero")
        XCTAssertNotEqual(batch[2], Engram.zero)
        XCTAssertEqual(batch[3], Engram.zero)
        XCTAssertEqual(batch[0], batch[2], "constant inference -> two non-empty inputs project identically")
    }
}
