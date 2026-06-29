// NLEmbeddingProviderTests.swift
//
// Tests for NLEmbeddingProvider and NLContextualEmbeddingProvider.
//
// These tests are gated `#if canImport(NaturalLanguage)` — they compile
// and run only on Apple platforms where the NaturalLanguage framework is
// available. On Linux/Windows they compile to an empty test file, which
// is the correct outcome: neither provider exists on those platforms, and
// their absence is the sanctioned Swift/Rust parity divergence recorded in
// ADR-019.
//
// ## Test strategy
//
// 1. Present path: when NLEmbedding.sentenceEmbedding(for: .english) is
//    non-nil (the English OS model is available — true on macOS 12+ in CI),
//    verify a real non-empty float vector is returned for sample text.
//
// 2. Absent path: when the model is nil for a language the OS doesn't ship
//    (we force-test via a near-zero-probability language code), verify that
//    embedFloat returns [] and embed returns .zero — the graceful opt-out.
//
// 3. Empty-input contract: embedFloat("") returns [], embed("") returns .zero,
//    embedPair("") returns (.zero, []).
//
// 4. Vector properties: non-empty result is L2-normalised (magnitude ≈ 1.0).
//
// 5. ProjectionSeed isolation: NLEmbeddingProvider and NLContextualEmbeddingProvider
//    seeds are distinct (they key to separate storage buckets — invariant I-4).
//
// 6. NLContextualEmbedding availability-guard: when hasAvailableAssets is false
//    (the test machine may not have the asset downloaded), embedFloat returns []
//    gracefully — never crashes. This is the primary safety test for that provider.
//
// ADR-019 reference: Apple NL Embedding Providers.

#if canImport(NaturalLanguage)
import NaturalLanguage
import Testing
import CorpusKit
import CorpusKitProviders
import EngramLib

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NLEmbeddingProvider tests
// ─────────────────────────────────────────────────────────────────────────────

// The package minimum is macOS 26 / iOS 26, which is above the NLEmbedding
// availability floor (macOS 12 / iOS 15) — so no @available guard needed here.
@Suite("NLEmbeddingProvider")
struct NLEmbeddingProviderTests {

    // MARK: Model ID / Version / Seed

    @Test("modelID and modelVersion are canonical")
    func modelIDAndVersion() {
        let provider = NLEmbeddingProvider()
        #expect(provider.modelID == "apple-nlembedding-v1")
        #expect(provider.modelVersion == "1.0.0")
    }

    @Test("projection seed matches nlEmbeddingProjectionSeed constant")
    func projectionSeedConstant() {
        // The constant must encode "APNLEMB1" in ASCII. Verify numerically so
        // any accidental drift in the hex literal is immediately visible.
        #expect(nlEmbeddingProjectionSeed == 0x4150_4E4C_454D_4231)
    }

    @Test("seed isolation: NLEmbeddingProvider differs from NLContextualEmbeddingProvider")
    func seedIsolation() {
        // Two providers with distinct seeds key to different storage partitions
        // in the VectorStore (invariant I-4 of CORPUSKIT_SPEC). Verify they differ.
        #expect(nlEmbeddingProjectionSeed != nlContextualEmbeddingProjectionSeed)
    }

    // MARK: Empty-input contract

    @Test("embed empty string returns .zero")
    func embedEmptyString() async throws {
        let provider = NLEmbeddingProvider()
        let result = try await provider.embed("")
        #expect(result == .zero)
    }

    @Test("embedFloat empty string returns []")
    func embedFloatEmptyString() async throws {
        let provider = NLEmbeddingProvider()
        let result = try await provider.embedFloat("")
        #expect(result.isEmpty)
    }

    @Test("embedPair empty string returns (.zero, [])")
    func embedPairEmptyString() async throws {
        let provider = NLEmbeddingProvider()
        let (engram, floats) = try await provider.embedPair("")
        #expect(engram == .zero)
        #expect(floats.isEmpty)
    }

    // MARK: Present path (English model)

    @Test("embedFloat returns non-empty vector for English text when model available")
    func embedFloatEnglishPresent() async throws {
        // Guard on model availability — on machines without the English NL model
        // (unlikely on macOS 12+ but defensive), skip rather than fail.
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else {
            // The model is absent; the absent-lane contract is tested separately.
            return
        }
        let provider = NLEmbeddingProvider(language: .english)
        let floats = try await provider.embedFloat("The quick brown fox jumps over the lazy dog.")
        // When the model is present, we expect a real vector — not the opt-out empty.
        #expect(!floats.isEmpty, "expected a non-empty float vector for English text")
    }

