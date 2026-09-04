// NeuralEmbedProviderTests.swift
//
// Bare-minimum contract test for NeuralEmbedProvider — the Swift twin of
// the Rust tools/neural-embed backend (RENAME-EMBED #72).
//
// One test (crash-directive minimum): the twin produces a float vector
// of the expected dimension for a fixed string, under the engine-neutral
// model id "neural-embed-v1".
//
// ## Graceful skip
//
// Guards on `NLEmbedding.wordEmbedding(for: .english) != nil` and
// returns early when the OS model asset is absent (CI sandboxes that
// block on-device model downloads) — the same skip pattern as
// AppleNLProviderTests.
//
// Gated `#if canImport(NaturalLanguage)` — compiles to an empty file on
// Linux/Windows (sanctioned divergence; the Rust twin covers that side).

#if canImport(NaturalLanguage)
import NaturalLanguage
import Testing
import CorpusKit
import CorpusKitProviders
import EngramLib
import SynapseKit

@Suite("NeuralEmbedProvider — engine-neutral Swift twin")
struct NeuralEmbedProviderTests {

    /// Fixed string → non-empty vector whose dimension equals the OS
    /// word-embedding model's dimension, under model id "neural-embed-v1".
    @Test func fixedStringProducesExpectedDimensionVector() async throws {
        // Expected dimension comes from the OS model itself — the provider
        // mean-pools word vectors, so its output dimension MUST equal
        // NLEmbedding.wordEmbedding(for: .english).dimension.
        guard let osModel = NLEmbedding.wordEmbedding(for: .english) else {
            // OS asset absent — graceful skip (see file header).
            return
        }
        let provider = NeuralEmbedProvider()
        #expect(provider.modelID == "neural-embed-v1")

        let v = try await provider.embedFloat(
            "The estate coordinator provisions embedding providers at open time."
        )
        #expect(!v.isEmpty)
        #expect(v.count == osModel.dimension)
    }
}
#endif // canImport(NaturalLanguage)
