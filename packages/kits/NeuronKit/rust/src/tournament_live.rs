//! The live branch tournament (NEURONKIT_SPEC § 4.4, NK-TOUR-01 model) —
//! the Rust parity of the Swift `NeuronKit.runTournament` / `rankTournament`
//! in Tournament.swift.
//!
//! Benchmark a set of COW branches, disqualify any with silent migration
//! loss (C-13), rank the survivors, and surface an ADVISORY winner. Spec
//! invariant I-16: the tournament performs ZERO substrate writes and never
//! promotes — its only substrate touch is the read-only `benchmark_live`,
//! which itself drives only `branch.recall_with(_)`. The winner is advisory.
//!
//! As in Swift, the ranking/gate/tie-break logic is a PURE core
//! (`rank_tournament`) separated from the benchmark I/O, because a single
//! shared corpus yields a non-disqualified report for at most one branch
//! (benchmark compares corpus ids against per-branch minted drawer ids). So
//! multi-branch ranking + tie-break is exercised with fabricated
//! `BenchmarkReport`s fed to `rank_tournament`, and the real wiring is
//! exercised end-to-end through `run_tournament`.

use genius_locus_kit::branches::EstateBranch;
use locus_kit::filter::RecallFrame;

use crate::benchmark_live::{benchmark, BenchmarkReport};

/// Why a branch was excluded from ranking.
#[derive(Debug, Clone, PartialEq)]
pub enum DisqualificationReason {
    /// The branch's benchmark found at least one missing concept (C-13).
    SilentLoss { not_found_count: usize },
}

/// A ranked survivor: the branch id, its benchmark report, and the combined
/// score (`recall_overlap * mean_reciprocal_rank`).
#[derive(Debug, Clone, PartialEq)]
pub struct BranchScore {
    pub branch_id: String,
    pub report: BenchmarkReport,
    pub combined_score: f32,
}

/// A branch excluded by the zero-silent-loss gate, retained with its reason
/// and report so the disqualification is visible and auditable.
#[derive(Debug, Clone, PartialEq)]
pub struct DisqualifiedBranch {
    pub branch_id: String,
    pub reason: DisqualificationReason,
    pub report: BenchmarkReport,
}

/// The outcome of a tournament. `winner` is advisory (I-16): the tournament
/// never promotes. `None` when every branch was disqualified or the input
/// was empty.
#[derive(Debug, Clone, PartialEq)]
pub struct TournamentReport {
    pub winner: Option<BranchScore>,
    pub ranking: Vec<BranchScore>,
    pub disqualified: Vec<DisqualifiedBranch>,
    /// Caller-supplied evaluation instant (never a system clock).
    pub evaluated_at: i64,
}

/// The pure, deterministic gate-plus-ranking core (parity of the Swift
/// `rankTournament`). Applies the C-13 gate BEFORE ranking, scores
/// survivors by `recall_overlap * mean_reciprocal_rank`, and ranks
/// descending with an ascending-branch-id tie-break for reproducibility.
/// No substrate touch, no clock.
pub fn rank_tournament(scored: Vec<(String, BenchmarkReport)>, now: i64) -> TournamentReport {
    let mut ranking: Vec<BranchScore> = Vec::new();
    let mut disqualified: Vec<DisqualifiedBranch> = Vec::new();

    for (branch_id, report) in scored {
        // Zero-silent-loss gate, BEFORE ranking (C-13): a branch whose
        // benchmark found a missing concept is disqualified, retained with
        // its reason, and never scored or ranked.
        let not_found_count = report.not_found_in_branch.len();
        if not_found_count > 0 {
            disqualified.push(DisqualifiedBranch {
                branch_id,
                reason: DisqualificationReason::SilentLoss { not_found_count },
                report,
            });
            continue;
        }
        let combined = report.recall_overlap * report.mean_reciprocal_rank;
        ranking.push(BranchScore {
            branch_id,
            report,
            combined_score: combined,
        });
    }

    // Descending by combined score; equal scores break by ascending branch
    // id string so the ordering is reproducible.
    ranking.sort_by(|a, b| {
        b.combined_score
            .partial_cmp(&a.combined_score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.branch_id.cmp(&b.branch_id))
    });

    let winner = ranking.first().cloned();
    TournamentReport {
        winner,
        ranking,
        disqualified,
        evaluated_at: now,
    }
}

