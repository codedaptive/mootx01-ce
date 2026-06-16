// EmbeddingProviderConformanceTests.swift — Swift leg of the
// cross-language bit-identity gate for the CorpusKitProviders text
// providers (B2-5: CorpusKit Rust embedding parity).
//
// The Rust port (rust-providers/src/text_providers.rs) ships the same
// MiniLM/mpnet/EmbeddingGemma providers Swift ships. This gate proves
// they are bit-identical for everything the kit owns: the
// DeterministicTokenizer token stream, and the full
// tokenize → inference-seam → SimHash-project → engram pipeline.
//
// What the kit does NOT own — the real WordPiece/SentencePiece
// tokenizers and the model inference pass — is host-supplied on BOTH
// ports (the Swift providers default to DeterministicTokenizer and
// take a host inference closure; so do the Rust providers). The
// embedding VALUES are therefore a property of the host's model
// bundle, not of either language port. To make the pipeline provable
// without a model bundle, this fixture uses a PURE inference function
// of the token IDs (`deterministicInference`) shared VERBATIM with the
// Rust leg. Both languages independently compute the identical pooled
// vector for the same token stream, so any divergence in the engram
// is a real projection/tokenizer drift, not model noise.
//
// Canonical generation: Swift is the canonical source. Run once with
// EMBEDDING_CONFORMANCE_EMIT set to the output path to regenerate
// Tests/SharedVectors/embedding_provider_vectors.json. The Rust leg
// (rust-providers/tests/embedding_conformance_tests.rs) reads the SAME
// file and asserts bit-for-bit equality.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import EngramLib
import SubstrateML
import VectorKit

@Suite("EmbeddingProviderConformance")
struct EmbeddingProviderConformanceTests {

    // MARK: - Shared deterministic inference seam
    //
    // Pure function of the token IDs. MUST be byte-identical to the
    // Rust `deterministic_inference` in the Rust leg. Builds a `dim`-
    // dimensional f32 vector where each coordinate folds the token IDs
    // with the coordinate index through the same integer arithmetic on
    // both ports, then scales into [-1, 1]. No floating-point
    // transcendental functions are used so the two ports cannot
    // diverge on libm differences — only exact i64/f32 arithmetic.
    static func deterministicInference(tokens: [Int32], dim: Int) -> [Float] {
        var out = [Float](repeating: 0, count: dim)
        for d in 0..<dim {
            // Fold every token id into coordinate d. UInt64 wrapping
            // arithmetic is identical Swift/Rust; the multiplier is an
            // arbitrary odd constant shared with the Rust leg.
            var acc: UInt64 = 0x9E37_79B9_7F4A_7C15 &* UInt64(d &+ 1)
            for t in tokens {
                // Token ids are non-negative (>= 0 from the tokenizer);
                // bitpattern into UInt64 is exact for that range.
                acc = (acc &* 1099511628211) &+ UInt64(UInt32(bitPattern: t))
            }
            // Reduce to a 16-bit residue, then map to [-1, 1] via exact
            // f32 division by 32768. Both ports compute the same i32
            // numerator and the same divisor, so the f32 result is bit-
            // identical.
            let residue = Int32(acc % 65536) - 32768
            out[d] = Float(residue) / Float(32768)
        }
        return out
    }

    // MARK: - Fixture inputs
    //
    // Shared VERBATIM with the Rust leg. Covers empty input (engram
    // zero contract), single token, multi-token, punctuation, and a
    // long input that exercises max-token truncation on the small-
    // maxTokens deterministic tokenizers.
    static let inputs: [String] = [
        "",
        "hello",
        "hello world",
        "The quick brown fox jumps over the lazy dog.",
        "embedding parity across swift and rust",
        "punctuation, semicolons; and — dashes! matter?",
        String(repeating: "token ", count: 200),
    ]

    // MARK: - Provider descriptors
    //
    // Identity, pooled dimensionality, and default tokenizer params for
    // each named provider, shared VERBATIM with the Rust leg. The
    // provider value itself is constructed inside `buildCanonical` so no
    // non-Sendable closure is held in a static (Swift 6 strict
    // concurrency).

    enum ProviderKind: String, CaseIterable {
        case minilm
        case mpnet
        case embeddingGemma = "embedding-gemma"

        var dim: Int { self == .minilm ? 384 : 768 }
        var vocabID: String {
            switch self {
            case .minilm: return "minilm-l6-v2"
            case .mpnet: return "mpnet-base"
            case .embeddingGemma: return "embedding-gemma-300m"
            }
        }
        var vocabSize: Int32 { self == .embeddingGemma ? 256_000 : 30_522 }
        var maxTokens: Int { self == .embeddingGemma ? 2048 : 128 }

        func makeProvider(
            inference: @escaping @Sendable ([Int32]) async throws -> [Float]
        ) -> any EmbeddingProvider {
            switch self {
            case .minilm: return MiniLMTextProvider(inference: inference)
            case .mpnet: return MPNetTextProvider(inference: inference)
            case .embeddingGemma: return EmbeddingGemmaProvider(inference: inference)
            }
        }
    }

    // MARK: - Canonical model

