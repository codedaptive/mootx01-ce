//! The deterministic scoring core of the migration recall-fidelity
//! benchmark (NEURONKIT_SPEC § 4.7) — Rust version of the Swift
//! `BenchmarkScoring` in `NeuronKit/Sources/NeuronKit/BenchmarkScoring.swift`.
//! Per CLAUDE.md neither version leads; both run identical math and are gated
//! against the shared BS-1..5 fixtures.
//!
//! Pure: a function of the expected concept ids and the per-query recalled
//! id lists. No branch handle, no estate, no recall I/O, no clock. The
//! Swift `benchmark(...)` performs the only substrate touch
//! (`branch.recall`) to produce `found_per_query`, then delegates every
//! metric here; the Rust version has no estate so it exposes only this core.
//! The live recall path is Bucket B (estate-blocked), tracked separately.

use std::collections::BTreeSet;

/// The scored metrics — the `BenchmarkReport` fields that are a pure
/// function of the recall results (everything except `branch_id` and
/// `evaluated_at`, supplied by the caller). Mirrors Swift
/// `BenchmarkScoring.Score`.
#[derive(Debug, Clone, PartialEq)]
pub struct BenchmarkScore {
    pub query_count: usize,
    pub recall_overlap: f32,
    pub recall_precision: f32,
    pub mean_reciprocal_rank: f32,
    pub not_found_in_branch: Vec<String>,
    pub new_in_branch: Vec<String>,
}

/// Score a benchmark from its recall results. Mirrors Swift
/// `BenchmarkScoring.score(expectedIDs:foundPerQuery:)` exactly.
///
/// - `expected_ids`: origin concept ids, in corpus order. MRR pairs
///   expected concept `i` with query `i`.
/// - `found_per_query`: recalled id lists, one per query, index-aligned;
///   each inner list is in the branch's ranked order.
///
/// Metrics (every denominator guarded; empty ⇒ 0):
/// - `recall_overlap`   = |expected ∩ foundUnion| / |expected ∪ foundUnion|
/// - `recall_precision` = |expected ∩ foundUnion| / |foundUnion|
/// - `mean_reciprocal_rank` = mean over paired concepts of 1/rank, rank =
///   1-based first position of `expected_ids[i]` in `found_per_query[i]`
///   (0 when absent); only indices `i < expected_ids.len()` are paired.
/// - `not_found_in_branch` = expected − foundUnion (C-13 signal),
///   `new_in_branch` = foundUnion − expected; both sorted.
///
/// `foundUnion` is the union across ALL queries (C-13: recalled if ANY
/// query surfaced it).
pub fn score(expected_ids: &[String], found_per_query: &[Vec<String>]) -> BenchmarkScore {
    let expected_set: BTreeSet<&String> = expected_ids.iter().collect();

    let mut found_union: BTreeSet<String> = BTreeSet::new();
    let mut reciprocal_ranks: Vec<f32> = Vec::new();
    for (index, ids) in found_per_query.iter().enumerate() {
        for id in ids {
            found_union.insert(id.clone());
        }
        // MRR pairing: query `index` scores expected concept `index`.
        if index < expected_ids.len() {
            let expected_id = &expected_ids[index];
            if let Some(pos) = ids.iter().position(|x| x == expected_id) {
                reciprocal_ranks.push(1.0 / (pos as f32 + 1.0));
            } else {
                reciprocal_ranks.push(0.0);
            }
        }
    }

    // Set differences over the union (sorted via BTreeSet iteration order,
    // matching Swift's `.sorted()`).
    let not_found_in_branch: Vec<String> = expected_set
        .iter()
        .filter(|id| !found_union.contains(**id))
        .map(|id| (*id).clone())
        .collect();
    let new_in_branch: Vec<String> = found_union
        .iter()
        .filter(|id| !expected_set.contains(*id))
        .cloned()
        .collect();

    let intersection_count = expected_set
        .iter()
        .filter(|id| found_union.contains(**id))
        .count();
    // |expected ∪ foundUnion|.
    let mut union_set: BTreeSet<&String> = expected_set.clone();
    for id in &found_union {
        union_set.insert(id);
    }
    let union_count = union_set.len();

    let recall_overlap = if union_count == 0 {
        0.0
    } else {
        intersection_count as f32 / union_count as f32
    };
    let recall_precision = if found_union.is_empty() {
        0.0
    } else {
        intersection_count as f32 / found_union.len() as f32
    };
    let mean_reciprocal_rank = if reciprocal_ranks.is_empty() {
        0.0
    } else {
        reciprocal_ranks.iter().sum::<f32>() / reciprocal_ranks.len() as f32
    };

    BenchmarkScore {
        query_count: found_per_query.len(),
        recall_overlap,
        recall_precision,
        mean_reciprocal_rank,
        not_found_in_branch,
        new_in_branch,
    }
}

