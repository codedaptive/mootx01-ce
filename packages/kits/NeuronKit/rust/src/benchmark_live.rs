//! The live migration recall-fidelity benchmark (NEURONKIT_SPEC § 4.7) —
//! the Rust parity of the Swift `NeuronKit.benchmark(branch:against:...)`
//! in BenchmarkAlgorithm.swift.
//!
//! It scores how faithfully a COW branch recalls the concepts of an origin
//! corpus. The ONLY substrate call it makes is `branch.recall_with(frame)`
//! per query — read-only, the C-13 corollary; the branch is never
//! perturbed. Every metric is delegated to the conformance-gated
//! `benchmark_scoring::score` (already in this crate), so this module is a thin,
//! faithful orchestration over the branch surface and the scoring core.
//!
//! The Swift signature takes an `ExternalCorpus` and calls
//! `origin.asRecallFrames()`; that convenience (build one frame per corpus
//! entry) is the CALLER's to replicate — this version takes the expected ids
//! and the query frames directly, which is exactly the data
//! `benchmark_scoring::score` depends on. `branch_id` and `evaluated_at`
//! are the only branch-/clock-supplied fields.

use genius_locus_kit::branches::EstateBranch;
use locus_kit::filter::RecallFrame;

use crate::benchmark_scoring::score;

/// Recall-fidelity report for a branch measured against an origin corpus
/// (spec § 4.7) — the Rust parity of the Swift `BenchmarkReport`.
/// `not_found_in_branch` is the zero-tolerance migration-loss signal
/// (conformance C-13): any non-empty value disqualifies the branch from
/// tournament ranking downstream.
#[derive(Debug, Clone, PartialEq)]
pub struct BenchmarkReport {
    /// The branch this report scores (its `BranchId` as a string).
    pub branch_id: String,
    pub query_count: usize,
    pub recall_overlap: f32,
    pub recall_precision: f32,
    pub mean_reciprocal_rank: f32,
    /// Concept ids in the corpus but absent from branch recall. MUST be
    /// empty for a conforming migration (C-13). Sorted (from the scorer).
    pub not_found_in_branch: Vec<String>,
    /// Concept ids found in branch recall but not in the corpus. Sorted.
    pub new_in_branch: Vec<String>,
    /// Caller-supplied evaluation instant (never a system clock — the fleet
    /// determinism rule; `now` is a parameter).
    pub evaluated_at: i64,
}

/// Score a branch's recall fidelity against an origin corpus (spec § 4.7).
///
/// For each query frame, recall from `branch` and collect the returned
/// drawer ids; then delegate every metric to `benchmark_scoring::score`
/// over (`expected_ids`, the per-query found-id lists). For MRR alignment,
/// query frame `i` is paired with `expected_ids[i]` by the scorer, so a
/// caller should keep query frames index-aligned with `expected_ids` (the
/// Swift `asRecallFrames()` default path is 1:1 with corpus entries).
///
/// READ-ONLY: issues only `branch.recall_with(_)`; no estate write verbs.
pub fn benchmark(
    branch: &EstateBranch,
    expected_ids: &[String],
    query_frames: Vec<RecallFrame>,
    now: i64,
) -> BenchmarkReport {
    let mut found_per_query: Vec<Vec<String>> = Vec::with_capacity(query_frames.len());
    for frame in query_frames {
        let drawers = branch.recall_with(frame, now);
        found_per_query.push(drawers.into_iter().map(|d| d.id).collect());
    }

    let s = score(expected_ids, &found_per_query);

    BenchmarkReport {
        branch_id: branch.branch_id.to_string(),
        query_count: s.query_count,
        recall_overlap: s.recall_overlap,
        recall_precision: s.recall_precision,
        mean_reciprocal_rank: s.mean_reciprocal_rank,
        not_found_in_branch: s.not_found_in_branch,
        new_in_branch: s.new_in_branch,
        evaluated_at: now,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use genius_locus_kit::branches::BranchId;
    use genius_locus_kit::{EstateCoordinator, EstateHandle};
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::{LatticeAnchor, OwnerCredentials};
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
    use locus_kit::frames::CaptureFrame;

    const NOW: i64 = 1_700_000_000;

    /// Open an empty parent estate in a coordinator and derive a branch from
    /// it (the Swift model: branches are minted by the kit's verb). Returns
    /// the coordinator (owning the branch) and the branch id.
    fn empty_branch() -> (EstateCoordinator, EstateHandle, BranchId) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
        let bid = coord.glk_derive_branch("b", &h, NOW).unwrap();
        (coord, h, bid)
    }

    fn cap(coord: &EstateCoordinator, bid: BranchId, content: &str) -> String {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "study",
            LatticeAnchor::udc("0"),
            "alice",
            "test-v1",
        );
        coord
            .branch_handle_for(bid)
            .unwrap()
            .capture(frame, NOW)
            .unwrap()
            .id
    }

    /// A per-query recall frame over the branch's unconfirmed rows (freshly
    /// captured rows are unconfirmed, so the filter must admit them — the
    /// same `Filter::Unconfirmed` the branch's own snapshot recall uses).
    /// One frame per corpus concept; the set metrics use the union of all
    /// queries' results, so this is sufficient to exercise the branch-recall
    /// plumbing while the scoring math itself is gated by benchmark_scoring.
    fn query() -> RecallFrame {
        let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
        frame.hydration_level = HydrationLevel::Structured;
        frame.ordering = Ordering::ByCaptureTimeDesc;
        frame
    }

    // BL-1: perfect recall — every corpus concept is found in its own query,
    // nothing is lost. recallOverlap = 1, notFound empty (C-13 clean).
    #[test]
    fn bl1_perfect_recall_is_clean() {
        let (coord, _h, bid) = empty_branch();
        let id_a = cap(&coord, bid, "alpha concept");
        let id_b = cap(&coord, bid, "beta concept");
        let expected = vec![id_a.clone(), id_b.clone()];
        let queries = vec![query(), query()];

        let branch = coord.branch_handle_for(bid).unwrap();
        let report = benchmark(branch, &expected, queries, NOW);
        assert_eq!(report.query_count, 2);
        assert!(report.not_found_in_branch.is_empty(), "C-13: nothing lost");
        assert_eq!(report.recall_overlap, 1.0, "found set == expected set");
        assert_eq!(report.evaluated_at, NOW);
        assert!(!report.branch_id.is_empty());
    }

    // BL-2: silent loss — a corpus concept whose row was never captured into
    // the branch surfaces in not_found_in_branch (the C-13 disqualifier).
    #[test]
    fn bl2_silent_loss_is_flagged() {
        let (coord, _h, bid) = empty_branch();
        let id_a = cap(&coord, bid, "alpha concept");
        // expected includes a ghost id that was never captured.
        let ghost = "concept-never-migrated".to_string();
        let expected = vec![id_a, ghost.clone()];
        // One query that finds alpha; the ghost has no row to find.
        let queries = vec![query(), query()];

        let branch = coord.branch_handle_for(bid).unwrap();
        let report = benchmark(branch, &expected, queries, NOW);
        assert!(
            report.not_found_in_branch.contains(&ghost),
            "the un-migrated concept is the C-13 loss signal: {:?}",
            report.not_found_in_branch
        );
    }
}
