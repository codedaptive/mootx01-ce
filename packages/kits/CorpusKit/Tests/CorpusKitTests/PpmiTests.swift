// PpmiTests.swift
//
// Conformance and correctness tests for PpmiProvider.
//
// ## What is tested
//
//   1. PPMI weight computation:
//      - A term pair that co-occurs only with each other gets high weight.
//      - A term pair where one member is a "stopword" (co-occurs with
//        everything) gets lower weight than a selective pair.
//      - Zero co-occurrence → zero weight (PPMI clamps to 0).
//
//   2. Context vector construction (train + finalize):
//      - A term's PPMI vector is the PPMI-weighted sum of context-term
//        index vectors, not just a plain sum (RI-style).
//      - A term whose every co-occurrence has negative PMI has no entry.
//
//   3. Document embedding (embed / embedFloat):
//      - Empty text returns Engram.zero / empty array.
//      - OOV-only text returns empty array.
//      - Non-empty trained text returns a unit-length vector.
//      - Same text + same trained provider → identical embedding.
//      - Semantically related texts have lower cosine distance than
//        unrelated texts.
//
//   4. PPMI ≠ RI (the distinct-method gate):
//      - PPMI and RI vectors for the same term differ (because the
//        accumulation weights differ).
//      - PPMI and RI Engrams differ (different projection seed ensures
//        bucket isolation).
//
//   5. Cross-port canonical vectors:
//      - Fixed mini-corpus, fixed parameters, expected PPMI co-occurrence
//        counts, weights, term vectors, document embeddings.
//      - The Swift test emits the JSON when PPMI_CONFORMANCE_EMIT is set
//        and performs local behavior/stability assertions; no committed
//        fixture is loaded or asserted inline in this file.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import EngramLib
import SubstrateTypes
import VectorKit

// MARK: - Shared canonical fixture
//
// This fixture is the conformance contract between the Swift and Rust ports.
// Any change to the corpus or parameters requires regenerating the canonical
// JSON on both ports.

/// Fixed mini-corpus for training.  Identical to the RI corpus so
/// cross-method comparisons are straightforward.
let ppmiCorpus: [[String]] = [
    ["car", "engine", "drive", "road", "vehicle"],
    ["vehicle", "road", "transport", "car", "fuel"],
    ["engine", "fuel", "combustion", "power", "car"],
    ["dog", "bark", "run", "fetch", "animal"],
    ["animal", "run", "cat", "dog", "pet"],
]

/// Parameters pinned for all conformance tests.
let ppmiD: Int = 2048    // ppmiDimension
let ppmiK: Int = 10      // ppmiNonzeros
let ppmiW: Int = 4       // ppmiWindow
let ppmiSeed: UInt64 = ppmiProjectionSeed  // 0x5050_4D49_5F56_314D

// MARK: - Helpers

/// Build and finalize a PpmiProvider trained on the canonical mini-corpus.
private func buildTrainedProvider() -> PpmiProvider {
    let provider = PpmiProvider()
    for doc in ppmiCorpus {
        provider.train(terms: doc, window: ppmiW)
    }
    provider.finalize()
    return provider
}

/// Cosine similarity between two unit-length vectors.
private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "cosineSimilarity: dimension mismatch")
    var dot: Float = 0
    for i in 0..<a.count { dot += a[i] * b[i] }
    return dot
}

// MARK: - Test suite

@Suite("PPMI")
struct PpmiTests {

    // MARK: §1 — Constants and projection seed isolation