#[cfg(test)]
mod tests {
    //! Conformance fixtures — mirror the Swift `BenchmarkScoringTests`
    //! (BS-1..5) exactly: same inputs, same expected metrics.
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }
    fn fq(rows: &[&[&str]]) -> Vec<Vec<String>> {
        rows.iter().map(|r| s(r)).collect()
    }

    // BS-1 — perfect migration: every concept recalled at rank 1.
    #[test]
    fn perfect_recall() {
        let r = score(&s(&["a", "b", "c"]), &fq(&[&["a"], &["b"], &["c"]]));
        assert_eq!(r.query_count, 3);
        assert!((r.recall_overlap - 1.0).abs() < 1e-6);
        assert!((r.recall_precision - 1.0).abs() < 1e-6);
        assert!((r.mean_reciprocal_rank - 1.0).abs() < 1e-6);
        assert!(r.not_found_in_branch.is_empty());
        assert!(r.new_in_branch.is_empty());
    }

    // BS-2 — silent loss: one concept never recalled (C-13 signal).
    #[test]
    fn silent_loss() {
        let r = score(&s(&["a", "b"]), &fq(&[&["a"], &[]]));
        assert!((r.recall_overlap - 0.5).abs() < 1e-6); // 1∩ / 2∪
        assert!((r.recall_precision - 1.0).abs() < 1e-6); // 1∩ / 1 found
        assert!((r.mean_reciprocal_rank - 0.5).abs() < 1e-6); // (1.0 + 0.0)/2
        assert_eq!(r.not_found_in_branch, s(&["b"]));
        assert!(r.new_in_branch.is_empty());
    }

    // BS-3 — rank sensitivity + surplus.
    #[test]
    fn rank_and_surplus() {
        let r = score(&s(&["a", "b"]), &fq(&[&["x", "a"], &["b", "y"]]));
        assert!((r.recall_overlap - 0.5).abs() < 1e-6); // 2∩ / 4∪
        assert!((r.recall_precision - 0.5).abs() < 1e-6); // 2∩ / 4 found
        assert!((r.mean_reciprocal_rank - 0.75).abs() < 1e-6); // a@2(0.5)+b@1(1.0) /2
        assert!(r.not_found_in_branch.is_empty());
        assert_eq!(r.new_in_branch, s(&["x", "y"])); // surplus, sorted
    }

    // BS-4 — empty is the guarded 0, never a trap.
    #[test]
    fn empty_is_zero_not_trap() {
        let r = score(&[], &[]);
        assert_eq!(r.query_count, 0);
        assert_eq!(r.recall_overlap, 0.0);
        assert_eq!(r.recall_precision, 0.0);
        assert_eq!(r.mean_reciprocal_rank, 0.0);
        assert!(r.not_found_in_branch.is_empty());
        assert!(r.new_in_branch.is_empty());
    }

    // BS-5 — union semantics: recalled by ANY query counts (C-13), but MRR
    // pairing is per-query.
    #[test]
    fn found_union_across_queries() {
        let r = score(&s(&["a", "b"]), &fq(&[&["a", "b"], &[]]));
        assert!(r.not_found_in_branch.is_empty());
        assert!((r.recall_overlap - 1.0).abs() < 1e-6);
        assert!((r.mean_reciprocal_rank - 0.5).abs() < 1e-6); // a@1 in q0; b not in q1
    }
}
