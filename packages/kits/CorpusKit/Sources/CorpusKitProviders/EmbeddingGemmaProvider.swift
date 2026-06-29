// EmbeddingGemmaProvider.swift
//
// EmbeddingGemma 300M provider. 768-dim pooled vector; the
// upstream model uses SentencePiece tokenization (different
// vocabulary structure from BERT WordPiece). For v1.0 this
// provider holds a DeterministicTokenizer stand-in matching
// the EmbeddingGemma vocab size; the real SentencePiece port
// lands in the v1.1 model-bundle mission
// (DECISION_EMBEDDING_INFERENCE_SEAM_2026-06-12).
//
// Conforms to VectorKit.EmbeddingProvider. The stored tokenizer
// property is public, matching the initializer's public injection seam.

import Foundation
import SubstrateTypes
import EngramLib
import CorpusKit
import VectorKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateML

public struct EmbeddingGemmaProvider: EmbeddingProvider {
    public let modelID: String
    public let modelVersion: String
    public let tokenizer: any Tokenizer
    public let projectionSeed: UInt64

    public let inference: @Sendable ([Int32]) async throws -> [Float]

    public init(
        modelID: String = "embedding-gemma-300m",
        modelVersion: String = "1.0.0",
        tokenizer: any Tokenizer = DeterministicTokenizer(
            vocabID: "embedding-gemma-300m",
            vocabSize: 256_000,
            maxTokens: 2048
        ),
        projectionSeed: UInt64 = 0x454D_4247_4D_5F76_31,  // "EMBGM_v1"
        inference: @escaping @Sendable ([Int32]) async throws -> [Float]
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.tokenizer = tokenizer
        self.projectionSeed = projectionSeed
        self.inference = inference
    }

    public func embed(_ text: String) async throws -> Engram {
        // EmbeddingProvider contract: empty input MUST return Engram.zero.
        guard !text.isEmpty else { return .zero }
        let tokens = tokenizer.tokenize(text)
        let pooled = try await inference(tokens)
        return FloatSimHash.project(vector: pooled, seed: projectionSeed)
    }

    /// Float lane source (Lane D): the pooled 768-d vector this provider's
    /// `embed(_:)` computes before projecting it to the 256-bit engram.
    /// Returning it here feeds the dense float lane's cosine ranking. Empty
    /// input returns `[]` per the `EmbeddingProvider.embedFloat` contract.
    /// One inference pass feeds both the binary engram and this float vector.
    public func embedFloat(_ text: String) async throws -> [Float] {
        guard !text.isEmpty else { return [] }
        let tokens = tokenizer.tokenize(text)
        return try await inference(tokens)
    }

    /// Single-pass override: run model inference ONCE, then derive BOTH outputs
    /// from the one pooled vector — the projected engram and the float-lane
    /// vector. This replaces the two independent `inference(_:)` calls that
    /// `embed` and `embedFloat` would each make (Corpus ingest needs both per
    /// chunk; for a real NN model that is the most expensive double-pass).
    /// Outputs are byte-identical to calling `embed` and `embedFloat`
    /// separately: empty input short-circuits before the seam returning
    /// `(.zero, [])`, the engram is `FloatSimHash.project(pooled)`, and the
    /// float row is `pooled`.
    public func embedPair(_ text: String) async throws -> (engram: Engram, floats: [Float]) {
        guard !text.isEmpty else { return (.zero, []) }
        let tokens = tokenizer.tokenize(text)
        let pooled = try await inference(tokens)
        return (FloatSimHash.project(vector: pooled, seed: projectionSeed), pooled)
    }
}
