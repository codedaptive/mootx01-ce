// composite_distance.rs
//
// Composite distance per cookbook § 8.4. Mirror of
// glref-swift-CompositeDistance.swift.

pub struct CompositeDistance;

impl CompositeDistance {
    pub const DEFAULT_ALPHA_LATTICE: f64 = 0.5;
    pub const DEFAULT_ALPHA_FINGERPRINT: f64 = 0.5;
    pub const FINGERPRINT_TOTAL_BITS: usize = 256;

    /// Composite distance between two rows.
    ///
    /// Both component distances must be in [0, 1]; callers that pass
    /// out-of-range values will panic (matching Swift's precondition).
    /// `lattice_distance` is guaranteed in-range by `UDCTreeDistance` and
    /// `WikidataGraphDistance` after the normalization fix.
    /// `fingerprint_hamming_distance` must not exceed `FINGERPRINT_TOTAL_BITS` (256).
    pub fn distance(
        lattice_distance: f64,
        fingerprint_hamming_distance: usize,
        alpha_lattice: f64,
        alpha_fingerprint: f64,
        compatible_seed_scope: bool,
    ) -> f64 {
        assert!(
            lattice_distance >= 0.0 && lattice_distance <= 1.0,
            "lattice_distance must be in [0, 1]; got {}",
            lattice_distance
        );
        assert!(
            fingerprint_hamming_distance <= Self::FINGERPRINT_TOTAL_BITS,
            "fingerprint_hamming_distance {} exceeds total bits {}",
            fingerprint_hamming_distance,
            Self::FINGERPRINT_TOTAL_BITS
        );
        let lat_part = alpha_lattice * lattice_distance;
        if !compatible_seed_scope {
            return lat_part;
        }
        let fp_normalized =
            fingerprint_hamming_distance as f64 / Self::FINGERPRINT_TOTAL_BITS as f64;
        lat_part + alpha_fingerprint * fp_normalized
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reflexive_identical_rows() {
        let d = CompositeDistance::distance(0.0, 0, 0.5, 0.5, true);
        assert!(d.abs() < 1e-12);
    }

    #[test]
    fn equal_weights_max_distance() {
        // lattice = 1.0, hamming = 256 (max). With α = 0.5 each:
        // d = 0.5 * 1.0 + 0.5 * (256/256) = 1.0.
        let d = CompositeDistance::distance(1.0, 256, 0.5, 0.5, true);
        assert!((d - 1.0).abs() < 1e-12);
    }

    #[test]
    fn cross_perimeter_drops_fingerprint() {
        // With compatibleSeedScope = false, fingerprint term ignored.
        let d_full = CompositeDistance::distance(0.4, 128, 0.5, 0.5, true);
        let d_lat = CompositeDistance::distance(0.4, 128, 0.5, 0.5, false);
        // d_full = 0.5 * 0.4 + 0.5 * 0.5 = 0.45
        // d_lat  = 0.5 * 0.4               = 0.20
        assert!((d_full - 0.45).abs() < 1e-12);
        assert!((d_lat - 0.20).abs() < 1e-12);
    }

    #[test]
    fn weight_skew() {
        // Heavy weight on lattice.
        let d = CompositeDistance::distance(0.4, 64, 0.9, 0.1, true);
        // d = 0.9 * 0.4 + 0.1 * (64/256) = 0.36 + 0.025 = 0.385.
        assert!((d - 0.385).abs() < 1e-12);
    }

    #[test]
    fn linearity_in_alphas() {
        // Halving both alphas halves the result.
        let d1 = CompositeDistance::distance(0.4, 64, 0.5, 0.5, true);
        let d2 = CompositeDistance::distance(0.4, 64, 0.25, 0.25, true);
        assert!((d1 - 2.0 * d2).abs() < 1e-12);
    }
}
