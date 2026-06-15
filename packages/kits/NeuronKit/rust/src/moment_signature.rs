// moment_signature.rs
//
// MomentSignature lens — shapes a window of fingerprinted rows into an
// OR-reduced signature and ranks candidates by Hamming proximity
// (NEURONKIT_SPEC.md § 8.2, Lens 1 Topics+Time).
//
// Delegates to substrate_ml::moment_summary::MomentSummary::or_reduce for
// OR-reduction and engram_lib::EngramLib::distance for Hamming distance.
// Owns no math (I-17). Pure, stateless, no estate access (I-18, B-5).
// Total over edge inputs (B-8, C-16).

use engram_lib::{Engram, EngramLib};
use substrate_ml::moment_summary::{MomentSummary, RowLite};

/// One candidate ranked against the window signature.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowRank {
    /// Candidate fingerprint being ranked.
    pub candidate: Engram,
    /// Hamming distance from the window signature; 0 = identical, 256 = fully inverted.
    pub hamming_distance: u32,
}

/// OR-reduced window signature with the ranked candidate set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MomentSignatureResult {
    /// OR-reduced fingerprint over the input window rows.
    pub signature: Engram,
    /// Candidates sorted ascending by Hamming distance to `signature` (nearest first).
    pub ranking: Vec<WindowRank>,
}

/// Shapes a time window of fingerprinted rows into an OR-reduced signature
/// and ranks candidates by Hamming proximity, nearest first.
///
/// Empty `fingerprints` or empty `candidates` yields zero signature and
/// empty ranking (B-8).
pub fn moment_signature(fingerprints: &[RowLite], candidates: &[Engram]) -> MomentSignatureResult {
    if fingerprints.is_empty() || candidates.is_empty() {
        return MomentSignatureResult {
            signature: Engram::ZERO,
            ranking: vec![],
        };
    }
    let fps: Vec<Engram> = fingerprints.iter().map(|r| r.fingerprint).collect();
    let sig = MomentSummary::or_reduce(&fps);
    let mut ranking: Vec<WindowRank> = candidates
        .iter()
        .map(|c| WindowRank {
            candidate: *c,
            hamming_distance: EngramLib::distance(&sig, c),
        })
        .collect();
    ranking.sort_by_key(|r| r.hamming_distance);
    MomentSignatureResult { signature: sig, ranking }
}

#[cfg(test)]
mod tests {
    use super::*;
    use substrate_types::fingerprint256::Fingerprint256;

    fn fp(b0: u64, b1: u64, b2: u64, b3: u64) -> Engram {
        Fingerprint256::new(b0, b1, b2, b3)
    }

    fn row(fingerprint: Engram) -> RowLite {
        RowLite {
            fingerprint,
            capture_hlc: substrate_types::HLC::new(0, 0, 0),
        }
    }

    #[test]
    fn empty_fingerprints_yields_zero_signature() {
        let result = moment_signature(&[], &[fp(0xFFFF, 0, 0, 0)]);
        assert_eq!(result.signature, Fingerprint256::ZERO);
        assert!(result.ranking.is_empty());
    }

    #[test]
    fn empty_candidates_yields_zero_signature() {
        let result = moment_signature(&[row(fp(0xABCD, 0, 0, 0))], &[]);
        assert_eq!(result.signature, Fingerprint256::ZERO);
        assert!(result.ranking.is_empty());
    }

    #[test]
    fn single_row_signature_equals_fingerprint() {
        let f = fp(0xDEAD, 0xBEEF, 0, 0);
        let result = moment_signature(&[row(f)], &[f]);
        assert_eq!(result.signature, f);
    }

    #[test]
    fn or_reduces_disjoint_bits() {
        let a = fp(0xFF00, 0, 0, 0);
        let b = fp(0x00FF, 0, 0, 0);
        let expected = fp(0xFFFF, 0, 0, 0);
        let result = moment_signature(&[row(a), row(b)], &[expected]);
        assert_eq!(result.signature, expected);
    }

    #[test]
    fn identical_candidate_ranks_first_with_distance_zero() {
        let f = fp(0xABCD, 0xEF01, 0, 0);
        let near = fp(0xABCD, 0xEF01, 0, 0);
        let far = fp(0x0000, 0x0000, 0xFFFF, 0xFFFF);
        let result = moment_signature(&[row(f)], &[far, near]);
        assert_eq!(result.ranking[0].candidate, near);
        assert_eq!(result.ranking[0].hamming_distance, 0);
    }

    #[test]
    fn ranking_ascending_by_hamming_distance() {
        let sig = fp(0xFFFF, 0, 0, 0);
        let c0 = fp(0xFFFF, 0, 0, 0);
        let c1 = fp(0xFFFE, 0, 0, 0);
        let c_far = fp(0x0000, 0xFFFF, 0, 0);
        let result = moment_signature(&[row(sig)], &[c_far, c1, c0]);
        let dists: Vec<u32> = result.ranking.iter().map(|r| r.hamming_distance).collect();
        let mut sorted = dists.clone();
        sorted.sort();
        assert_eq!(dists, sorted);
    }

    #[test]
    fn deterministic() {
        let f = fp(0x1234, 0x5678, 0x9ABC, 0xDEF0);
        let cand = fp(0x1234, 0, 0, 0);
        let r1 = moment_signature(&[row(f)], &[cand]);
        let r2 = moment_signature(&[row(f)], &[cand]);
        assert_eq!(r1, r2);
    }

    // C-17 fidelity: signature must equal MomentSummary::or_reduce on same inputs.
    #[test]
    fn c17_fidelity_signature_equals_primitive() {
        use substrate_ml::moment_summary::MomentSummary;
        let fps = vec![fp(0xFF00, 0, 0, 0), fp(0x00FF, 0, 0, 0)];
        let rows: Vec<_> = fps.iter().map(|&f| row(f)).collect();
        let direct = MomentSummary::or_reduce(&fps);
        let result = moment_signature(&rows, &[direct]);
        assert_eq!(result.signature, direct,
            "lens signature must equal MomentSummary::or_reduce on the same inputs");
    }
}
