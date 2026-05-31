//! Live migration-benchmark recipe execution — the real `RecipeSubstrate`
//! adapter that binds `migration_orchestration` to the actual Rust substrate,
//! the Rust parity of the Swift `MigrationBenchmark.run(...)` recipe body.
//!
//! `migration_orchestration::run_migration_benchmark` is substrate-agnostic:
//! it sequences derive → capture → benchmark over a `RecipeSubstrate` and is
//! conformance-gated with a deterministic fake. This module supplies the LIVE
//! implementation of that seam — the bridge the orchestration's doc-comment
//! anticipated — so the recipe actually RUNS in Rust, closing the through-line
//! `GLK COW branch verbs → NeuronKit benchmark → CognitionKit recipe` that the
//! Swift side already proves.
//!
//! Each seam op maps to the real substrate, exactly as the Swift recipe does:
//!   - derive_branch → `EstateCoordinator::glk_derive_branch`
//!   - capture       → branch `capture` of a `CaptureFrame` built like the
//!     Swift recipe (channel .typed, room, `LatticeAnchor::udc(latticeCode)`,
//!     `addedBy = "migration-{plan}"`, embedding model, sensitivity)
//!   - benchmark     → `neuron_kit::benchmark_branch` over the id-correlated
//!     corpus (one unconfirmed-recall query per entry; the set metrics use
//!     the union, the scoring math itself is gated in neuron_kit).
//!
//! The `RecipeSubstrate` seam is fallible: each op returns
//! `Result<_, SubstrateError>`, so this adapter maps the underlying GLK /
//! branch error into a `SubstrateError` (operation + detail) rather than
//! panicking. `run_migration_benchmark` propagates it as
//! `RecipeRunError::Substrate`, alongside the recipe's own
//! `RecipeRunError::Recipe` guard failures — the Rust encoding of the Swift
//! recipe's heterogeneous untyped `throws`.

use std::collections::HashMap;

use genius_locus_kit::branches::BranchId;
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::EstateCoordinator;
use locus_kit::adjectives::AdjectiveSensitivity;
use locus_kit::drawer_operational::CaptureChannel;
use locus_kit::estate_types::LatticeAnchor;
use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
use locus_kit::frames::CaptureFrame;

use crate::error::SubstrateError;
use crate::migration_orchestration::{BenchmarkOutcome, CorpusEntry, RecipeSubstrate};

/// A live `RecipeSubstrate` over a real `EstateCoordinator` + parent estate.
/// Branches are minted in the coordinator's registry (the Swift model); the
/// estate-free `String` branch ids the orchestration uses are mapped back to
/// the typed `BranchId` here.
pub struct LiveRecipeSubstrate<'a> {
    coord: &'a mut EstateCoordinator,
    parent: EstateHandle,
    now: i64,
    /// estate-free branch id (the orchestration's `String`) -> typed BranchId.
    branch_ids: HashMap<String, BranchId>,
    /// branch id -> plan name, for the `addedBy = "migration-{plan}"` field.
    plan_names: HashMap<String, String>,
}

impl<'a> LiveRecipeSubstrate<'a> {
    /// Construct a live substrate that derives branches from `parent` in
    /// `coord`, capturing/benchmarking at the deterministic instant `now`.
    pub fn new(coord: &'a mut EstateCoordinator, parent: EstateHandle, now: i64) -> Self {
        Self {
            coord,
            parent,
            now,
            branch_ids: HashMap::new(),
            plan_names: HashMap::new(),
        }
    }

    fn one_query() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }
}

