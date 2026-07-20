// MiniLMTextProvider.swift
//
// MiniLM-L6 v2 text embedding provider. Pulls tokenization from
// the DeterministicTokenizer (the BERT WordPiece tokenizer ships
// in the v1.1 model-bundle mission per
// selectable embedding providers). Projection uses
// SubstrateML.FloatSimHash
// with a stable projection seed owned here in CorpusKitProviders so
// the two providers produce bit-identical engrams for the same
// pooled float vector.
//
// CoreML model loading is the host app's responsibility; this
// provider takes the loaded MLModel handle and an embedding
// closure so the kit stays testable without a model bundle.
//
// Conforms to VectorKit.EmbeddingProvider (the canonical embedding-
// provider abstraction). The tokenizer property is public, exposed
// for injection and testing; tokenization stays out of VectorKit's contract per the
// kit-graph design (port-maintenance isolation: VectorKit is pure
// compute, text/weights/tokenizer live outside it).

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

public struct MiniLMTextProvider: EmbeddingProvider {
    public let modelID: String
    public let modelVersion: String
    public let tokenizer: any Tokenizer
    public let projectionSeed: UInt64

    /// Closure that runs MiniLM inference on tokenized input and
    /// returns the pooled 384-dimensional float vector.
    public let inference: @Sendable ([Int32]) async throws -> [Float]

    public init(
        modelID: String = "minilm-v6",
        modelVersion: String = "1.0.0",
        tokenizer: any Tokenizer = DeterministicTokenizer(vocabID: "minilm-l6-v2"),
        projectionSeed: UInt64 = 0x4D49_4E4C_4D_5F76_31,  // "MINLM_v1"
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

    /// Float lane source (Lane D): the pooled 384-d vector this provider's
    /// `embed(_:)` already computes before throwing it away inside
    /// `FloatSimHash.project`. Returning it here lets the dense float lane
    /// rank by cosine over the true embedding — the answer-vs-question-echo
    /// case the 256-bit SimHash projection cannot separate. Empty input
    /// returns `[]` (no dense direction for the empty string), matching the
    /// `EmbeddingProvider.embedFloat` contract. One inference pass feeds both
    /// the binary engram and this float vector.
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