    @Test("embedFloat result is L2-normalised (magnitude ≈ 1.0) when model available")
    func embedFloatIsNormalised() async throws {
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else { return }
        let provider = NLEmbeddingProvider(language: .english)
        let floats = try await provider.embedFloat("Natural language processing on device.")
        guard !floats.isEmpty else { return }
        // L2 magnitude: sqrt(sum(x^2)) should be ≈ 1.0 after normalisation.
        let magnitude = sqrt(floats.reduce(0) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1.0) < 1e-4,
                "expected L2-normalised vector, got magnitude \(magnitude)")
    }

    @Test("embed returns non-.zero Engram for English text when model available")
    func embedEnglishPresent() async throws {
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else { return }
        let provider = NLEmbeddingProvider(language: .english)
        let engram = try await provider.embed("Semantic search on Apple hardware.")
        #expect(engram != .zero, "expected a real Engram for embedded English text")
    }

    @Test("embedPair returns consistent engram and floats when model available")
    func embedPairConsistency() async throws {
        guard NLEmbedding.sentenceEmbedding(for: .english) != nil else { return }
        let provider = NLEmbeddingProvider(language: .english)
        let text = "Memory is the treasury and guardian of all things."
        let (pairEngram, pairFloats) = try await provider.embedPair(text)
        let floatEngram = try await provider.embed(text)
        // The Engram from embedPair must match the Engram from embed independently.
        // This verifies embedPair is not taking a shortcut that produces a different
        // projection result.
        #expect(pairEngram == floatEngram,
                "embedPair engram must equal embed(_:) result")
        let directFloats = try await provider.embedFloat(text)
        #expect(pairFloats.count == directFloats.count,
                "embedPair floats dimension must equal embedFloat(_:) result")
    }

    // MARK: Absent path (no model for language)

    @Test("embedFloat returns [] for unsupported language")
    func embedFloatAbsentLanguage() async throws {
        // Use a language code that the OS is extremely unlikely to have a sentence
        // embedding model for. We create a raw NLLanguage value for "zxx" (no
        // linguistic content / not applicable per ISO 639-2), which is not a
        // real natural language and will reliably have no NLEmbedding model.
        let nolangProvider = NLEmbeddingProvider(language: NLLanguage(rawValue: "zxx"))
        let floats = try await nolangProvider.embedFloat("some text that has no model")
        // The provider must opt out gracefully — not crash, not throw.
        #expect(floats.isEmpty,
                "expected [] for a language with no NLEmbedding model (graceful opt-out)")
    }

    @Test("embed returns .zero for unsupported language")
    func embedAbsentLanguage() async throws {
        let nolangProvider = NLEmbeddingProvider(language: NLLanguage(rawValue: "zxx"))
        let engram = try await nolangProvider.embed("some text that has no model")
        #expect(engram == .zero,
                "expected Engram.zero for a language with no NLEmbedding model")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NLContextualEmbeddingProvider tests
// ─────────────────────────────────────────────────────────────────────────────

// The package minimum is macOS 26 / iOS 26, which is above NLContextualEmbedding's
// availability floor (macOS 13 / iOS 16) — so no @available guard needed here.
@Suite("NLContextualEmbeddingProvider")
struct NLContextualEmbeddingProviderTests {

    // MARK: Model ID / Version / Seed

    @Test("modelID and modelVersion are canonical")
    func modelIDAndVersion() {
        let provider = NLContextualEmbeddingProvider()
        #expect(provider.modelID == "apple-nlcontextual-v1")
        #expect(provider.modelVersion == "1.0.0")
    }

    @Test("projection seed matches nlContextualEmbeddingProjectionSeed constant")
    func projectionSeedConstant() {
        // Must encode "APNLCTX1" in ASCII.
        #expect(nlContextualEmbeddingProjectionSeed == 0x4150_4E4C_4354_5831)
    }

    // MARK: Empty-input contract

    @Test("embed empty string returns .zero")
    func embedEmptyString() async throws {
        let provider = NLContextualEmbeddingProvider()
        let result = try await provider.embed("")
        #expect(result == .zero)
    }

    @Test("embedFloat empty string returns []")
    func embedFloatEmptyString() async throws {
        let provider = NLContextualEmbeddingProvider()
        let result = try await provider.embedFloat("")
        #expect(result.isEmpty)
    }

    @Test("embedPair empty string returns (.zero, [])")
    func embedPairEmptyString() async throws {
        let provider = NLContextualEmbeddingProvider()
        let (engram, floats) = try await provider.embedPair("")
        #expect(engram == .zero)
        #expect(floats.isEmpty)
    }

    // MARK: Graceful absent-lane behaviour (asset may not be downloaded)
    //
    // NLContextualEmbedding requires a downloadable asset. We CANNOT assume
    // the asset is present in CI. The core safety invariant is that the provider
    // NEVER crashes when the asset is absent — it simply opts out.

