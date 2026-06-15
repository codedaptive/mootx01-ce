// SparseTypes.swift
//
// Sparse-lane foundation types: ImpactPosting, SparseHit, LaneTag,
// FusedHit.
//
// Lane F foundation types — CorpusKit half. Defined here first so
// Lane D (InvertedIndex, BM25Weighting) and Lane E (Fusion) can
// be built in parallel without touching this file (FT-1 rule).
//
// Additive-only rule: if a downstream lane needs a new field on any
// of these types, it files an FT-1 Lane F update. No lane adds
// fields locally. New fields must have default values in all
// initialisers so existing Swift/Rust call sites do not break.
//
// Parity note: these types have bit-identical Rust twins in
// CorpusKit/rust/src/engine/sparse_types.rs. The Rust port must
// agree on every field name, type, and serialization rule. In
// particular:
//   - ImpactPosting.impact is i32 (integer-only path, §2.2).
//   - SparseHit.impact is Float (the engine surface; quantised
//     internally, exposed as Float for consumer ergonomics).
//   - FusedHit.perLane uses LaneTag string values as keys.
//
// LaneTag is defined canonically in VectorKit (DenseHit.swift), the lower kit
// (CorpusKit depends on VectorKit). CorpusKit ALIASES it here rather than
// defining a second enum: two byte-identical Swift enums are still DISTINCT
// TYPES, which makes `.binaryDense` ambiguous in any consumer that imports both
// VectorKit and CorpusKit (e.g. ARIA_MCP). One type, aliased — mirroring the
// Rust port, where CorpusKit re-exports `vectorkit::engine::hit::LaneTag`.

import Foundation
import VectorKit

// MARK: - LaneTag (aliased from VectorKit, the canonical owner)

/// Identifies which retrieval lane produced a score in FusedHit.perLane.
/// The canonical enum lives in VectorKit.DenseHit; this alias gives CorpusKit
/// consumers the same single type. New lanes are added to VectorKit's enum
/// (FT-1 Lane F update) — never as a second local definition.
public typealias LaneTag = VectorKit.LaneTag

// MARK: - ImpactPosting

/// One entry in an impact-ordered inverted index posting list.
///
/// The `impact` field is an INTEGER (i32) — the result of quantising
/// a float weight via round-half-to-even at QUANT_SCALE=100
/// (retrieval algorithms reference §2.2). All scoring arithmetic on
/// the sparse lane uses integers, making it bit-identical across Swift
/// and Rust.
///
/// Postings within a term's list are sorted by item_id ascending
/// (the WAND pivoting invariant: §2.1, sorted by doc_id ASC). The
/// index builder is responsible for maintaining this order.
///
/// Thread-safety: value type, Sendable.
public struct ImpactPosting: Sendable, Equatable {

    /// The owning item identifier (formerly chunk UUID string;
    /// renamed to item_id to match the VectorRecordKey rename).
    public let itemID: String

    /// Quantised per-term impact for this item. INTEGER.
    /// impact = quantize(float_weight, scale=100, round=half-even).
    /// Scoring: score(item) = Σ_term query_weight[term] * impact.
    /// Never a raw float at query time — quantisation happens once at
    /// index build.
    public let impact: Int32

    /// Designated initialiser.
    ///
    /// Additive-only: future FT-1 fields added here must have defaults
    /// so existing callers are unaffected.
    public init(itemID: String, impact: Int32) {
        self.itemID = itemID
        self.impact = impact
    }
}

// MARK: - SparseHit

/// One result from a sparse-lane (BM25 / SPLADE) search.
///
/// The `impact` is the float score as exposed to consumers — the
/// quantised integer score divided back by QUANT_SCALE. This is a
/// display/fusion surface value, not the integer used internally for
/// ranking (which is Int32 and lives inside the inverted index engine).
///
/// Fusion (Lane E) reads `impact` to compute per-lane contributions
/// in `FusedHit.perLane`. Dense-first selection uses `SparseHit` as
/// the sparse-lane half of the per-lane score the dense-first spec
/// requires to flow up the channel.
///
/// Thread-safety: value type, Sendable.
public struct SparseHit: Sendable, Equatable {

    /// Item identifier of the matching record.
    public let itemID: String

    /// Normalised impact score in human-readable float units.
    /// impact = integer_score / QUANT_SCALE. For BM25, this is
    /// approximately the BM25 contribution. Higher = more relevant.
    ///
    /// Stored as Float (not Double) because the RRF fusion step
    /// uses Float throughout and precision beyond ~7 significant
    /// figures is not meaningful at the fused-score level.
    public let impact: Float

    /// Designated initialiser.
    ///
    /// Additive-only: future FT-1 fields must have defaults.
    public init(itemID: String, impact: Float) {
        self.itemID = itemID
        self.impact = impact
    }
}

// MARK: - FusedHit

/// One result from weighted RRF fusion across N lanes.
///
/// fusedScore is the generalized RRF score:
///   fusedScore(item) = Σ_lane weights[lane] · 1/(rrfK + rank_lane(item))
///
/// perLane carries the raw per-lane scores (Hamming distance / cosine /
/// BM25 impact) for all lanes that produced a hit for this item. Lanes
/// that did not produce a hit for this item are absent from perLane.
/// The current VectorKit/CorpusKit HybridRecall discards per-lane
/// scores; FusedHit preserves them so dense-first selection and recipe
/// layers can read the precomputed dense signal without recomputing it.
/// (arch spec §5.2, DENSE_FIRST_SELECTION_SCOPE_v0.1)
///
/// Result order: (fusedScore DESC, itemID ASC) — total order via the
/// universal tie-break rule (retrieval algorithms reference §0.3).
///
/// Thread-safety: value type, Sendable.
public struct FusedHit: Sendable, Equatable {

    /// Item identifier of this result.
    public let itemID: String

    /// Weighted RRF fusion score. Higher = more relevant.
    public let fusedScore: Float

    /// Per-lane raw scores, keyed by lane. Values are in each lane's
    /// natural unit:
    ///   - .binaryDense: Hamming distance (Int cast to Float; lower=better)
    ///   - .floatDense: cosine/L2/dot Float (sign depends on metric)
    ///   - .sparse: normalised impact Float (higher=better)
    ///   - .lateInteraction: MaxSim integer score (higher=better)
    ///
    /// Absent key means this item did not appear in that lane's results.
    ///
    /// Preserving per-lane scores here is the correction to the current
    /// HybridRecall.recall which fused+dropped them — dense-first
    /// selection needs these values without recomputing from scratch.
    public let perLane: [LaneTag: Float]

    /// Designated initialiser.
    ///
    /// Additive-only: future FT-1 fields must have defaults.
    public init(
        itemID: String,
        fusedScore: Float,
        perLane: [LaneTag: Float] = [:]
    ) {
        self.itemID = itemID
        self.fusedScore = fusedScore
        self.perLane = perLane
    }
}
