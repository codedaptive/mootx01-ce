// CrossEncoderProfile.swift
//
// The value type that names one packaged cross encoder and the operating
// limits the retrieval-time rerank stage applies with it. A cross encoder
// scores (query, span) PAIRS to one relevance logit; it has no vector
// geometry, no pooling and no span index, so it is a sibling of
// `EncoderModelSpec`, not a variant of it. Nothing about a profile is
// persisted per estate: the packaged profile is fixed, and the estate
// manifest may lower the three pool limits (see GeniusLocusKit's
// `cross_encoder_pool`, `cross_encoder_head`, `cross_encoder_spans`).
//
// Mirror: rust/src/encoder/cross_encoder_profile.rs.

import Foundation

/// One packaged cross encoder and the limits the rerank stage runs it under.
///
/// `pool`, `head` and `spans` are the MAXIMA the stage accepts: at most
/// `pool` candidates enter the stage, at most the first `head` of them are
/// scored, at most `spans` spans per candidate are paired with the query.
/// The stage clamps a caller's or manifest's value to these; it never
/// raises them.
public struct CrossEncoderProfile: Sendable, Equatable, Codable {
    /// Packaged identity, e.g. `ms-marco-minilm-l6-cross-v1`. Names the
    /// model directory under `<configuration>/models/<modelID>/`.
    public let modelID: String
    /// Weights revision: HF revision short hash or the CoreML bundle version.
    public let modelVersion: String
    /// SHA-256 hex digest of the vendored `vocab.txt`; the factory refuses a
    /// model directory whose vocab hashes differently.
    public let tokenizerHash: String
    /// Maximum token sequence of the PAIR (`[CLS] q [SEP] s [SEP]`); the
    /// pair tokenizer truncates longest-first to this.
    public let maxSequence: Int
    /// Maximum candidates handed to the stage from the authorized final list.
    public let pool: Int
    /// Maximum candidates, counted from the front of the pool, that are scored.
    public let head: Int
    /// Maximum spans per scored candidate paired with the query.
    public let spans: Int
    /// The reciprocal-rank-fusion constant: `1/(rrfK + rank)` per rank list.
    public let rrfK: Int

    /// Column-style key names so a profile serialises like the lab's
    /// `profile.json` and the manifest's `cross_encoder_*` keys.
    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelVersion = "model_version"
        case tokenizerHash = "tokenizer_hash"
        case maxSequence = "max_sequence"
        case pool
        case head
        case spans
        case rrfK = "rrf_k"
    }

    /// Memberwise initialiser; every field is required.
    public init(
        modelID: String,
        modelVersion: String,
        tokenizerHash: String,
        maxSequence: Int,
        pool: Int,
        head: Int,
        spans: Int,
        rrfK: Int
    ) {
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.tokenizerHash = tokenizerHash
        self.maxSequence = maxSequence
        self.pool = pool
        self.head = head
        self.spans = spans
        self.rrfK = rrfK
    }

    /// Base name of the packaged model artifact: `<artifactName>.mlmodelc`
    /// on Apple platforms; the Rust runtime reads the fixed HF file triple
    /// instead and does not use it. Derived from `modelID` so a second
    /// packaged profile never collides with the first.
    public var artifactName: String {
        // `ms-marco-minilm-l6-cross-v1` → `MsMarcoMinilmL6CrossV1`
        modelID.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// The one qualified profile: `cross-encoder/ms-marco-MiniLM-L-6-v2` at
    /// HF revision `233902d25c440f23af6f7d6e94d2946bac0bee0a`, FP32, pair
    /// limit 512 tokens, pool 50 / head 30 / spans 3, RRF k = 60. These are
    /// the values the lab measured; they are not tuned here.
    ///
    /// `tokenizerHash` is `sha256(vocab.txt)` of that revision, which is the
    /// same 30 522-entry uncased BERT vocabulary the floor sentence encoder
    /// ships (`EncoderModelSpec.floor.tokenizerHash`).
    ///
    /// `modelVersion` remains the established short display value. Strict
    /// transcript recall reads `minilmL6Revision` to prove the full source pin.
    public static let minilmL6Revision = "233902d25c440f23af6f7d6e94d2946bac0bee0a"

    public static let minilmL6 = CrossEncoderProfile(
        modelID: "ms-marco-minilm-l6-cross-v1",
        modelVersion: "233902d2",
        tokenizerHash: "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3",
        maxSequence: 512,
        pool: 50,
        head: 30,
        spans: 3,
        rrfK: 60)
}
