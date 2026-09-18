// EncoderModelSpec.swift
//
// The value type that mirrors one `encoder_models` registry row (LocusKit
// schema 19). Everything the span encoder, the recall rerank stage and the
// `spanEncode` duty need to know about a sentence encoder travels in this
// struct: identity, geometry, prefixes, pooling, tokenizer provenance and the
// span windowing parameters. The registry row is the persisted form; this
// struct is the in-process form. Field names map one-to-one onto the row's
// columns (see `CodingKeys`), so a spec serialises like a row.
//
// Mirror: rust/src/encoder/spec.rs.

import Foundation

/// One shipped sentence encoder and its span-index geometry.
///
/// `modelID` carries the span unit (`<model>-w<windowWords>`), so two specs
/// that differ only in `windowWords` are two different indexes and are never
/// compared. `modelVersion` is the weights revision; a weights change is a
/// new version and a re-index.
public struct EncoderModelSpec: Sendable, Equatable, Codable {

    /// How the encoder collapses the token matrix into one vector.
    public enum Pooling: String, Sendable, Equatable, Codable {
        /// Attention-masked mean over the token positions.
        case mean
        /// The first (`[CLS]`) position.
        case cls
    }

    /// `<model>-w<window_words>`, e.g. `minilm-l6-v2-w60`.
    public let modelID: String
    /// Weights revision: HF revision short hash or the Apple asset version.
    public let modelVersion: String
    /// Output dimension of the pooled vector.
    public let dim: Int
    /// Text prepended to every query before encoding (`""` when the model
    /// card has none).
    public let queryPrefix: String
    /// Text prepended to every span before encoding (`""` when none).
    public let docPrefix: String
    /// Pooling the inference pass applies before L2 normalisation.
    public let pooling: Pooling
    /// SHA-256 hex digest of the vendored `vocab.txt`. The factory refuses to
    /// load a model directory whose vocab hashes differently.
    public let tokenizerHash: String
    /// Span window in words (`Spanner.words` units).
    public let windowWords: Int
    /// Overlap divisor: `step = windowWords / overlapDivisor` (2 = half overlap).
    public let overlapDivisor: Int
    /// Upper bound on spans per record; `Spanner.spans` widens the step to
    /// stay at or under it.
    public let maxSpans: Int
    /// Maximum token sequence the model accepts; the tokenizer truncates here.
    public let maxSequence: Int

    /// Column names of the `encoder_models` row, so an encoded spec is a row.
    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelVersion = "model_version"
        case dim
        case queryPrefix = "query_prefix"
        case docPrefix = "doc_prefix"
        case pooling
        case tokenizerHash = "tokenizer_hash"
        case windowWords = "window_words"
        case overlapDivisor = "overlap_divisor"
        case maxSpans = "max_spans"
        case maxSequence = "max_sequence"
    }

    /// Memberwise initialiser; every field is required because every field
    /// is a NOT NULL column.
    public init(
        modelID: String,
        modelVersion: String,
        dim: Int,
        queryPrefix: String,
        docPrefix: String,
        pooling: Pooling,
        tokenizerHash: String,
        windowWords: Int,
        overlapDivisor: Int,
        maxSpans: Int,
        maxSequence: Int
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.dim = dim
        self.queryPrefix = queryPrefix
        self.docPrefix = docPrefix
        self.pooling = pooling
        self.tokenizerHash = tokenizerHash
        self.windowWords = windowWords
        self.overlapDivisor = overlapDivisor
        self.maxSpans = maxSpans
        self.maxSequence = maxSequence
    }

    /// The floor model for all development: `sentence-transformers/all-MiniLM-L6-v2`
    /// at HF revision `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`, 384-d, mean
    /// pooling, no prefixes, 256-token maximum, 60-word spans with half
    /// overlap and at most 32 spans per record.
    ///
    /// `tokenizerHash` is `sha256(vocab.txt)` of that revision's vocabulary
    /// (the 30 522-entry uncased BERT vocabulary, 231 508 bytes), computed
    /// with `shasum -a 256` on the vendored file.
    public static let floor = EncoderModelSpec(
        modelID: "minilm-l6-v2-w60",
        modelVersion: "1110a243",
        dim: 384,
        queryPrefix: "",
        docPrefix: "",
        pooling: .mean,
        tokenizerHash: "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3",
        windowWords: 60,
        overlapDivisor: 2,
        maxSpans: 32,
        maxSequence: 256)
}
