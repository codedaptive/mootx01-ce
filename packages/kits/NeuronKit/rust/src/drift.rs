//! Drift — distributional shift between two windows (Lens 5, Surprise): the
//! NeuronKit reasoning surface over SubstrateML's `InformationTheory`. Given
//! two topic/category distributions (e.g. two time windows), the
//! Jensen-Shannon and KL divergences quantify how far the second has moved
//! from the first — "your interests shifted in April."
//!
//! Layer B-1: the divergence math lives in SubstrateML; this shapes it into a
//! reasoning result. CognitionKit sequences it (build the two distributions
//! from the estate, then call this). The distributions must share support
//! (same length, aligned bins); the caller aligns them.

use substrate_ml::info_theory::InformationTheory;

/// How far distribution `q` has drifted from `p`.
#[derive(Clone, Debug, PartialEq)]
pub struct DriftScore {
    /// Jensen-Shannon divergence (symmetric, bounded) — the primary drift
    /// signal. 0 = identical; grows with separation.
    pub jensen_shannon: f32,
    /// KL divergence D(p‖q) (asymmetric) — how surprising q is under p.
    pub kl_divergence: f32,
}

/// Drift of `q` from `p`. `p` and `q` are distributions over the same aligned
/// support (same length); the caller normalizes/aligns them.
pub fn drift(p: &[f32], q: &[f32]) -> DriftScore {
    DriftScore {
        jensen_shannon: InformationTheory::jensen_shannon(p, q),
        kl_divergence: InformationTheory::kl_divergence(p, q),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // DR-1: identical distributions have zero Jensen-Shannon drift.
    #[test]
    fn dr1_identical_is_zero_drift() {
        let p = [0.5_f32, 0.3, 0.2];
        let d = drift(&p, &p);
        assert!(d.jensen_shannon.abs() < 1e-5, "no shift ⇒ no drift, got {}", d.jensen_shannon);
    }

    // DR-2: a clear shift registers more drift than a slight one — JS grows
    // monotonically with separation.
    #[test]
    fn dr2_bigger_shift_more_drift() {
        let p = [0.8_f32, 0.1, 0.1];
        let slight = [0.7_f32, 0.2, 0.1];
        let big = [0.1_f32, 0.1, 0.8];
        let ds = drift(&p, &slight).jensen_shannon;
        let db = drift(&p, &big).jensen_shannon;
        assert!(db > ds, "a larger shift drifts more: big {db} vs slight {ds}");
    }

    // DR-3: maximally disjoint distributions drift the most (mass moved to a
    // bin that was empty).
    #[test]
    fn dr3_disjoint_is_high_drift() {
        let p = [1.0_f32, 0.0];
        let q = [0.0_f32, 1.0];
        let d = drift(&p, &q);
        assert!(d.jensen_shannon > 0.5, "disjoint support is high drift, got {}", d.jensen_shannon);
    }
}
