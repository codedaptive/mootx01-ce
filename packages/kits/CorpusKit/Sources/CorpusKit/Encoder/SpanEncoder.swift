// SpanEncoder.swift
//
// The encoder contract the recall rerank stage and the `spanEncode` duty
// code against, plus the one concrete encoder shape both ports ship: a
// `ProviderSpanEncoder` that applies the spec's prefixes, runs a pooled
// inference seam in batches and L2-normalises every vector through the
// substrate's conformance-gated `FloatVecOps.l2Normalize`.
//
// Float values from a real model are allowed to differ by port (CoreML vs
// candle); the SHAPE of this contract is what the two ports keep identical.
//
// Mirror: rust/src/encoder/span_encoder.rs.

import Foundation
import SubstrateKernel
import SynapseKit

/// Failure classes of building or running a span encoder.
public enum EncoderError: Error, Sendable, Equatable {
    /// No usable model at the resolved location: the directory, the vocab
    /// file or the compiled model is missing, or this build carries no
    /// inference runtime for the spec.
    case modelUnavailable(String)
    /// `sha256(vocab.txt)` in the model directory differs from
    /// `EncoderModelSpec.tokenizerHash`: the weights and the vocabulary the
    /// registry row describes would not agree, so nothing loads.
    case tokenizerMismatch(expected: String, actual: String)
    /// The assets are present and hash correctly but the runtime refused
    /// them (malformed weights, unsupported pooling, dimension disagreement).
    case loadFailed(String)
    /// The loaded model failed while encoding (runtime error, wrong output
    /// dimension, or a batch that came back with the wrong count).
    case inferenceFailed(String)
}

/// A sentence encoder over span text.
///
/// `encodeQuery` applies `spec.queryPrefix`; `encodeSpans` applies
/// `spec.docPrefix` to each span. Both return L2-normalised vectors of
/// `spec.dim` floats. An empty input string yields the all-zero vector of
/// `spec.dim` (no direction), never a throw.
public protocol SpanEncoder: Sendable {
    /// The registry row this encoder serves.
    var spec: EncoderModelSpec { get }
    /// Encode one query: prefix, pool, L2-normalise.
    func encodeQuery(_ text: String) async throws -> [Float]
    /// Encode spans in order: prefix each, pool, L2-normalise. Output count
    /// and order equal the input's.
    func encodeSpans(_ spans: [String]) async throws -> [[Float]]
}

/// The pooled-vector inference seam a `ProviderSpanEncoder` drives.
///
/// Implementations return one pooled (NOT yet normalised) vector per input
/// text, in input order. An empty text may return `[]`; the encoder maps it
/// to the zero vector. Everything else must be `spec.dim` floats.
public protocol SpanInference: Sendable {
    /// Pooled vectors for `texts`, one per text, same order.
    func pooledBatch(_ texts: [String]) async throws -> [[Float]]
}

/// `SpanInference` over any `EmbeddingProvider` whose `embedFloat` returns
/// the pooled vector (MiniLM, the NL providers).
///
/// Runs `embedFloat` once per text: the provider's own inference seam is
/// the batch unit, so there is no second batching layer to disagree with
/// the model's. Provider errors surface as `EncoderError.inferenceFailed`.
public struct EmbeddingProviderSpanInference<Provider: EmbeddingProvider>: SpanInference {
    /// The wrapped provider.
    public let provider: Provider

    /// Wrap `provider`.
    public init(_ provider: Provider) {
        self.provider = provider
    }

    public func pooledBatch(_ texts: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for text in texts {
            do {
                out.append(try await provider.embedFloat(text))
            } catch {
                throw EncoderError.inferenceFailed(
                    "\(provider.modelID): \(String(describing: error))")
            }
        }
        return out
    }
}

/// The concrete span encoder: spec + pooled inference seam + batch size.
///
/// `encodeSpans` slices its input into `batchSize` chunks and hands each
/// chunk to the seam; the manifest key `encoder_batch` (16 on iOS, 64
/// elsewhere) sets `batchSize` at activation so a phone never queues 64
/// spans of tokens at once.
public struct ProviderSpanEncoder: SpanEncoder {
    public let spec: EncoderModelSpec
    /// The pooled-vector seam.
    public let inference: any SpanInference
    /// Spans per seam call in `encodeSpans`; values below 1 act as 1.
    public let batchSize: Int

    /// Default `batchSize` when activation supplies none: the non-iOS
    /// `encoder_batch` default.
    public static let defaultBatchSize = 64

    /// Build an encoder for `spec` over `inference`.
    public init(spec: EncoderModelSpec, inference: any SpanInference, batchSize: Int = ProviderSpanEncoder.defaultBatchSize) {
        self.spec = spec
        self.inference = inference
        self.batchSize = batchSize
    }

    public func encodeQuery(_ text: String) async throws -> [Float] {
        try await encodeBatch([spec.queryPrefix + text])[0]
    }

    public func encodeSpans(_ spans: [String]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(spans.count)
        let stride = max(1, batchSize)
        var index = 0
        while index < spans.count {
            let end = min(index + stride, spans.count)
            out += try await encodeBatch(spans[index..<end].map { spec.docPrefix + $0 })
            index = end
        }
        return out
    }

    /// One seam call: pooled vectors in, unit vectors out. Dimension and
    /// count are checked here so a mis-wired model fails loudly instead of
    /// writing wrong-length rows.
    private func encodeBatch(_ texts: [String]) async throws -> [[Float]] {
        let pooled = try await inference.pooledBatch(texts)
        guard pooled.count == texts.count else {
            throw EncoderError.inferenceFailed(
                "\(spec.modelID): seam returned \(pooled.count) vectors for \(texts.count) texts")
        }
        return try pooled.map { vector in
            // Empty text has no direction: the zero vector dots to 0 against
            // every query and never wins a span.
            if vector.isEmpty { return [Float](repeating: 0, count: spec.dim) }
            guard vector.count == spec.dim else {
                throw EncoderError.inferenceFailed(
                    "\(spec.modelID): seam returned dim \(vector.count), spec dim \(spec.dim)")
            }
            return FloatVecOps.l2Normalize(vector)
        }
    }
}