    struct TokenizerVector: Codable {
        let provider: String
        let input: String
        let tokens: [Int32]
    }

    struct EngramVector: Codable {
        let provider: String
        let input: String
        // The four 64-bit blocks of the projected engram. Stored as
        // blocks (not a hex string) because both ports expose the
        // blocks directly: Swift `block0..3`, Rust `new(b0..b3)`.
        let block0: UInt64
        let block1: UInt64
        let block2: UInt64
        let block3: UInt64
        // The pooled float vector this engram was projected from,
        // serialised as IEEE-754 bit patterns so the float lane is
        // checked exactly without decimal-rounding ambiguity.
        let floatBits: [UInt32]
    }

    struct CanonicalFile: Codable {
        let tokenizerVectors: [TokenizerVector]
        let engramVectors: [EngramVector]
    }

    // MARK: - Builder

    /// Build the canonical vectors from the live Swift providers. Used
    /// both by the emitter and the production-matches-canonical check.
    static func buildCanonical() async throws -> CanonicalFile {
        var tokVectors: [TokenizerVector] = []
        var engVectors: [EngramVector] = []

        for kind in ProviderKind.allCases {
            let dim = kind.dim
            let inference: @Sendable ([Int32]) async throws -> [Float] = { toks in
                deterministicInference(tokens: toks, dim: dim)
            }
            let provider = kind.makeProvider(inference: inference)

            // Tokenizer leg: tokenize each non-empty input via the
            // provider's default DeterministicTokenizer. (Empty input
            // is covered by the engram zero contract, not a token
            // stream — the providers short-circuit before tokenizing.)
            let tokenizer = DeterministicTokenizer(
                vocabID: kind.vocabID,
                vocabSize: kind.vocabSize,
                maxTokens: kind.maxTokens
            )
            for input in inputs where !input.isEmpty {
                tokVectors.append(
                    TokenizerVector(provider: kind.rawValue, input: input, tokens: tokenizer.tokenize(input)))
            }

            // Engram leg: full pipeline for every input including the
            // empty string (which must project to Engram.zero).
            for input in inputs {
                let engram = try await provider.embed(input)
                let floats = try await provider.embedFloat(input)
                engVectors.append(
                    EngramVector(
                        provider: kind.rawValue,
                        input: input,
                        block0: engram.block0,
                        block1: engram.block1,
                        block2: engram.block2,
                        block3: engram.block3,
                        floatBits: floats.map { $0.bitPattern }))
            }
        }
        return CanonicalFile(tokenizerVectors: tokVectors, engramVectors: engVectors)
    }

    // MARK: - Loading

    func loadCanonical() throws -> CanonicalFile {
        guard let url = Bundle.module.url(
            forResource: "embedding_provider_vectors",
            withExtension: "json",
            subdirectory: "SharedVectors")
        else {
            Issue.record("embedding_provider_vectors.json must ship under SharedVectors/")
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CanonicalFile.self, from: data)
    }

    // MARK: - Emitter (inert unless env var is set)

    /// One-shot canonical-file emitter. Disabled unless
    /// EMBEDDING_CONFORMANCE_EMIT is set; writes the canonical JSON to
    /// the path in that variable. Used ONCE to generate the checked-in
    /// vector file from the Swift leg (the canonical source). Never
    /// asserts, so it is inert in normal runs.
    @Test("emit canonical vectors when EMBEDDING_CONFORMANCE_EMIT is set")
    func emitCanonicalIfRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["EMBEDDING_CONFORMANCE_EMIT"],
              !path.isEmpty else { return }
        let file = try await Self.buildCanonical()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Production-matches-canonical

    @Test("production providers match the canonical embedding vectors")
    func productionMatchesCanonical() async throws {
        let canonical = try loadCanonical()
        let built = try await Self.buildCanonical()

        #expect(built.tokenizerVectors.count == canonical.tokenizerVectors.count)
        #expect(built.engramVectors.count == canonical.engramVectors.count)

        for (b, c) in zip(built.tokenizerVectors, canonical.tokenizerVectors) {
            #expect(b.provider == c.provider && b.input == c.input)
            #expect(b.tokens == c.tokens, "tokenizer drift for \(b.provider)/\(b.input)")
        }
        for (b, c) in zip(built.engramVectors, canonical.engramVectors) {
            #expect(b.provider == c.provider && b.input == c.input)
            #expect(
                b.block0 == c.block0 && b.block1 == c.block1
                    && b.block2 == c.block2 && b.block3 == c.block3,
                "engram drift for \(b.provider)/\(b.input)")
            #expect(b.floatBits == c.floatBits, "float-lane drift for \(b.provider)/\(b.input)")
        }
    }

    // MARK: - Empty-input zero contract (explicit)

    @Test("empty input projects to Engram.zero for every provider")
    func emptyInputIsZeroEngram() throws {
        let canonical = try loadCanonical()
        for v in canonical.engramVectors where v.input.isEmpty {
            #expect(v.block0 == 0 && v.block1 == 0 && v.block2 == 0 && v.block3 == 0,
                    "\(v.provider): empty input must be Engram.zero")
        }
    }
}
