//! The deterministic decision core of MigrationBenchmark — Rust version of
//! the Swift `MigrationRanking` enum in
//! `CognitionKit/Sources/CognitionKit/MigrationRanking.swift`.
//!
//! Every function here is a PURE function of its inputs (no estate, no
//! branch handles, no UUIDs, no clock). The Swift `MigrationBenchmark.run`
//! does the estate I/O and delegates every decision — the duplicate-plan
//! guard, the origin partition, the lost-concept union, the C-13 gate and
//! the survivor ranking — to these functions. Both versions agree on the
//! fixtures in the `#[cfg(test)]` block below, which mirror the Swift
//! `MigrationRankingTests`.
//!
//! Determinism note: `combined_score = recall_overlap * mean_reciprocal_rank`
//! is always in [0, 1] for benchmark inputs (both factors are in [0, 1]),
//! so it is never NaN and the `partial_cmp` in `rank` never sees an
//! incomparable pair. The tie-break on `name` makes the order total.

/// One plan's benchmark outcome, stripped of estate identity so the
/// ranking is a pure function. Mirrors Swift `MigrationRanking.PlanOutcome`.
#[derive(Debug, Clone, PartialEq)]
pub struct PlanOutcome {
    pub name: String,
    pub recall_overlap: f32,
    pub mean_reciprocal_rank: f32,
    /// Concepts this plan lost (dropped ∪ benchmark not-found). Non-empty
    /// disqualifies the plan (C-13).
    pub lost: Vec<String>,
}

/// A surviving plan's rank line. Mirrors Swift `MigrationRanking.RankedPlan`.
#[derive(Debug, Clone, PartialEq)]
pub struct RankedPlan {
    pub name: String,
    pub recall_overlap: f32,
    pub mean_reciprocal_rank: f32,
    pub combined_score: f32,
}

/// A disqualified plan. Mirrors Swift `MigrationRanking.DisqualifiedCore`.
#[derive(Debug, Clone, PartialEq)]
pub struct DisqualifiedCore {
    pub name: String,
    pub lost_concepts: Vec<String>,
}

/// The ranking outcome. Mirrors Swift `MigrationRanking.Result`.
#[derive(Debug, Clone, PartialEq)]
pub struct RankingResult {
    pub rankings: Vec<RankedPlan>,
    pub disqualified: Vec<DisqualifiedCore>,
    pub winner: Option<String>,
}

/// The first value that appears more than once in `names`, scanning in
/// order, or `None` when every value is unique. Mirrors Swift
/// `MigrationRanking.firstDuplicate`.
pub fn first_duplicate(names: &[String]) -> Option<String> {
    let mut seen = std::collections::HashSet::new();
    for name in names {
        if !seen.insert(name) {
            return Some(name.clone());
        }
    }
    None
}

/// The lost-concept set for one plan: the union of `dropped` and
/// `not_found`, de-duplicated and sorted for a deterministic,
/// cross-version-identical result. Mirrors Swift `MigrationRanking.lostConcepts`.
pub fn lost_concepts(dropped: &[String], not_found: &[String]) -> Vec<String> {
    let mut set: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for d in dropped {
        set.insert(d.clone());
    }
    for n in not_found {
        set.insert(n.clone());
    }
    set.into_iter().collect()
}

/// Partition origin `(id, content)` pairs into the ids worth migrating
/// (non-empty after trimming) and the ids dropped as unmigratable,
/// order-preserving within each bucket. Mirrors Swift
/// `MigrationRanking.partitionOrigin`. Returns `(migratable, dropped)`.
pub fn partition_origin(entries: &[(String, String)]) -> (Vec<String>, Vec<String>) {
    let mut migratable = Vec::new();
    let mut dropped = Vec::new();
    for (id, content) in entries {
        if content.trim().is_empty() {
            dropped.push(id.clone());
        } else {
            migratable.push(id.clone());
        }
    }
    (migratable, dropped)
}

/// Apply the C-13 gate and rank the survivors. Mirrors Swift
/// `MigrationRanking.rank`:
///
/// - a plan with a non-empty `lost` set is disqualified (not ranked);
/// - a survivor's `combined_score` is `recall_overlap * mean_reciprocal_rank`;
/// - survivors sort by `combined_score` descending, ties by `name`
///   ascending, for a reproducible order across versions;
/// - the advisory `winner` is the top survivor's name, or `None`.
pub fn rank(outcomes: &[PlanOutcome]) -> RankingResult {
    let mut rankings: Vec<RankedPlan> = Vec::new();
    let mut disqualified: Vec<DisqualifiedCore> = Vec::new();
    for o in outcomes {
        if o.lost.is_empty() {
            rankings.push(RankedPlan {
                name: o.name.clone(),
                recall_overlap: o.recall_overlap,
                mean_reciprocal_rank: o.mean_reciprocal_rank,
                combined_score: o.recall_overlap * o.mean_reciprocal_rank,
            });
        } else {
            disqualified.push(DisqualifiedCore {
                name: o.name.clone(),
                lost_concepts: o.lost.clone(),
            });
        }
    }
    // Combined score descending; equal scores break by name ascending.
    // Mirrors the Swift `sort` comparator exactly. `partial_cmp` is safe:
    // combined scores are finite (see module note).
    rankings.sort_by(|a, b| {
        if a.combined_score != b.combined_score {
            b.combined_score
                .partial_cmp(&a.combined_score)
                .expect("combined scores are finite")
        } else {
            a.name.cmp(&b.name)
        }
    });
    let winner = rankings.first().map(|r| r.name.clone());
    RankingResult {
        rankings,
        disqualified,
        winner,
    }
}