    @Test("embedFloat returns [] gracefully when asset is absent or unavailable")
    func embedFloatAbsentAsset() async throws {
        // Check whether the asset is actually available. If it is, the present-
        // path tests below will cover it. This test focuses on the absent path.
        let contextual = NLContextualEmbedding(language: .english)
        let assetAvailable = contextual?.hasAvailableAssets ?? false
        if assetAvailable {
            // The asset is present; skip the absent-path test (it would pass for
            // the wrong reason). The present-path tests below cover this machine.
            return
        }
        // Asset is absent — verify the opt-out contract holds.
        let provider = NLContextualEmbeddingProvider(language: .english)
        // Must not throw, must not crash.
        let floats = try await provider.embedFloat("Some sample text for contextual embedding.")
        #expect(floats.isEmpty,
                "expected [] when the contextual embedding asset is not downloaded")
    }

    @Test("embed returns .zero gracefully when asset is absent or unavailable")
    func embedAbsentAsset() async throws {
        let contextual = NLContextualEmbedding(language: .english)
        guard !(contextual?.hasAvailableAssets ?? false) else { return }
        let provider = NLContextualEmbeddingProvider(language: .english)
        let engram = try await provider.embed("Some sample text.")
        #expect(engram == .zero,
                "expected Engram.zero when the contextual embedding asset is not downloaded")
    }

    // MARK: Present path (only runs when asset is available)

    @Test("embedFloat returns non-empty vector when contextual asset is available")
    func embedFloatPresent() async throws {
        let contextual = NLContextualEmbedding(language: .english)
        guard contextual?.hasAvailableAssets == true else { return }
        let provider = NLContextualEmbeddingProvider(language: .english)
        let floats = try await provider.embedFloat("The transformer produces contextual token representations.")
        #expect(!floats.isEmpty, "expected a non-empty float vector when contextual asset is available")
    }

    @Test("embedFloat result is L2-normalised when contextual asset is available")
    func embedFloatIsNormalisedWhenPresent() async throws {
        let contextual = NLContextualEmbedding(language: .english)
        guard contextual?.hasAvailableAssets == true else { return }
        let provider = NLContextualEmbeddingProvider(language: .english)
        let floats = try await provider.embedFloat("Contextual embeddings capture token meaning in context.")
        guard !floats.isEmpty else { return }
        let magnitude = sqrt(floats.reduce(0) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1.0) < 1e-4,
                "expected L2-normalised contextual vector, got magnitude \(magnitude)")
    }

    @Test("embedPair returns consistent engram and floats when contextual asset is available")
    func embedPairConsistencyWhenPresent() async throws {
        let contextual = NLContextualEmbedding(language: .english)
        guard contextual?.hasAvailableAssets == true else { return }
        let provider = NLContextualEmbeddingProvider(language: .english)
        let text = "On-device transformer models for private, local semantic search."
        let (pairEngram, pairFloats) = try await provider.embedPair(text)
        let floatEngram = try await provider.embed(text)
        #expect(pairEngram == floatEngram, "embedPair engram must equal embed(_:) result")
        let directFloats = try await provider.embedFloat(text)
        #expect(pairFloats.count == directFloats.count,
                "embedPair floats dimension must equal embedFloat(_:) result")
    }

    // MARK: Absent language (no contextual model at all for the language)

    @Test("embedFloat returns [] for language with no contextual model")
    func embedFloatAbsentLanguage() async throws {
        // "zxx" (no linguistic content) has no NLContextualEmbedding model.
        let provider = NLContextualEmbeddingProvider(language: NLLanguage(rawValue: "zxx"))
        let floats = try await provider.embedFloat("any text")
        #expect(floats.isEmpty,
                "expected [] for a language with no NLContextualEmbedding model")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EmbeddingModel cases
// ─────────────────────────────────────────────────────────────────────────────

// Package minimum macOS 26 / iOS 26 — all NL APIs unconditionally available.
@Suite("EmbeddingModel — NL cases")
struct EmbeddingModelNLCasesTests {

    @Test("nlEmbedding case is not trainable (no TrainableEmbeddingBasis)")
    func nlEmbeddingNotTrainable() {
        let model = EmbeddingModel.nlEmbedding(provider: NLEmbeddingProvider())
        #expect(!model.isTrainable,
                "NLEmbeddingProvider is item-local; it must not report as trainable")
    }

    @Test("nlContextualEmbedding case is not trainable")
    func nlContextualEmbeddingNotTrainable() {
        let model = EmbeddingModel.nlContextualEmbedding(provider: NLContextualEmbeddingProvider())
        #expect(!model.isTrainable,
                "NLContextualEmbeddingProvider is item-local; it must not report as trainable")
    }

    @Test("nlEmbedding is not the default ensemble — default remains .deterministic")
    func defaultRemainsUnchanged() {
        // NL cases are opt-in. Verify the single-model fallback
        // EmbeddingModel.default is still .deterministic (not the
        // production CorpusEnsemble.defaultEnsemble() multi-signal ensemble).
        if case .deterministic = EmbeddingModel.default {
            // Correct.
        } else {
            Issue.record("EmbeddingModel.default must remain .deterministic after adding NL cases")
        }
    }
}
#endif // canImport(NaturalLanguage)