impl RecipeSubstrate for LiveRecipeSubstrate<'_> {
    fn derive_branch(&mut self, plan_name: &str) -> Result<String, SubstrateError> {
        let bid = self
            .coord
            .glk_derive_branch(plan_name, &self.parent, self.now)
            .map_err(|e| SubstrateError::new("derive_branch", format!("{e:?}")))?;
        let key = bid.to_string();
        self.branch_ids.insert(key.clone(), bid);
        self.plan_names.insert(key.clone(), plan_name.to_string());
        Ok(key)
    }

    fn capture(
        &mut self,
        branch_id: &str,
        content: &str,
        room: &str,
        lattice_code: &str,
        embedding_model_id: &str,
        sensitivity: i64,
    ) -> Result<String, SubstrateError> {
        let plan = self.plan_names.get(branch_id).cloned().unwrap_or_default();
        let mut frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            room,
            LatticeAnchor::udc(lattice_code),
            format!("migration-{plan}"),
            embedding_model_id,
        );
        frame.sensitivity = AdjectiveSensitivity::from_raw(sensitivity);
        // The branch id was minted by `derive_branch` on this same adapter,
        // so a missing mapping is an internal invariant violation, not a
        // substrate failure — surface it as one for a uniform error channel.
        let bid = *self
            .branch_ids
            .get(branch_id)
            .ok_or_else(|| SubstrateError::new("capture", format!("untracked branch id {branch_id}")))?;
        let branch = self
            .coord
            .branch_handle_for(bid)
            .ok_or_else(|| SubstrateError::new("capture", "branch not in registry"))?;
        branch
            .capture(frame, self.now)
            .map(|d| d.id)
            .map_err(|e| SubstrateError::new("capture", format!("{e:?}")))
    }

    fn benchmark(
        &mut self,
        branch_id: &str,
        corpus: &[CorpusEntry],
    ) -> Result<BenchmarkOutcome, SubstrateError> {
        let bid = *self
            .branch_ids
            .get(branch_id)
            .ok_or_else(|| SubstrateError::new("benchmark", format!("untracked branch id {branch_id}")))?;
        let branch = self
            .coord
            .branch_handle_for(bid)
            .ok_or_else(|| SubstrateError::new("benchmark", "branch not in registry"))?;
        let expected_ids: Vec<String> = corpus.iter().map(|c| c.id.clone()).collect();
        // One unconfirmed-recall query per corpus entry — the set metrics use
        // the union of all queries' results (matching the Swift default path's
        // 1:1 frame-per-entry shape). `benchmark_branch` is itself infallible.
        let queries: Vec<RecallFrame> = corpus.iter().map(|_| Self::one_query()).collect();
        let report = neuron_kit::benchmark_branch(branch, &expected_ids, queries, self.now);
        Ok(BenchmarkOutcome {
            recall_overlap: report.recall_overlap,
            mean_reciprocal_rank: report.mean_reciprocal_rank,
            not_found: report.not_found_in_branch,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::migration_orchestration::{run_migration_benchmark, OriginEntry, PlanInput};
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::OwnerCredentials;
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(storage, NOW, None).unwrap());
        let h = coord.open(store, OwnerCredentials::new("owner"), 0, 100).unwrap();
        (coord, h)
    }

    fn plan(name: &str) -> PlanInput {
        PlanInput {
            name: name.to_string(),
            room: "study".to_string(),
            lattice_code: "0".to_string(),
            embedding_model_id: "test-v1".to_string(),
            sensitivity: 0,
        }
    }

    fn origin(entries: &[(&str, &str)]) -> Vec<OriginEntry> {
        entries
            .iter()
            .map(|(id, c)| OriginEntry { id: id.to_string(), content: c.to_string() })
            .collect()
    }

    // CK-LIVE-1: the full through-line RUNS in Rust. A clean plan migrates
    // every concept, loses none (C-13 clean), is ranked, and wins — proving
    // GLK branch verbs + NeuronKit benchmark drive a real CognitionKit recipe.
    #[test]
    fn ck_live1_clean_plan_runs_and_wins() {
        let (mut coord, h) = coord_with_parent();
        let plans = vec![plan("flat")];
        let origin = origin(&[("e1", "alpha"), ("e2", "beta")]);

        let mut sub = LiveRecipeSubstrate::new(&mut coord, h, NOW);
        let report = run_migration_benchmark(&mut sub, &plans, &origin).expect("run");

        assert_eq!(report.winner.as_deref(), Some("flat"), "clean plan wins");
        assert!(report.disqualified.is_empty(), "nothing lost ⇒ not disqualified");
        assert_eq!(report.plan_results.len(), 1);
        let pr = &report.plan_results[0];
        assert!(pr.lost.is_empty(), "no concept lost");
        assert_eq!(pr.recall_overlap, 1.0, "every migrated concept recalled");
    }

    // CK-LIVE-2: an origin entry with empty content is never captured
    // (dropped), so the plan's `lost` set is non-empty and C-13 disqualifies
    // it — no winner. The live recipe enforces zero-silent-loss end to end.
    #[test]
    fn ck_live2_dropped_concept_disqualifies_the_plan() {
        let (mut coord, h) = coord_with_parent();
        let plans = vec![plan("flat")];
        // e3 has empty content ⇒ dropped (never migratable).
        let origin = origin(&[("e1", "alpha"), ("e2", "beta"), ("e3", "")]);

        let mut sub = LiveRecipeSubstrate::new(&mut coord, h, NOW);
        let report = run_migration_benchmark(&mut sub, &plans, &origin).expect("run");

        assert!(report.winner.is_none(), "a lossy plan cannot win");
        assert_eq!(report.disqualified.len(), 1);
        assert_eq!(report.disqualified[0].name, "flat");
        assert!(
            report.disqualified[0].lost_concepts.contains(&"e3".to_string()),
            "the dropped concept is the C-13 loss: {:?}",
            report.disqualified[0].lost_concepts
        );
        // The per-plan result still records the lost concept.
        assert!(report.plan_results[0].lost.contains(&"e3".to_string()));
    }
}
