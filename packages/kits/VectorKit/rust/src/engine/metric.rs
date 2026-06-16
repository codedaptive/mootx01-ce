//! DenseMetric — umbrella metric enum for binary and float dense lanes.
//!
//! Parallel to Swift `DenseMetric`, `BinaryMetric`, and `FloatMetric`.
//! Both metric families are owned by VectorKit: dense-embedding distance
//! is a VectorKit concern (ADR-008 persistencekit-vector-contract-correction).
//!
//! The four-way conformance contract: binary paths (BinaryMetric) must
//! run integer-only arithmetic and produce bit-identical results across
//! Swift scalar, Swift Metal, Rust scalar, and Rust BLAS/NEON.

/// Binary distance metric. All arithmetic is integer-only — no floats
/// on the binary path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BinaryMetric {
    /// Popcount of XOR. Range 0..=256 for 256-bit engrams.
    Hamming,
    /// Hamming distance re-expressed as a ratio: range 0.0–1.0, but
    /// stored as a fixed-point integer (×10_000) to stay integer-only
    /// on the critical path. `raw_distance` from a search hit carries
    /// the scaled integer value.
    Jaccard,
}

/// Float distance metric for float32 / int8 vector lanes. VectorKit-owned
/// (ADR-008); persistence-kit carries no vector-distance type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FloatMetric {
    /// 1 − dot(a,b) / (‖a‖ ‖b‖).
    Cosine,
    /// Euclidean distance.
    L2,
    /// Negative inner product (for pre-normalised vectors,
    /// maximise dot product ≡ minimise negative dot).
    Dot,
}

/// Umbrella lane-dispatch metric. Selects between binary and float dense
/// lanes at the protocol boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DenseMetric {
    Binary(BinaryMetric),
    Float(FloatMetric),
}

impl DenseMetric {
    /// Convenience: Hamming binary metric.
    pub const HAMMING: DenseMetric = DenseMetric::Binary(BinaryMetric::Hamming);
    /// Convenience: Jaccard binary metric.
    pub const JACCARD: DenseMetric = DenseMetric::Binary(BinaryMetric::Jaccard);
    /// Convenience: cosine float metric.
    pub const COSINE: DenseMetric = DenseMetric::Float(FloatMetric::Cosine);
    /// Convenience: L2 float metric.
    pub const L2: DenseMetric = DenseMetric::Float(FloatMetric::L2);
    /// Convenience: dot-product float metric.
    pub const DOT: DenseMetric = DenseMetric::Float(FloatMetric::Dot);

    /// Returns `true` if this metric operates on binary (Engram) vectors.
    pub fn is_binary(self) -> bool {
        matches!(self, DenseMetric::Binary(_))
    }

    /// Returns `true` if this metric operates on float32 or int8 vectors.
    pub fn is_float(self) -> bool {
        matches!(self, DenseMetric::Float(_))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_binary_and_is_float_are_mutually_exclusive() {
        assert!(DenseMetric::HAMMING.is_binary());
        assert!(!DenseMetric::HAMMING.is_float());
        assert!(DenseMetric::COSINE.is_float());
        assert!(!DenseMetric::COSINE.is_binary());
    }

    #[test]
    fn convenience_constants_have_expected_variants() {
        assert_eq!(DenseMetric::HAMMING, DenseMetric::Binary(BinaryMetric::Hamming));
        assert_eq!(DenseMetric::JACCARD, DenseMetric::Binary(BinaryMetric::Jaccard));
        assert_eq!(DenseMetric::COSINE, DenseMetric::Float(FloatMetric::Cosine));
        assert_eq!(DenseMetric::L2, DenseMetric::Float(FloatMetric::L2));
        assert_eq!(DenseMetric::DOT, DenseMetric::Float(FloatMetric::Dot));
    }
}