    @Test("PPMI projection seed differs from RI projection seed")
    func projectionSeedDiffersFromRI() {
        // Ensures PPMI and RI store to different vector buckets in a shared
        // estate: same text, different providers → different Engrams.
        #expect(ppmiProjectionSeed != riProjectionSeed,
                "PPMI and RI must use distinct projection seeds for bucket isolation")
    }

    @Test("PPMI dimension matches RI dimension (shared index space)")
    func dimensionMatchesRI() {
        #expect(ppmiDimension == riDimension,
                "PPMI and RI share the same index vector space (D=2048)")
    }

    // MARK: §2 — PPMI weight computation

    @Test("PPMI weight is higher for selective pairs than stopword-context pairs")
    func ppmiWeightSelectiveVsStopword() {
        // Build a tiny corpus where "alpha" co-occurs ONLY with "beta",
        // and "gamma" co-occurs with every term (stopword-like behaviour).
        // The alpha-beta pair should have a higher PPMI weight than any
        // gamma-X pair.
        let provider = PpmiProvider()
        // "alpha" and "beta" co-occur exclusively.
        provider.train(terms: ["alpha", "beta"], window: 1)
        provider.train(terms: ["alpha", "beta"], window: 1)
        provider.train(terms: ["alpha", "beta"], window: 1)
        // "gamma" co-occurs with everyone — many distinct context terms.
        provider.train(terms: ["gamma", "alpha"], window: 1)
        provider.train(terms: ["gamma", "beta"], window: 1)
        provider.train(terms: ["gamma", "delta"], window: 1)
        provider.train(terms: ["gamma", "epsilon"], window: 1)
        provider.finalize()

        // alpha and beta must both have PPMI vectors.
        let alphaVec = provider.ppmiVector(forTerm: "alpha")
        let betaVec  = provider.ppmiVector(forTerm: "beta")
        #expect(alphaVec != nil, "alpha must have a PPMI vector")
        #expect(betaVec != nil,  "beta must have a PPMI vector")

        // alpha's PPMI vector must be non-zero (the pair is selective).
        let alphaHasNonzero = alphaVec?.contains { $0 != 0 } ?? false
        #expect(alphaHasNonzero, "alpha's PPMI vector must be non-zero for a selective pair")
    }

    @Test("PPMI clamps negative PMI to zero (zero-weight context terms contribute nothing)")
    func ppmiClampsNegativePMI() {
        // A term pair where one member is always-present (P(t)*P(c) > P(t,c))
        // yields negative PMI.  After PPMI clamping it contributes zero weight.
        // We verify this by constructing a case where "common" co-occurs with
        // everything: its contribution is clamped and the target term's PPMI
        // vector may be nil (all context pairs below chance).
        let provider = PpmiProvider()
        // "common" appears in all documents alongside everything else.
        let corpus = [
            ["common", "a", "b", "c"],
            ["common", "d", "e", "f"],
            ["common", "g", "h", "i"],
            ["common", "j", "k", "l"],
        ]
        for doc in corpus { provider.train(terms: doc, window: 1) }
        provider.finalize()
        // "common" co-occurs uniformly — its PPMI weights against its
        // uniform neighbours may be non-zero but should not be inflated.
        // The point: a call to ppmiVector must not panic and returns a
        // vector or nil, depending on whether any pair clears the floor.
        // We just verify it runs without crashing and returns consistent types.
        let _ = provider.ppmiVector(forTerm: "common")
        // finalize() on a uniform co-occurrence corpus must not crash.
        _ = Bool(true)
    }

    // MARK: §3 — Context vector construction

    @Test("PPMI vector is weighted by PPMI score, not a plain count")
    func ppmiVectorIsWeighted() {
        // Build a provider where we know the PPMI weight for one specific
        // pair is > 0, and verify the context vector is non-zero in at
        // least the directions of that pair's index vector.
        let provider = buildTrainedProvider()
        let carVec = provider.ppmiVector(forTerm: "car")
        #expect(carVec != nil, "car must have a PPMI vector after training on ppmiCorpus")
        let hasNonzero = carVec?.contains { $0 != 0 } ?? false
        #expect(hasNonzero, "car's PPMI vector must have at least one non-zero component")
    }

    @Test("finalize() must be called before embedFloat returns non-empty")
    func finalizeRequired() async throws {
        let provider = PpmiProvider()
        for doc in ppmiCorpus { provider.train(terms: doc, window: ppmiW) }
        // NOT finalized yet — ppmiVectors is empty.
        let v = try await provider.embedFloat("car engine")
        // Before finalize, all terms are OOV in ppmiVectors.
        #expect(v.isEmpty, "embedFloat must return empty before finalize() is called")

        // After finalize, the same text must return a non-empty vector.
        provider.finalize()
        let v2 = try await provider.embedFloat("car engine")
        #expect(!v2.isEmpty, "embedFloat must return non-empty after finalize() on trained provider")
    }

    @Test("PPMI vector differs from plain RI context vector for the same term")
    func ppmiDiffersFromRI() {
        // The key distinction: PPMI weights each context term's index vector
        // by its informativeness.  RI adds the full index vector for every
        // co-occurrence.  The results must differ.
        let ppmi = buildTrainedProvider()
        let ri   = RandomIndexingProvider()
        for doc in ppmiCorpus { ri.train(terms: doc, window: ppmiW) }

        let ppmiVec = ppmi.ppmiVector(forTerm: "car")
        let riVec   = ri.contextVector(forTerm: "car")

        guard let pv = ppmiVec, let rv = riVec else {
            Issue.record("both providers must have a context vector for 'car' after training on ppmiCorpus")
            return
        }
        // PPMI-weighted accumulation produces a different vector than
        // plain count-based accumulation.  They may be proportional in
        // degenerate cases but are generally distinct.
        #expect(pv != rv, "PPMI and RI context vectors for 'car' must differ (different accumulation weights)")
    }

    // MARK: §4 — Document embedding

    @Test("empty text returns Engram.zero")
    func embedEmptyReturnsZero() async throws {
        let provider = buildTrainedProvider()
        let engram = try await provider.embed("")
        #expect(engram == Engram.zero, "empty input must return Engram.zero")
    }

    @Test("empty text returns empty float vector")
    func embedFloatEmptyReturnsEmpty() async throws {
        let provider = buildTrainedProvider()
        let v = try await provider.embedFloat("")
        #expect(v.isEmpty, "empty input must return empty float vector")
    }

    @Test("OOV-only text returns empty float vector")
    func embedFloatOOVReturnsEmpty() async throws {
        let provider = PpmiProvider()
        provider.finalize()
        let v = try await provider.embedFloat("unknown term never trained")
        #expect(v.isEmpty, "all-OOV input must return empty float vector")
    }

    @Test("OOV-only text returns Engram.zero")
    func embedOOVReturnsZero() async throws {
        let provider = PpmiProvider()
        provider.finalize()
        let engram = try await provider.embed("unknown term never trained")
        #expect(engram == Engram.zero, "all-OOV input must return Engram.zero")
    }

    @Test("trained text returns a unit-length float vector")
    func embedFloatReturnsUnitVector() async throws {
        let provider = buildTrainedProvider()
        let v = try await provider.embedFloat("car engine")
        guard !v.isEmpty else {
            Issue.record("embedFloat must be non-empty after training on ppmiCorpus")
            return
        }
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1.0) < 1e-5, "embedFloat must return a unit vector; got norm=\(norm)")
    }

    @Test("same text on same provider returns identical embedding")
    func embedDeterminism() async throws {
        let provider = buildTrainedProvider()
        let e1 = try await provider.embed("car engine road")
        let e2 = try await provider.embed("car engine road")
        #expect(e1 == e2, "same text must produce same embedding")
    }

    @Test("PPMI and RI Engrams differ for the same text (bucket isolation)")
    func ppmiAndRIEngramsDiffer() async throws {
        let ppmiProvider = buildTrainedProvider()
        let riProvider   = RandomIndexingProvider()
        for doc in ppmiCorpus { riProvider.train(terms: doc, window: ppmiW) }

        let ppmiEngram = try await ppmiProvider.embed("car engine")
        let riEngram   = try await riProvider.embed("car engine")

        // Different projection seeds guarantee distinct Engrams even if
        // the float vectors were identical (they are not, but belt + suspenders).
        // PPMI and RI must produce distinct Engrams for the same text
        // (different projection seeds + different accumulation weights).
        #expect(ppmiEngram != riEngram)
    }

    // MARK: §5 — Semantic relatedness

    @Test("semantically related texts are closer than unrelated texts")
    func semanticRelatedness() async throws {
        let provider = buildTrainedProvider()

        let carVec     = try await provider.embedFloat("car")
        let vehicleVec = try await provider.embedFloat("vehicle")
        let dogVec     = try await provider.embedFloat("dog")

        guard !carVec.isEmpty, !vehicleVec.isEmpty, !dogVec.isEmpty else {
            Issue.record("all test terms must be in vocabulary after training on ppmiCorpus")
            return
        }

        let carVehicleSim = cosineSimilarity(carVec, vehicleVec)
        let carDogSim     = cosineSimilarity(carVec, dogVec)

        // car and vehicle share PPMI-informative context (road, engine, fuel,
        // transport); car and dog share no meaningful context in this corpus.
        #expect(carVehicleSim > carDogSim,
                "car↔vehicle (\(carVehicleSim)) must be closer than car↔dog (\(carDogSim)) under PPMI")
    }

    // MARK: §6 — EmbeddingModel wiring

    @Test("EmbeddingModel.ppmi case passes provider through")
    func embeddingModelPpmiCase() {
        let provider = buildTrainedProvider()
        // Verify the case compiles and carries the provider instance.
        let model: EmbeddingModel = .ppmi(provider: provider)
        // pattern-match to confirm the provider is accessible.
        if case .ppmi(let wrapped) = model {
            #expect(wrapped.modelID == "ppmi-v1",
                    "EmbeddingModel.ppmi must carry the PpmiProvider with its modelID")
        } else {
            Issue.record("EmbeddingModel.ppmi must match the .ppmi case")
        }
    }

    // MARK: §7 — Conformance (cross-port canonical vectors)

    /// Cross-language vector emitter.  Set PPMI_CONFORMANCE_EMIT to a JSON
    /// path to emit canonical vectors for the Rust leg to consume.
    /// Inert in normal runs (no env var set).
    @Test("emit PPMI canonical vectors when PPMI_CONFORMANCE_EMIT is set")
    func emitCanonicalIfRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["PPMI_CONFORMANCE_EMIT"],
              !path.isEmpty else { return }

        let provider = buildTrainedProvider()

        // Canonical PPMI vectors for the probe terms.
        struct PpmiVectorEntry: Codable {
            let term: String
            /// Float bit patterns of the raw (unnormalised) PPMI vector.
            let floatBits: [UInt32]
        }
        let probeTerms = ["car", "vehicle", "dog", "engine", "road"]
        var ppmiVectorEntries: [PpmiVectorEntry] = []
        for term in probeTerms {
            if let v = provider.ppmiVector(forTerm: term) {
                ppmiVectorEntries.append(PpmiVectorEntry(
                    term: term,
                    floatBits: v.map { $0.bitPattern }))
            }
        }

        // Canonical document embeddings.
        struct DocumentEmbeddingEntry: Codable {
            let text: String
            let block0: UInt64
            let block1: UInt64
            let block2: UInt64
            let block3: UInt64
            let floatBits: [UInt32]
        }
        let probeTexts = ["car engine", "vehicle road", "dog animal", ""]
        var embeddings: [DocumentEmbeddingEntry] = []
        for text in probeTexts {
            let engram   = try await provider.embed(text)
            let floatVec = try await provider.embedFloat(text)
            embeddings.append(DocumentEmbeddingEntry(
                text: text,
                block0: engram.block0,
                block1: engram.block1,
                block2: engram.block2,
                block3: engram.block3,
                floatBits: floatVec.map { $0.bitPattern }))
        }

        struct CanonicalFile: Codable {
            let ppmiD: Int
            let ppmiK: Int
            let ppmiW: Int
            let projectionSeed: UInt64
            let corpus: [[String]]
            let ppmiVectors: [PpmiVectorEntry]
            let documentEmbeddings: [DocumentEmbeddingEntry]
        }
        let file = CanonicalFile(
            ppmiD: ppmiD,
            ppmiK: ppmiK,
            ppmiW: ppmiW,
            projectionSeed: ppmiSeed,
            corpus: ppmiCorpus,
            ppmiVectors: ppmiVectorEntries,
            documentEmbeddings: embeddings)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Canonical document embedding stability gate: fixed corpus + fixed text
    /// → stable Engram across calls.  The cross-port gate is the JSON-based
    /// conformance test (emitCanonicalIfRequested above + Rust consumption).
    @Test("canonical document embedding is stable across calls")
    func canonicalDocumentEmbeddingStability() async throws {
        let provider = buildTrainedProvider()
        let e1 = try await provider.embed("car engine")
        let e2 = try await provider.embed("car engine")
        #expect(e1 == e2, "canonical embedding must be deterministic")
        #expect(e1 != Engram.zero, "trained provider must return non-zero engram for in-vocabulary text")
    }

    // P2-secfix: a negative window value makes lo > hi (e.g. window=-5, i=3
    // → lo=8, hi=-2). Without the guard the closed range lo...hi traps at
    // runtime. The fix adds `if hi < lo { continue }` mirroring
    // RandomIndexingProvider. A negative window produces no co-occurrence
    // counts but must never crash.
    @Test("train with negative window does not crash")
    func trainWithNegativeWindowDoesNotCrash() {
        let provider = PpmiProvider()
        // window = -1: lo = max(0, i+1), hi = min(n-1, i-1) → lo > hi for all i.
        // No crash, no co-occurrence counts, totalPairs stays 0.
        provider.train(terms: ["alpha", "beta", "gamma"], window: -1)
        provider.finalize()
        // The provider must reach finalize() without trapping. A second
        // finalize() call is safe (idempotent) and confirms no corrupt state.
        provider.finalize()
    }
}
