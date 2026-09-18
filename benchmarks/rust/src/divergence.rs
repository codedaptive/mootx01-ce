//! divergence.rs — the two divergence axes the benchmarker reports.
//!
//! Ports `Divergence.swift` exactly. Both functions are pure and
//! deterministic: no randomness, no I/O, no mutable global state.
//!
//! SET divergence answers "did all expected items land on the target?"
//! RANK divergence answers "did recall ORDER change between rankings?"
//! Both are normalized so 0.0 means no divergence and 1.0 means maximal.

use std::collections::HashSet;

/// SET divergence. Did all expected items land on the target?
///
/// Symmetric difference over union: 0.0 = identical sets, 1.0 = disjoint.
/// Two empty sets are defined as identical (0.0) — there is nothing that
/// failed to land. Mirrors Swift `jaccardDivergence` exactly.
pub fn jaccard_divergence(expected: &[&str], got: &[&str]) -> f64 {
    let expected_set: HashSet<&str> = expected.iter().copied().collect();
    let got_set: HashSet<&str> = got.iter().copied().collect();

    if expected_set.is_empty() && got_set.is_empty() {
        return 0.0;
    }

    let intersection = expected_set.intersection(&got_set).count();
    let union = expected_set.union(&got_set).count();
    // Jaccard similarity = |A ∩ B| / |A ∪ B|; divergence is its complement.
    1.0 - (intersection as f64 / union as f64)
}

/// RANK divergence. Did recall ORDER change between two rankings?
///
/// Computed over the intersection of IDs present in both rankings — IDs in
/// only one ranking carry no order information and are dropped.
/// Normalized to 0.0 = identical order, 1.0 = fully reversed, via the
/// normalized Kendall-tau distance: the count of discordant pairs divided
/// by the maximum possible pair count for the shared set.
/// Mirrors Swift `rankDivergence` exactly.
pub fn rank_divergence(expected: &[&str], got: &[&str]) -> f64 {
    // Restrict both rankings to the shared-ID intersection.
    let expected_set: HashSet<&str> = expected.iter().copied().collect();
    let got_set: HashSet<&str> = got.iter().copied().collect();
    let shared: HashSet<&str> = expected_set.intersection(&got_set).copied().collect();

    let expected_order: Vec<&str> = expected.iter().copied().filter(|id| shared.contains(id)).collect();
    let got_order: Vec<&str> = got.iter().copied().filter(|id| shared.contains(id)).collect();

    let n = expected_order.len();
    // Fewer than two shared IDs means no pairs exist, so no order can
    // disagree: divergence is 0.
    if n < 2 {
        return 0.0;
    }

    // Position of each shared id within `got`, for testing pair order.
    let mut rank_in_got: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for (i, id) in got_order.iter().enumerate() {
        rank_in_got.insert(id, i);
    }

    // Count discordant pairs: for every pair (a, b) where a precedes b in
    // `expected`, it is discordant if a follows b in `got`.
    let mut discordant = 0usize;
    for i in 0..n {
        for j in (i + 1)..n {
            if let (Some(&ra), Some(&rb)) = (
                rank_in_got.get(expected_order[i]),
                rank_in_got.get(expected_order[j]),
            ) {
                if ra > rb {
                    discordant += 1;
                }
            }
        }
    }

    let total_pairs = n * (n - 1) / 2;
    discordant as f64 / total_pairs as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jaccard_identical() {
        assert!((jaccard_divergence(&["a", "b", "c"], &["a", "b", "c"]) - 0.0).abs() < 1e-9);
    }

    #[test]
    fn jaccard_disjoint() {
        assert!((jaccard_divergence(&["a", "b"], &["c", "d"]) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn jaccard_both_empty() {
        assert!((jaccard_divergence(&[], &[]) - 0.0).abs() < 1e-9);
    }

    #[test]
    fn rank_identical() {
        assert!((rank_divergence(&["a", "b", "c", "d"], &["a", "b", "c", "d"]) - 0.0).abs() < 1e-9);
    }

    #[test]
    fn rank_fully_reversed() {
        assert!((rank_divergence(&["a", "b", "c", "d"], &["d", "c", "b", "a"]) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn rank_fewer_than_two_shared() {
        assert!((rank_divergence(&["a"], &["a", "b"]) - 0.0).abs() < 1e-9);
    }
}
