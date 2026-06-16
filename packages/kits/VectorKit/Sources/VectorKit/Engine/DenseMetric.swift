// DenseMetric.swift
//
// Metric enumeration for the dense engine seam.
//
// Lane F foundation type. The DenseMetric umbrella wraps both the
// binary-lane metrics (Hamming, Jaccard) and the float-lane metrics
// (cosine, l2, dot — VectorKit's FloatMetric). Both metric families
// are owned by VectorKit: dense-embedding distance is a VectorKit
// concern (ADR-008 persistencekit-vector-contract-correction).
//
// Design rationale: the engine seam (DenseIndex.search) takes one
// parameter of type DenseMetric. Binary and float metrics live in one
// enum so no dispatch site needs to know which lane it is routing to.
//
// Determinism boundary (arch spec §6):
// - .binary(.hamming): bit-identical four-way (I-7, SubstrateKernel).
// - .binary(.jaccard): bit-identical numerator + denominator (kernel
//   AND/OR/popcount), then one IEEE-754 double division — see note.
// - .float(_): reproducible-within-config; NOT four-way bit-identical.
//   This is a documented property of float math, not a bug.
//
// Jaccard determinism note: Jaccard(a,b) = popcount(a AND b) /
// popcount(a OR b). Both popcount terms are computed by SubstrateKernel
// (four-way gated). The final division is IEEE-754 double. Two
// platforms that produce identical integer numerator and denominator
// will produce identical doubles for this division (IEEE-754 mandates
// exact rounding for the basic operations: +, -, *, /). The determinism
// boundary is therefore "bit-identical numerator/denominator (kernel) +
// identical IEEE-754 division" — identical across all conformant
// IEEE-754 implementations, which covers Swift and Rust on the targeted
// platforms.

// MARK: - Float metrics

/// Metrics defined over float32 dense embedding vectors (the float lane).
///
/// VectorKit owns this type: dense-embedding distance is a VectorKit
/// concern (ADR-008 persistencekit-vector-contract-correction). The float
/// lane is reproducible-within-config, NOT four-way bit-identical — see the
/// determinism boundary note above.
public enum FloatMetric: Sendable, Equatable, Hashable {
    /// Cosine distance: 1 - (a·b) / (‖a‖·‖b‖).
    case cosine
    /// Squared / Euclidean L2 distance.
    case l2
    /// Negative dot product (so smaller = nearer, matching cosine/l2 ordering).
    case dot
}

// MARK: - Binary metrics

/// Metrics defined over 256-bit binary (Engram / Fingerprint256) vectors.
///
/// All arithmetic on these metrics is integer-only (§0.2 of the
/// retrieval algorithms reference). Distance values are UInt32
/// (Hamming: 0…256). Jaccard's final division is Double but the
/// operands are integer — see the Jaccard determinism note above.
public enum BinaryMetric: Sendable, Equatable, Hashable {
    /// Hamming distance: popcount(a XOR b). Integer in [0, 256].
    /// Computed ONLY by SubstrateKernel.hammingTopK / hammingDistance
    /// — the engine never reimplements it (arch spec §3.1, §3.4).
    case hamming

    /// Jaccard similarity / distance over 256-bit vectors.
    ///
    ///   similarity = popcount(a AND b) / popcount(a OR b)
    ///   distance   = 1 - similarity
    ///
    /// Both popcount terms are SubstrateKernel ops. The division is
    /// Double (IEEE-754 exactly rounded). Jaccard is defined as 0/0=1
    /// (identical all-zero vectors have similarity 1 by convention).
    case jaccard
}

// MARK: - DenseMetric umbrella

/// Unified metric type for the dense engine seam (DenseIndex.search).
///
/// The `.binary` case wraps BinaryMetric; the `.float` case wraps
/// VectorKit's own FloatMetric (cosine, l2, dot).
public enum DenseMetric: Sendable, Equatable, Hashable {
    /// Binary-lane metric. Integer arithmetic, four-way determinism.
    case binary(BinaryMetric)
    /// Float-lane metric (FloatMetric: cosine, l2, dot).
    /// Reproducible-within-config; NOT four-way bit-identical.
    case float(FloatMetric)

    // MARK: - Convenience accessors

    /// Shorthand: .binary(.hamming)
    public static let hamming: DenseMetric = .binary(.hamming)

    /// Shorthand: .binary(.jaccard)
    public static let jaccard: DenseMetric = .binary(.jaccard)

    /// Shorthand: .float(.cosine)
    public static let cosine: DenseMetric = .float(.cosine)

    /// Shorthand: .float(.l2)
    public static let l2: DenseMetric = .float(.l2)

    /// Shorthand: .float(.dot)
    public static let dot: DenseMetric = .float(.dot)

    // MARK: - Lane checks

    /// True for binary-lane metrics (integer arithmetic, four-way gate).
    public var isBinary: Bool {
        if case .binary = self { return true }
        return false
    }

    /// True for float-lane metrics (reproducible-within-config).
    public var isFloat: Bool {
        if case .float = self { return true }
        return false
    }
}
