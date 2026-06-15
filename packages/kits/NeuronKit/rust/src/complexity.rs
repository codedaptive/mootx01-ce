// complexity.rs
//
// Complexity lens — Shannon entropy and mutual information over topic-count
// distributions (NEURONKIT_SPEC.md § 8.2, Lens 4 Topics).
//
// Normalises raw count distributions into probability distributions (input
// shaping per I-17 "owns no math") before delegating to
// substrate_ml::info_theory::InformationTheory::entropy and
// ::mutual_information. InformationTheory requires normalised distributions;
// the lens supplies them. Pure, stateless, no estate access (I-18, B-5).
// Total over edge inputs (B-8, C-16).

use substrate_ml::info_theory::InformationTheory;

/// Shannon entropy and mutual information over topic-count distributions.
#[derive(Debug, Clone, PartialEq)]
pub struct ComplexityResult {
    /// Shannon entropy of distribution A in bits.
    pub entropy_a: f32,
    /// Shannon entropy of distribution B in bits; None when counts_b is not provided.
    pub entropy_b: Option<f32>,
    /// Mutual information between A and B in bits; None when joint is not provided.
    pub mutual_information: Option<f32>,
}

/// Computes Shannon entropy and (optionally) mutual information over topic-count
/// distributions.
///
/// All-zero or empty `counts_a` yields entropy 0.0 (B-8).
pub fn complexity(
    counts_a: &[f32],
    counts_b: Option<&[f32]>,
    joint: Option<&[Vec<f32>]>,
) -> ComplexityResult {
    let entropy_a = InformationTheory::entropy(&normalise(counts_a));
    let entropy_b = counts_b.map(|c| InformationTheory::entropy(&normalise(c)));
    let mutual_information = joint.map(|j| {
        let norm_j = normalise_joint(j);
        InformationTheory::mutual_information(&norm_j)
    });
    ComplexityResult { entropy_a, entropy_b, mutual_information }
}

// Normalises a raw count slice to a probability distribution.
// Returns all-zeros when sum is zero: InformationTheory treats a
// zero distribution as zero bits, which is correct.
fn normalise(counts: &[f32]) -> Vec<f32> {
    let total: f32 = counts.iter().sum();
    if total == 0.0 || counts.is_empty() {
        return counts.to_vec();
    }
    counts.iter().map(|&c| c / total).collect()
}

// Normalises a joint count matrix into a joint probability matrix.
fn normalise_joint(joint: &[Vec<f32>]) -> Vec<Vec<f32>> {
    let total: f32 = joint.iter().flat_map(|r| r.iter()).sum();
    if total == 0.0 {
        return joint.to_vec();
    }
    joint.iter().map(|row| row.iter().map(|&c| c / total).collect()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_counts_yields_zero_entropy() {
        let result = complexity(&[], None, None);
        assert_eq!(result.entropy_a, 0.0);
        assert!(result.entropy_b.is_none());
        assert!(result.mutual_information.is_none());
    }

    #[test]
    fn all_zero_counts_yields_zero_entropy() {
        let result = complexity(&[0.0, 0.0, 0.0], None, None);
        assert_eq!(result.entropy_a, 0.0);
    }

    #[test]
    fn uniform_distribution_yields_log2_n_entropy() {
        // Uniform 4-category: entropy = log2(4) = 2 bits.
        let result = complexity(&[1.0, 1.0, 1.0, 1.0], None, None);
        assert!((result.entropy_a - 2.0).abs() < 0.001,
            "uniform 4-category entropy should be 2.0 bits, got {}", result.entropy_a);
    }

    #[test]
    fn certain_distribution_has_zero_entropy() {
        let result = complexity(&[0.0, 10.0, 0.0, 0.0], None, None);
        assert!(result.entropy_a.abs() < 1e-6);
    }

    #[test]
    fn omitted_counts_b_yields_none_entropy_b() {
        let result = complexity(&[1.0, 2.0, 3.0], None, None);
        assert!(result.entropy_b.is_none());
    }

    #[test]
    fn supplied_counts_b_populates_entropy_b() {
        let result = complexity(&[1.0, 1.0], Some(&[1.0, 1.0]), None);
        // Uniform 2-category: 1 bit.
        assert!(result.entropy_b.is_some());
        assert!((result.entropy_b.unwrap() - 1.0).abs() < 0.001);
    }

    #[test]
    fn omitted_joint_yields_none_mutual_information() {
        let result = complexity(&[1.0, 2.0], None, None);
        assert!(result.mutual_information.is_none());
    }

    #[test]
    fn independent_joint_yields_near_zero_mi() {
        // Independent: P(A,B) = P(A)·P(B); MI ≈ 0.
        // Uniform A, uniform B: joint = [[1,1],[1,1]] (equal counts).
        let joint = vec![vec![1.0f32, 1.0], vec![1.0, 1.0]];
        let result = complexity(&[1.0, 1.0], Some(&[1.0, 1.0]), Some(&joint));
        assert!(result.mutual_information.is_some());
        assert!(result.mutual_information.unwrap().abs() < 0.01,
            "independent joint should yield near-zero MI");
    }

    #[test]
    fn deterministic() {
        let counts: &[f32] = &[3.0, 1.0, 2.0, 4.0];
        let r1 = complexity(counts, None, None);
        let r2 = complexity(counts, None, None);
        assert_eq!(r1.entropy_a, r2.entropy_a);
    }

    // C-17 fidelity: entropy_a must equal InformationTheory::entropy on the
    // normalised distribution directly.
    #[test]
    fn c17_fidelity_entropy_equals_primitive() {
        let counts: &[f32] = &[1.0, 2.0, 3.0, 4.0];
        let total: f32 = counts.iter().sum();
        let normalised: Vec<f32> = counts.iter().map(|&c| c / total).collect();
        let direct = InformationTheory::entropy(&normalised);
        let result = complexity(counts, None, None);
        assert_eq!(result.entropy_a, direct,
            "lens entropy_a must equal InformationTheory::entropy on the normalised distribution");
    }
}