/// Benchmark each branch against the corpus, then gate + rank (parity of the
/// Swift `runTournament`). `make_queries` rebuilds the per-branch query
/// frames (the Swift signature reuses one `queries` array; the Rust frames
/// are consumed by `benchmark`, so a builder is taken instead). All branches
/// are scored at the same deterministic `now`.
pub fn run_tournament<F>(
    branches: &[EstateBranch],
    expected_ids: &[String],
    make_queries: F,
    now: i64,
) -> TournamentReport
where
    F: Fn() -> Vec<RecallFrame>,
{
    let mut scored: Vec<(String, BenchmarkReport)> = Vec::with_capacity(branches.len());
    for branch in branches {
        let report = benchmark(branch, expected_ids, make_queries(), now);
        scored.push((branch.branch_id.to_string(), report));
    }
    rank_tournament(scored, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use genius_locus_kit::EstateCoordinator;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
    use locus_kit::frames::CaptureFrame;
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    /// Fabricate a benchmark report — the way the Swift tournament tests feed
    /// `rankTournament` deterministic ranking inputs.
    fn report(branch_id: &str, overlap: f32, mrr: f32, not_found: &[&str]) -> BenchmarkReport {
        BenchmarkReport {
            branch_id: branch_id.to_string(),
            query_count: 1,
            recall_overlap: overlap,
            recall_precision: overlap,
            mean_reciprocal_rank: mrr,
            not_found_in_branch: not_found.iter().map(|s| s.to_string()).collect(),
            new_in_branch: vec![],
            evaluated_at: NOW,
        }
    }

    // TR-1: survivors rank descending by combined = overlap * mrr; the top is
    // the advisory winner.
    #[test]
    fn tr1_ranks_descending_by_combined_score() {
        let scored = vec![
            ("low".to_string(), report("low", 0.5, 0.5, &[])), // 0.25
            ("high".to_string(), report("high", 1.0, 1.0, &[])), // 1.00
            ("mid".to_string(), report("mid", 0.8, 0.5, &[])), // 0.40
        ];
        let t = rank_tournament(scored, NOW);
        let order: Vec<&str> = t.ranking.iter().map(|b| b.branch_id.as_str()).collect();
        assert_eq!(order, vec!["high", "mid", "low"]);
        assert_eq!(t.winner.unwrap().branch_id, "high");
        assert!(t.disqualified.is_empty());
        assert_eq!(t.evaluated_at, NOW);
    }

    // TR-2: a branch with non-empty not_found is disqualified (C-13) — never
    // scored or ranked, retained with its reason.
    #[test]
    fn tr2_silent_loss_is_disqualified_before_ranking() {
        let scored = vec![
            ("clean".to_string(), report("clean", 1.0, 1.0, &[])),
            (
                "lossy".to_string(),
                report("lossy", 0.9, 0.9, &["missing-concept"]),
            ),
        ];
        let t = rank_tournament(scored, NOW);
        assert_eq!(t.ranking.len(), 1);
        assert_eq!(t.ranking[0].branch_id, "clean");
        assert_eq!(t.disqualified.len(), 1);
        assert_eq!(t.disqualified[0].branch_id, "lossy");
        assert_eq!(
            t.disqualified[0].reason,
            DisqualificationReason::SilentLoss { not_found_count: 1 }
        );
    }

    // TR-3: equal combined scores break by ascending branch-id string.
    #[test]
    fn tr3_ties_break_by_ascending_branch_id() {
        let scored = vec![
            ("zzz".to_string(), report("zzz", 0.8, 0.5, &[])), // 0.40
            ("aaa".to_string(), report("aaa", 0.5, 0.8, &[])), // 0.40
        ];
        let t = rank_tournament(scored, NOW);
        let order: Vec<&str> = t.ranking.iter().map(|b| b.branch_id.as_str()).collect();
        assert_eq!(order, vec!["aaa", "zzz"], "equal scores -> ascending id");
        assert_eq!(t.winner.unwrap().branch_id, "aaa");
    }

    // TR-4: empty input -> no winner, empty ranking/disqualified.
    #[test]
    fn tr4_empty_input_has_no_winner() {
        let t = rank_tournament(vec![], NOW);
        assert!(t.winner.is_none());
        assert!(t.ranking.is_empty());
        assert!(t.disqualified.is_empty());
    }

    // TR-5: end-to-end run_tournament over a real, clean branch — it is
    // benchmarked, survives the gate, and is the advisory winner.
    #[test]
    fn tr5_run_tournament_end_to_end() {
        // The Swift model: mint the branch through the kit's verb.
        let mut coord = EstateCoordinator::new();
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        let bid = coord.glk_derive_branch("b", &h, NOW).unwrap();

        let mut ids = Vec::new();
        for c in ["alpha", "beta"] {
            let frame = CaptureFrame::new(
                c,
                CaptureChannel::Typed,
                "study",
                LatticeAnchor::udc("0"),
                "alice",
                "test-v1",
            );
            ids.push(
                coord
                    .branch_handle_for(bid)
                    .unwrap()
                    .capture(frame, NOW)
                    .unwrap()
                    .id,
            );
        }

        let make_queries = || {
            let mk = || {
                let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
                f.hydration_level = HydrationLevel::Structured;
                f.ordering = Ordering::ByCaptureTimeDesc;
                f
            };
            vec![mk(), mk()]
        };

        let branch = coord.branch_handle_for(bid).unwrap();
        let t = run_tournament(std::slice::from_ref(branch), &ids, make_queries, NOW);
        assert!(
            t.disqualified.is_empty(),
            "clean branch is not disqualified"
        );
        assert_eq!(t.ranking.len(), 1);
        assert!(
            t.winner.is_some(),
            "the clean branch is the advisory winner"
        );
    }
}
