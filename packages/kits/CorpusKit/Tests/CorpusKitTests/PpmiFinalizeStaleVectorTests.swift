#if MOOTX01_DENSE_FAMILIES
// Dense-family test — compiled only when DenseFamilies trait is on.
// Off by default (plan 70BC55F3, 2026-09-05). See Package.swift.
// PpmiFinalizeStaleVectorTests.swift
//
// Finding D — D-CT-01: PpmiProvider.finalize() must clear ppmiVectors
// unconditionally so finalizing from empty counts yields an empty serving
// basis rather than preserving vectors from the previous finalization.
//
// Production path exercised: restoreCounts(from:) with an empty counts blob
// followed by finalizeFromCounts() — the same sequence the counts-path
// reindex runs after all content is deleted.
//
// Uses ppmiVector(forTerm:) and vocabularySize (both synchronous) instead of
// the async embed path, so these tests run without a concurrency harness.

import Testing
import Foundation
import CorpusKitProviders

@Suite("PpmiFinalizeStaleVectors")
struct PpmiFinalizeStaleVectorTests {

    /// A small corpus sufficient to produce at least one non-zero PPMI vector.
    private let corpus: [[String]] = [
        ["car", "engine", "drive", "road"],
        ["engine", "fuel", "power", "car"],
        ["dog", "bark", "fetch", "animal"],
        ["animal", "cat", "pet", "dog"],
    ]

    /// A term that is guaranteed to be in vocabulary after training above.
    /// Uses lowercase because finalize() stores lowercase keys.
    private let probeTerm = "car"

    // MARK: - Helpers

    /// Build and finalize a PpmiProvider trained on `corpus`.
    private func buildTrained() -> PpmiProvider {
        let provider = PpmiProvider()
        for doc in corpus {
            provider.train(terms: doc, window: ppmiWindow)
        }
        provider.finalize()
        return provider
    }

    /// Produce a valid empty counts blob by serializing a fresh provider
    /// that has never been trained. This is the same blob the counts-path
    /// reindex would write after all sources have been removed.
    private func emptyCounts() -> Data {
        PpmiProvider().serializeCounts()
    }

    // MARK: - §1 Sanity: trained provider has a non-nil vector for probe term

    @Test("trained provider has non-nil PPMI vector for a corpus term")
    func trainedProviderHasNonNilVector() {
        let provider = buildTrained()
        let vec = provider.ppmiVector(forTerm: probeTerm)
        // ppmiVector returns nil for OOV terms or terms with all-zero weights;
        // "car" co-occurs selectively enough in the corpus above.
        #expect(vec != nil,
                "ppmiVector for '\(probeTerm)' must be non-nil after training")
        #expect(provider.vocabularySize > 0,
                "vocabularySize must be > 0 after training a non-empty corpus")
    }

    // MARK: - §2 Core invariant: finalizing from empty counts clears stale vectors

    @Test("D-CT-01: restoreCounts(empty) + finalizeFromCounts clears stale ppmiVectors")
    func finalizeFromEmptyCountsClearsStaleVectors() throws {
        // Step 1 — train and finalize; confirm the probe term has a vector.
        let provider = buildTrained()
        #expect(provider.ppmiVector(forTerm: probeTerm) != nil,
                "precondition: '\(probeTerm)' must have a vector before the reset")
        #expect(provider.vocabularySize > 0, "precondition: vocabularySize must be > 0")

        // Step 2 — reset to empty counts via the production path.
        // `restoreCounts(from:)` intentionally does NOT clear ppmiVectors
        // (the serving basis is restored separately from a basis blob). The
        // caller is expected to derive a fresh basis via `finalizeFromCounts()`.
        // When the counts are empty, the resulting basis must also be empty.
        let empty = emptyCounts()
        try provider.restoreCounts(from: empty)

        // Step 3 — finalize from the now-empty count state.
        _ = provider.finalizeFromCounts()

        // Step 4 — the provider must now report an empty vocabulary and return
        // nil for the previously-in-vocabulary term.  Preserving stale vectors
        // here would let deleted content keep answering embed calls, violating
        // the hard-delete contract.
        #expect(provider.vocabularySize == 0,
                "vocabularySize must be 0 after finalizeFromCounts on empty counts — stale vectors must not survive")
        #expect(provider.ppmiVector(forTerm: probeTerm) == nil,
                "ppmiVector for '\(probeTerm)' must be nil after finalizeFromCounts on empty counts")
    }

    // MARK: - §3 Idempotence: two finalizations on same non-empty counts are identical

    @Test("finalize() twice on the same non-empty counts is idempotent")
    func finalizeIdempotent() {
        let provider = buildTrained()
        let vocab1 = provider.vocabularySize
        let vec1 = provider.ppmiVector(forTerm: probeTerm)

        // Second finalize on the same counts.
        provider.finalize()

        let vocab2 = provider.vocabularySize
        let vec2 = provider.ppmiVector(forTerm: probeTerm)

        #expect(vocab1 == vocab2,
                "vocabularySize must be identical across two finalizations on the same counts")
        #expect(vec1 == vec2,
                "ppmiVector must be bit-identical across two finalizations on the same counts")
    }
}

#endif // MOOTX01_DENSE_FAMILIES