#[cfg(test)]
mod tests {
    //! Conformance fixtures — mirror Swift `MigrationRankingTests`
    //! (fixtures F1–F7).
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    // F1 / F2 — duplicate detection
    #[test]
    fn f1_f2_first_duplicate() {
        assert_eq!(first_duplicate(&s(&["a", "b", "c"])), None);
        assert_eq!(
            first_duplicate(&s(&["x", "y", "x", "y"])),
            Some("x".to_string())
        );
        assert_eq!(first_duplicate(&[]), None);
    }

    // F3 — lost-concept union, sorted + deduped
    #[test]
    fn f3_lost_concepts() {
        assert_eq!(lost_concepts(&s(&["b"]), &s(&["a", "b"])), s(&["a", "b"]));
        assert_eq!(lost_concepts(&[], &[]), Vec::<String>::new());
        assert_eq!(
            lost_concepts(&s(&["z", "m"]), &s(&["m", "a"])),
            s(&["a", "m", "z"])
        );
    }

    // F4 — origin partition by empty-after-trim content
    #[test]
    fn f4_partition_origin() {
        let entries = vec![
            ("a".to_string(), "hi".to_string()),
            ("b".to_string(), "   ".to_string()),
            ("c".to_string(), "yo".to_string()),
        ];
        let (migratable, dropped) = partition_origin(&entries);
        assert_eq!(migratable, s(&["a", "c"]));
        assert_eq!(dropped, s(&["b"]));
    }

    fn outcome(name: &str, overlap: f32, mrr: f32, lost: &[&str]) -> PlanOutcome {
        PlanOutcome {
            name: name.to_string(),
            recall_overlap: overlap,
            mean_reciprocal_rank: mrr,
            lost: s(lost),
        }
    }

    // F5 — four clean equal-score plans rank alphabetically
    #[test]
    fn f5_rank_equal_scores_tie_break_by_name() {
        let outcomes = vec![
            outcome("delta", 1.0, 1.0, &[]),
            outcome("alpha", 1.0, 1.0, &[]),
            outcome("charlie", 1.0, 1.0, &[]),
            outcome("bravo", 1.0, 1.0, &[]),
        ];
        let r = rank(&outcomes);
        assert_eq!(
            r.rankings
                .iter()
                .map(|p| p.name.as_str())
                .collect::<Vec<_>>(),
            vec!["alpha", "bravo", "charlie", "delta"]
        );
        assert_eq!(r.winner, Some("alpha".to_string()));
        assert!(r.disqualified.is_empty());
    }

    // F6 — a lost plan is disqualified, never ranked
    #[test]
    fn f6_rank_disqualifies_lost_plan() {
        let outcomes = vec![
            outcome("clean", 1.0, 1.0, &[]),
            outcome("lossy", 0.5, 0.5, &["x"]),
        ];
        let r = rank(&outcomes);
        assert_eq!(
            r.rankings
                .iter()
                .map(|p| p.name.as_str())
                .collect::<Vec<_>>(),
            vec!["clean"]
        );
        assert_eq!(
            r.disqualified
                .iter()
                .map(|d| d.name.as_str())
                .collect::<Vec<_>>(),
            vec!["lossy"]
        );
        assert_eq!(r.disqualified[0].lost_concepts, s(&["x"]));
        assert_eq!(r.winner, Some("clean".to_string()));
    }

    // F7 — distinct scores rank strictly descending; combined = overlap*mrr
    #[test]
    fn f7_rank_distinct_scores_descending() {
        let outcomes = vec![
            outcome("low", 0.2, 0.5, &[]),  // 0.10
            outcome("high", 0.8, 1.0, &[]), // 0.80
            outcome("mid", 0.5, 0.8, &[]),  // 0.40
        ];
        let r = rank(&outcomes);
        assert_eq!(
            r.rankings
                .iter()
                .map(|p| p.name.as_str())
                .collect::<Vec<_>>(),
            vec!["high", "mid", "low"]
        );
        assert!((r.rankings[0].combined_score - 0.8).abs() < 1e-6);
        assert_eq!(r.winner, Some("high".to_string()));
    }

    // Empty input -> empty result, no winner.
    #[test]
    fn rank_empty() {
        let r = rank(&[]);
        assert!(r.rankings.is_empty());
        assert!(r.disqualified.is_empty());
        assert_eq!(r.winner, None);
    }
}
