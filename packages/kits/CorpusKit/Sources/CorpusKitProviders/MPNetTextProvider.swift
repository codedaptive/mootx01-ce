// MPNetTextProvider.swift
//
// mpnet (all-mpnet-base-v2 style) embedding provider. 768-dim
// pooled vector; projection seed is mpnet-specific so engrams
// are distinct from MiniLM's. CoreML inference closure injected
// by the host app.
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

public struct MPNetTextProvider: EmbeddingProvider {
    public let modelID: String
    public let modelVersion: String
    public let tokenizer: any Tokenizer
    public let projectionSeed: UInt64

    public let inference: @Sendable ([Int32]) async throws -> [Float]

    public init(
        modelID: String = "mpnet-base-v2",
        modelVersion: String = "1.0.0",
        tokenizer: any Tokenizer = DeterministicTokenizer(vocabID: "mpnet-base"),
        projectionSeed: UInt64 = 0x4D50_4E45_54_5F76_31,  // "MPNET_v1"
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
