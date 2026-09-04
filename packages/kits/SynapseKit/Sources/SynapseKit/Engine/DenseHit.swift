// DenseHit.swift
//
// Result carriers for the dense and fusion lanes.
//
// Lane F foundation types defined here:
//   DenseHit  — one result from a dense (binary or float) search.
//   LaneTag   — identifies which retrieval lane produced a score.
//
// SparseHit and FusedHit live in CorpusKit/Engine/SparseTypes and are
// NOT defined in this file.
//
// Additive-only rule (arch spec §2.4, Kong Cond-4):
// Downstream lanes must NOT add stored properties to these types
// without an FT-1 Lane F update. New fields get default values so
// existing memberwise initialisers do not break across the Swift/Rust
// twins. This is the "recurring breakage shape" flagged in Kong memory
// ([[recall-carrier-shape]]).
//
// Carrier reconciliation (Kong Cond-4):
// DenseHit.rawDistance carries the raw per-lane score upward —
// the Hamming distance for the binary lane, or the float distance
// for the float lane. This is what dense-first selection
// (DENSE_FIRST_SELECTION_SCOPE_v0.1) needs and what the current
// VectorMatch / RecallHit discarded. The design is intentionally
// compatible: RecallHit widening adds per-lane scores; DenseHit
// IS the per-lane score carrier.

import Foundation

// MARK: - DenseHit

/// One result from a dense (binary or float) index search.
///
/// rawDistance is the raw score in the metric's natural units:
/// - Hamming: integer in 0…256 (nearer = smaller).
/// - Jaccard: LIVE (W2.5 Track M1 unlock): the Jaccard DISTANCE in [0,1]
///   stored as the Float bit pattern (same encoding as the float lane).
///   Read it back with `jaccardDistance`.
/// - Cosine / L2 / dot: Float (sign depends on the specific metric).
///
/// The engine returns [DenseHit] sorted by rawDistance ascending
/// (nearer first), with ties broken by key.itemID ascending per
/// the universal tie-break rule (§0.3 of the retrieval algorithms
/// reference).
///
/// Thread-safety: value type, Sendable.
public struct DenseHit: Sendable, Equatable {

    // MARK: - Stored fields

    /// Which record produced this hit.
    public let key: VectorRecordKey

    /// Raw distance in the metric's natural unit.
    ///
    /// Representation by metric:
    /// - Hamming: the integer distance cast to Int32 (range 0…256).
    ///   Stored as Int32 to match the Rust i32 wire type and to avoid
    ///   signed/unsigned confusion at call sites. Always non-negative.
    /// - Jaccard: the Jaccard distance in [0,1] as a Float bit pattern
    ///   (the float-lane encoding). `BruteForceIndex` serves
    ///   `.binary(.jaccard)` so this path is not exercised in production.
    /// - Float cosine / L2 / dot: the Float cast to a bit-identical Int32
    ///   representation. Use floatDistance to read it back.
    ///
    /// For binary lane consumers that only use Hamming, `rawDistance`
    /// IS the Hamming distance and can be used directly.
    public let rawDistance: Int32

    /// The metric that produced rawDistance.
    public let metric: DenseMetric

    // MARK: - Initialisers

    /// General initialiser.
    ///
    /// Additive-only: new fields added to Lane F must supply a default
    /// value here so callers that use the current memberwise init do not
    /// need to be updated.
    public init(key: VectorRecordKey, rawDistance: Int32, metric: DenseMetric) {
        self.key = key
        self.rawDistance = rawDistance
        self.metric = metric
    }

    /// Convenience: Jaccard hit (W2.5 M1). Stores the distance's Float
    /// bit pattern — Float precision is exact enough for a [0,1] ratio of
    /// small integers and keeps the Int32 wire shape (additive-only rule).
    public init(key: VectorRecordKey, jaccardDistance: Double) {
        self.key = key
        self.rawDistance = Int32(bitPattern: Float(jaccardDistance).bitPattern)
        self.metric = .binary(.jaccard)
    }

    /// Convenience: Hamming hit.
    ///
    /// - Parameters:
    ///   - key: the record key of the match.
    ///   - hammingDistance: integer in 0…256.
    public init(key: VectorRecordKey, hammingDistance: Int) {
        self.key = key
        self.rawDistance = Int32(hammingDistance)
        self.metric = .hamming
    }

    // MARK: - Typed accessors

    /// Hamming distance as Int. Valid when metric == .hamming.
    ///
    /// Returns the rawDistance value directly; the cast is safe
    /// because Hamming distances are always in 0…256.
    public var hammingDistance: Int { Int(rawDistance) }

    /// Jaccard distance as Double. Valid when metric == .jaccard.
    ///
    /// rawDistance stores the bit pattern of the Double when the
    /// metric is Jaccard. This accessor reconstructs the Double.
    /// Returns nil if the metric is not Jaccard — use this to guard
    /// at the call site rather than force-casting.
    ///
    /// Live in Lane A (BruteForceIndex) since the W2.5 M1 unlock. The
    /// original reserved encoding (Double bit pattern through Int32) could
    /// never round-trip — corrected to the float-lane Float-bit-pattern
    /// encoding before first production use.
    public var jaccardDistance: Double? {
        guard case .binary(.jaccard) = metric else { return nil }
        return Double(Float(bitPattern: UInt32(bitPattern: rawDistance)))
    }

    /// Float distance. Valid when metric is a float-lane metric.
    ///
    /// rawDistance stores the bit pattern of the Float. Returns nil
    /// if the metric is not a float metric. Used by FloatBruteForceIndex
    /// and VectorStore.findNearestFloat.
    public var floatDistance: Float? {
        guard case .float = metric else { return nil }
        return Float(bitPattern: UInt32(bitPattern: rawDistance))
    }
}

// MARK: - LaneTag

/// Identifies which retrieval lane produced a score. Used in fusion
/// and late-interaction paths. Future lanes extend this enum via an
/// FT-1 Lane F update.
public enum LaneTag: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Binary dense lane (Hamming, Jaccard; SynapseKit binary engine).
    case binaryDense = "binary_dense"
    /// Float dense lane (cosine, L2, dot; SynapseKit float engine).
    case floatDense  = "float_dense"
    /// Sparse impact-weighted inverted index (BM25, SPLADE; CorpusKit).
    case sparse      = "sparse"
    /// ColBERT MaxSim late interaction (binary tokens; SynapseKit).
    case lateInteraction = "late_interaction"
}
