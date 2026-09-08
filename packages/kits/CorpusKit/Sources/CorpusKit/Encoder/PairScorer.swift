// PairScorer.swift
//
// The cross-encoder contract the retrieval-time rerank stage codes against,
// plus the one concrete scorer shape both ports ship: a `ProviderPairScorer`
// that runs a pair-logit inference seam in batches and checks that every
// span came back with exactly one finite logit.
//
// Logit values from a real model are allowed to differ by port (CoreML vs
// candle); the SHAPE of this contract is what the two ports keep identical.
// The scorer never sorts, never fuses and never truncates the span list:
// selection and fusion belong to the stage in GeniusLocusKit.
//
// Mirror: rust/src/encoder/pair_scorer.rs.

import Foundation

/// A cross encoder over (query, span) pairs.
///
/// `score` returns one finite relevance logit per span, in span order, so
/// `result.count == spans.count` always holds. An empty span list returns
/// an empty array without touching the model. Higher is more relevant; the
/// scale is the model's own and is only ever compared within one call.
public protocol PairScorer: Sendable {
    /// The packaged profile this scorer serves.
    var profile: CrossEncoderProfile { get }
    /// The inference runtime behind the scorer (`coreml`, `candle`, or a
    /// test double's own name); reported on every recall the stage runs.
    var backend: String { get }
    /// Score every `(query, span)` pair.
    func score(query: String, spans: [String]) async throws -> [Float]
}

/// The pair-logit inference seam a `ProviderPairScorer` drives.
///
/// Implementations tokenize each pair, run the classifier and return the
/// raw logit per span in input order. The seam is text-in so that the
/// tokenizer stays with the runtime that owns the vocabulary, exactly as
/// `SpanInference` does for the sentence encoder.
public protocol PairInference: Sendable {
    /// The runtime's name (`coreml`, `candle`, or a test double's own name).
    var backend: String { get }
    /// Raw logits for `spans` against `query`, one per span, same order.
    func logits(query: String, spans: [String]) async throws -> [Float]
}

/// The concrete pair scorer: profile + inference seam + batch size.
///
/// `score` slices its spans into `batchSize` chunks and hands each chunk to
/// the seam with the same query, so a pool of 30 candidates times 3 spans
/// never queues 90 pairs of tokens at once.
public struct ProviderPairScorer: PairScorer {
    public let profile: CrossEncoderProfile
    /// The pair-logit seam.
    public let inference: any PairInference
    /// Pairs per seam call; values below 1 act as 1.
    public let batchSize: Int

    /// Default `batchSize` when the caller supplies none: the lab's
    /// `batch_size` of 8, which held FP32 latency flat on CPU.
    public static let defaultBatchSize = 8

    /// Build a scorer for `profile` over `inference`.
    public init(profile: CrossEncoderProfile, inference: any PairInference, batchSize: Int = ProviderPairScorer.defaultBatchSize) {
        self.profile = profile
        self.inference = inference
        self.batchSize = batchSize
    }

    public var backend: String { inference.backend }

    public func score(query: String, spans: [String]) async throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(spans.count)
        let stride = max(1, batchSize)
        var index = 0
        while index < spans.count {
            let end = min(index + stride, spans.count)
            out += try await scoreBatch(query: query, spans: Array(spans[index..<end]))
            index = end
        }
        return out
    }

    /// One seam call. Count and finiteness are checked here so a mis-wired
    /// model fails loudly instead of fusing a NaN into the head order.
    private func scoreBatch(query: String, spans: [String]) async throws -> [Float] {
        let logits = try await inference.logits(query: query, spans: spans)
        guard logits.count == spans.count else {
            throw EncoderError.inferenceFailed(
                "\(profile.modelID): seam returned \(logits.count) logits for \(spans.count) pairs")
        }
        if let bad = logits.firstIndex(where: { !$0.isFinite }) {
            throw EncoderError.inferenceFailed(
                "\(profile.modelID): seam returned a non-finite logit at pair \(bad)")
        }
        return logits
    }
}
