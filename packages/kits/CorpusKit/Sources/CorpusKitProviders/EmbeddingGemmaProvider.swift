// EmbeddingGemmaProvider.swift
//
// EmbeddingGemma 300M provider. 768-dim pooled vector; the
// upstream model uses SentencePiece tokenization (different
// vocabulary structure from BERT WordPiece). For v1.0 this
// provider holds a DeterministicTokenizer stand-in matching
// the EmbeddingGemma vocab size; the real SentencePiece port
// lands when the model assets ship in the host bundle.
//
// Conforms to VectorKit.EmbeddingProvider. Tokenizer held as a
// private impl detail (see MiniLMTextProvider for the rationale).

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
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
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
}
