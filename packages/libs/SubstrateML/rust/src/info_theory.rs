// info_theory.rs
//
// Information-theoretic primitives per cookbook § 8.11. Mirror of
// glref-swift-InformationTheory.swift.
//
// All units in bits (log base 2). Inputs MUST be valid probability
// distributions. The reference does not validate; callers are
// responsible.

pub struct InformationTheory;

impl InformationTheory {
    /// Shannon entropy in bits.
    pub fn entropy(p: &[f32]) -> f32 {
        p.iter()
            .filter(|&&pi| pi > 0.0)
            .map(|&pi| -pi * pi.log2())
            .sum()
    }

    /// Mutual information I(X;Y) in bits over a joint distribution.
    pub fn mutual_information(joint: &[Vec<f32>]) -> f32 {
        if joint.is_empty() { return 0.0; }
        let m = joint.len();
        let n = joint[0].len();
        let mut px = vec![0.0_f32; m];
        let mut py = vec![0.0_f32; n];
        for i in 0..m {
            for j in 0..n {
                px[i] += joint[i][j];
                py[j] += joint[i][j];
            }
        }
        let mut mi = 0.0_f32;
        for i in 0..m {
            for j in 0..n {
                let p = joint[i][j];
                if p > 0.0 && px[i] > 0.0 && py[j] > 0.0 {
                    mi += p * (p / (px[i] * py[j])).log2();
                }
            }
        }
        mi
    }

    /// KL divergence KL(p || q) in bits.
    pub fn kl_divergence(p: &[f32], q: &[f32]) -> f32 {
        assert_eq!(p.len(), q.len(), "p and q must have matching support");
        let mut kl = 0.0_f32;
        for i in 0..p.len() {
            if p[i] > 0.0 && q[i] > 0.0 {
                kl += p[i] * (p[i] / q[i]).log2();
            }
        }
        kl
    }

    /// Cross entropy H(p, q) in bits.
    pub fn cross_entropy(p: &[f32], q: &[f32]) -> f32 {
        assert_eq!(p.len(), q.len(), "p and q must have matching support");
        let mut ce = 0.0_f32;
        for i in 0..p.len() {
            if p[i] > 0.0 && q[i] > 0.0 {
                ce -= p[i] * q[i].log2();
            }
        }
        ce
    }

    /// Symmetric Jensen-Shannon divergence in bits, bounded in [0,1].
    pub fn jensen_shannon(p: &[f32], q: &[f32]) -> f32 {
        assert_eq!(p.len(), q.len(), "p and q must have matching support");
        let m: Vec<f32> = p.iter().zip(q.iter()).map(|(a, b)| (a + b) / 2.0).collect();
        0.5 * Self::kl_divergence(p, &m) + 0.5 * Self::kl_divergence(q, &m)
    }

    /// Normalized mutual information NMI in [0, 1].
    ///
    /// Returns 0 (matching `mutual_information`'s sentinel) when `joint`
    /// is empty or ragged. A ragged matrix corrupts the marginals; guard
    /// matches the Swift port's totality contract.
    pub fn normalized_mutual_information(joint: &[Vec<f32>]) -> f32 {
        if joint.is_empty() {
            return 0.0;
        }
        let n = joint[0].len();
        if joint.iter().any(|row| row.len() != n) {
            return 0.0;
        }
        let mi = Self::mutual_information(joint);
        let m = joint.len();
        let mut px = vec![0.0_f32; m];
        let mut py = vec![0.0_f32; n];
        for i in 0..m {
            for j in 0..n {
                px[i] += joint[i][j];
                py[j] += joint[i][j];
            }
        }
        let denom = Self::entropy(&px) + Self::entropy(&py);
        if denom > 0.0 { 2.0 * mi / denom } else { 0.0 }
    }
}
