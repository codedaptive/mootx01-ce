// FloatSimHashEmbeddingProvider.swift
//
// The concrete EmbeddingProvider for VectorKit. Swift mirror of the
// Rust vectorkit::FloatSimHashEmbeddingProvider.
//
// The provider holds a stable projection seed and an injectable
// inference closure that turns text into a dense [Float] vector. The
// closure result is fed through SubstrateML.FloatSimHash.project
// (the canonical SimHash projection, bit-identical Swift/Rust per
// the substrate conformance harness) to obtain the 256-bit Engram.
//
// VectorKit does not own tokenization, model bundles, or model
// identity. Concrete text providers that carry a tokenizer and a
// model-specific projection seed (MiniLM, mpnet, EmbeddingGemma)
// live in CorpusKitProviders and conform to VectorKit.EmbeddingProvider.
// This provider is the low-level "host supplies inference, kit
// supplies the canonical projection" building block.

import EngramLib
import Foundation
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

public struct FloatSimHashEmbeddingProvider: EmbeddingProvider {
    public let modelID: String
    public let modelVersion: String

    /// FloatSimHash hyperplane seed. Distinct seeds produce distinct
    /// fingerprints for the same float vector, which enforces spec
    /// I-4 (cross-model comparisons are forbidden) at the projection
    /// layer. The caller supplies the seed; model-specific seeds are
    /// owned by the CorpusKitProviders text providers.
    public let projectionSeed: UInt64

    /// Host-supplied inference. Wraps a CoreML / ONNX / other model
    /// that turns text into a dense float vector. Kept injectable so
    /// the kit stays testable without a model bundle.
    public let inference: @Sendable (String) async throws -> [Float]

    public init(
        modelID: String,
        modelVersion: String,
        projectionSeed: UInt64,
        inference: @escaping @Sendable (String) async throws -> [Float]
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.projectionSeed = projectionSeed
        self.inference = inference
    }

    public func embed(_ text: String) async throws -> Engram {
        // Empty-input contract from the EmbeddingProvider protocol:
        // every conformer returns the substrate's canonical zero
        // engram for the empty string. Short-circuit before invoking
        // the inference closure so the contract holds even when the
        // closure would otherwise hash empty input to a non-zero
        // vector.
        guard !text.isEmpty else { return Engram.zero }
        let floats = try await inference(text)
        // FloatSimHash.project returns a Fingerprint256; Engram is a
        // type alias for Fingerprint256. The canonical projection IS
        // the engram, so there is no reconstruction step.
        return FloatSimHash.project(vector: floats, seed: projectionSeed)
    }

    /// Return the pooled dense float vector — the float lane source.
    ///
    /// This is exactly the vector `embed(_:)` feeds into
    /// `FloatSimHash.project`; the inference closure is the model pass
    /// MiniLM/mpnet/EmbeddingGemma run. Returning it directly is the
    /// "retain, don't recompute" path: the float lane and the binary
    /// SimHash lane are two reads of one inference output. Empty input
    /// returns `[]` per the protocol contract (no dense direction for the
    /// empty string).
    public func embedFloat(_ text: String) async throws -> [Float] {
        guard !text.isEmpty else { return [] }
        return try await inference(text)
    }
}
