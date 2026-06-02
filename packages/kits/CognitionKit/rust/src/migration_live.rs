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
use uuid::Uuid;

use crate::error::{RecipeError, RecipeRunError, SubstrateError};
use crate::migration_orchestration::{BenchmarkOutcome, CoreReport, CorpusEntry, RecipeSubstrate};

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
        let bid = *self.branch_ids.get(branch_id).ok_or_else(|| {
            SubstrateError::new("capture", format!("untracked branch id {branch_id}"))
        })?;
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
        let bid = *self.branch_ids.get(branch_id).ok_or_else(|| {
            SubstrateError::new("benchmark", format!("untracked branch id {branch_id}"))
        })?;
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

/// Parse a report's estate-free `String` branch id back to a typed
/// `BranchId` for the coordinator's branch registry.
fn parse_branch_id(s: &str) -> Result<BranchId, SubstrateError> {
    Uuid::parse_str(s)
        .map_err(|e| SubstrateError::new("promote_branch", format!("bad branch id '{s}': {e}")))
}

/// Confirm promotion of a winning branch by id, discarding the losers — the
/// id-addressed form of the human-gated second step (spec B-3). Intended for
/// stateless callers (such as the MCP two-call pattern) that carry the branch
/// ids emitted by `run_migration_benchmark` rather than the `CoreReport`
/// object itself. Parity of the Swift `MigrationBenchmark.confirmPromotion`
/// by-id overload; the cross-version behavioral contract is maintained there.
///
/// Guard order mirrors the Swift reference:
///   1. C-5: `winner_branch_id` in `disqualified_branch_ids` →
///      `RecipeError::SilentConceptLoss { branch_id: winner id string,
///      lost_concepts: vec![] }` (the by-id shape carries no lost-concept
///      detail — callers echo ids from the run report, not concept lists).
///   2. Resolve: `coord.branch_handle_for(winner_branch_id)` → `None` →
///      `RecipeError::UserConfirmationRequired { action: "promote unknown
///      branch <id>" }`.
///   3. `coord.glk_promote_branch(winner_branch_id, handle, now)`, mapped
///      exactly as the report-based path maps it.
///   4. Discard loop over `discard_branch_ids` skipping ids equal to the
///      winner and skipping unresolvable ids silently (parity of the
///      report-based path's discard behaviour).
pub fn confirm_migration_promotion_by_id(
    coord: &mut EstateCoordinator,
    winner_branch_id: BranchId,
    discard_branch_ids: &[BranchId],
    disqualified_branch_ids: &[BranchId],
    handle: &EstateHandle,
    now: i64,
) -> Result<(), RecipeRunError> {
    // Guard 1 — C-5: a disqualified branch is never promoted.
    // The by-id shape carries no lost-concept detail; callers hold ids only.
    if disqualified_branch_ids.contains(&winner_branch_id) {
        return Err(RecipeError::SilentConceptLoss {
            branch_id: winner_branch_id.to_string(),
            lost_concepts: vec![],
        }
        .into());
    }

    // Guard 2 — resolve: an id the coordinator does not hold is unknown.
    coord.branch_handle_for(winner_branch_id).ok_or_else(|| {
        RecipeError::UserConfirmationRequired {
            action: format!("promote unknown branch {winner_branch_id}"),
        }
    })?;

    // Guard 3 — promote.
    coord
        .glk_promote_branch(winner_branch_id, handle, now)
        .map_err(|e| SubstrateError::new("promote_branch", format!("{e:?}")))?;

    // Guard 4 — discard loop; winner and unresolvable ids skipped silently.
    for &bid in discard_branch_ids {
        if bid != winner_branch_id {
            let _ = coord.glk_discard_branch(bid);
        }
    }
    Ok(())
}

/// Confirm promotion of the winning plan's branch into the estate and discard
/// the losers — the explicit human-gated second step (spec B-3). `run`
/// (run_migration_benchmark) never promotes; this does. Parity of the Swift
/// `MigrationBenchmark.confirmPromotion`.
///
/// Branches are resolved from the coordinator's retained registry, so this
/// works across the stateless run→confirm boundary (two separate calls): the
/// `CoreReport` carries the branch ids the run surfaced; the coordinator still
/// holds the live branches.
///
/// Guards (parity of the Swift throws):
///   - `RecipeError::SilentConceptLoss` if `winner_plan_name` names a plan the
///     C-13 gate disqualified (C-5: a disqualified plan is never promoted).
///   - `RecipeError::UserConfirmationRequired` if `winner_plan_name` names no
///     plan in the report.
pub fn confirm_migration_promotion(
    coord: &mut EstateCoordinator,
    report: &CoreReport,
    winner_plan_name: &str,
    handle: &EstateHandle,
    now: i64,
) -> Result<(), RecipeRunError> {
    // C-5: never promote a disqualified plan. The branch id comes from
    // plan_results (DisqualifiedCore carries only name + lost_concepts).
    if let Some(dq) = report
        .disqualified
        .iter()
        .find(|d| d.name == winner_plan_name)
    {
        let branch_id = report
            .plan_results
            .iter()
            .find(|p| p.name == winner_plan_name)
            .map(|p| p.branch_id.clone())
            .unwrap_or_default();
        return Err(RecipeError::SilentConceptLoss {
            branch_id,
            lost_concepts: dq.lost_concepts.clone(),
        }
        .into());
    }

    // Resolve the winner plan's branch; an unknown plan is a confirmation
    // error (the human is naming a branch the report never produced).
    let winner = report
        .plan_results
        .iter()
        .find(|p| p.name == winner_plan_name)
        .ok_or_else(|| RecipeError::UserConfirmationRequired {
            action: format!("promote unknown plan '{winner_plan_name}'"),
        })?;
    let winner_bid = parse_branch_id(&winner.branch_id)?;
    coord
        .glk_promote_branch(winner_bid, handle, now)
        .map_err(|e| SubstrateError::new("promote_branch", format!("{e:?}")))?;

    // Discard the losers; their rows are retained for audit (I-15).
    for pr in &report.plan_results {
        if pr.name != winner_plan_name {
            if let Ok(bid) = parse_branch_id(&pr.branch_id) {
                let _ = coord.glk_discard_branch(bid);
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::migration_orchestration::{run_migration_benchmark, OriginEntry, PlanInput};
    use locus_kit::drawer_store::DrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::OwnerCredentials;
    use locus_kit::filter::{Filter, HydrationLevel, Ordering, RecallFrame};
    use uuid::Uuid;

    const NOW: i64 = 1_700_000_000;

    /// Recall all unconfirmed rows from an estate — used to inspect the parent
    /// after a promotion.
    fn all_frame() -> RecallFrame {
        let mut f = RecallFrame::new(vec![Filter::Unconfirmed]);
        f.hydration_level = HydrationLevel::Structured;
        f.ordering = Ordering::ByCaptureTimeDesc;
        f
    }

    fn coord_with_parent() -> (EstateCoordinator, EstateHandle) {
        let mut coord = EstateCoordinator::new();
        // InMemoryDrawerStore::new allocates InMemoryStorage internally.
        let store: Arc<dyn DrawerStore> =
            Arc::new(InMemoryDrawerStore::new(NOW, None).unwrap());
        let h = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .unwrap();
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
            .map(|(id, c)| OriginEntry {
                id: id.to_string(),
                content: c.to_string(),
            })
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
        assert!(
            report.disqualified.is_empty(),
            "nothing lost ⇒ not disqualified"
        );
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
            report.disqualified[0]
                .lost_concepts
                .contains(&"e3".to_string()),
            "the dropped concept is the C-13 loss: {:?}",
            report.disqualified[0].lost_concepts
        );
        // The per-plan result still records the lost concept.
        assert!(report.plan_results[0].lost.contains(&"e3".to_string()));
    }

    // CK-LIVE-3: confirm_migration_promotion actually promotes the winner's
    // post-derivation rows into the parent estate (B-3 gated second step).
    // The parent was empty before; after promotion it holds the migrated rows.
    #[test]
    fn ck_live3_confirm_promotes_winner_into_parent() {
        let (mut coord, h) = coord_with_parent();
        let plans = vec![plan("flat")];
        let origin = origin(&[("e1", "alpha"), ("e2", "beta")]);

        let report = {
            let mut sub = LiveRecipeSubstrate::new(&mut coord, h, NOW);
            run_migration_benchmark(&mut sub, &plans, &origin).expect("run")
        };
        assert_eq!(report.winner.as_deref(), Some("flat"));
        // Parent is still empty before confirmation (run never promotes).
        assert_eq!(coord.recall(&h, all_frame(), NOW).unwrap().len(), 0);

        confirm_migration_promotion(&mut coord, &report, "flat", &h, NOW).expect("promote");
        // The two migrated concepts are now in the parent estate.
        assert_eq!(coord.recall(&h, all_frame(), NOW).unwrap().len(), 2);
    }

    // CK-LIVE-4: confirming a DISQUALIFIED plan raises SilentConceptLoss
    // (C-5) — a plan the C-13 gate dropped is never promoted.
    #[test]
    fn ck_live4_confirm_disqualified_is_silent_concept_loss() {
        let (mut coord, h) = coord_with_parent();
        let plans = vec![plan("flat")];
        let origin = origin(&[("e1", "alpha"), ("e3", "")]); // e3 dropped

        let report = {
            let mut sub = LiveRecipeSubstrate::new(&mut coord, h, NOW);
            run_migration_benchmark(&mut sub, &plans, &origin).expect("run")
        };
        let err = confirm_migration_promotion(&mut coord, &report, "flat", &h, NOW).unwrap_err();
        match err {
            RecipeRunError::Recipe(RecipeError::SilentConceptLoss { lost_concepts, .. }) => {
                assert!(lost_concepts.contains(&"e3".to_string()));
            }
            other => panic!("expected SilentConceptLoss, got {other:?}"),
        }
        // Nothing was promoted (the disqualified branch's rows stay isolated).
        assert_eq!(coord.recall(&h, all_frame(), NOW).unwrap().len(), 0);
    }

    // CK-LIVE-5: confirming a plan the report never produced raises
    // UserConfirmationRequired (the human named an unknown branch).
    #[test]
    fn ck_live5_confirm_unknown_plan_requires_confirmation() {
        let (mut coord, h) = coord_with_parent();
        let plans = vec![plan("flat")];
        let origin = origin(&[("e1", "alpha")]);

        let report = {
            let mut sub = LiveRecipeSubstrate::new(&mut coord, h, NOW);
            run_migration_benchmark(&mut sub, &plans, &origin).expect("run")
        };
        let err =
            confirm_migration_promotion(&mut coord, &report, "ghost-plan", &h, NOW).unwrap_err();
        match err {
            RecipeRunError::Recipe(RecipeError::UserConfirmationRequired { action }) => {
                assert!(action.contains("ghost-plan"));
            }
            other => panic!("expected UserConfirmationRequired, got {other:?}"),
        }
    }

    // -------------------------------------------------------------------------
    // By-id overload tests (confirm_migration_promotion_by_id)
    // -------------------------------------------------------------------------

    // CK-LIVE-6: success — run the benchmark, pull winner branch id, call the
    // by-id overload with correct ids, assert Ok and the promoted rows appear
    // in the parent estate. Same assertion style as CK-LIVE-3.
    #[test]
    fn ck_live6_by_id_success_promotes_winner_into_parent() {
        let (mut coord, h) = coord_with_parent();
        let plans = vec![plan("flat")];
        let origin = origin(&[("e1", "alpha"), ("e2", "beta")]);

        let report = {
            let mut sub = LiveRecipeSubstrate::new(&mut coord, h, NOW);
            run_migration_benchmark(&mut sub, &plans, &origin).expect("run")
        };
        assert_eq!(report.winner.as_deref(), Some("flat"));

        // Pull winner branch id from the report.
        let winner_id_str = report
            .plan_results
            .iter()
            .find(|p| p.name == "flat")
            .map(|p| p.branch_id.clone())
            .expect("flat plan result");
        let winner_bid: BranchId = Uuid::parse_str(&winner_id_str).expect("uuid");

        // Parent is empty before confirmation.
        assert_eq!(coord.recall(&h, all_frame(), NOW).unwrap().len(), 0);

        confirm_migration_promotion_by_id(
            &mut coord,
            winner_bid,
            &[], // no other branches to discard
            &[], // no disqualified ids
            &h,
            NOW,
        )
        .expect("by-id promote");

        // The two migrated concepts appear in the parent estate after promotion.
        assert_eq!(coord.recall(&h, all_frame(), NOW).unwrap().len(), 2);
    }

    // CK-LIVE-7: winner id is in the disqualified set → SilentConceptLoss (C-5).
    // The by-id shape returns an empty lost_concepts vec (no concept detail
    // available from ids alone).
    #[test]
    fn ck_live7_by_id_disqualified_winner_is_silent_concept_loss() {
        let (mut coord, h) = coord_with_parent();
        let plans = vec![plan("flat")];
        let origin = origin(&[("e1", "alpha"), ("e3", "")]); // e3 dropped → disqualified

        let report = {
            let mut sub = LiveRecipeSubstrate::new(&mut coord, h, NOW);
            run_migration_benchmark(&mut sub, &plans, &origin).expect("run")
        };

        let winner_id_str = report
            .plan_results
            .iter()
            .find(|p| p.name == "flat")
            .map(|p| p.branch_id.clone())
            .expect("flat plan result");
        let winner_bid: BranchId = Uuid::parse_str(&winner_id_str).expect("uuid");

        // Treat winner as disqualified — passes the id in disqualified_branch_ids.
        let err = confirm_migration_promotion_by_id(
            &mut coord,
            winner_bid,
            &[],
            &[winner_bid], // winner is disqualified
            &h,
            NOW,
        )
        .unwrap_err();

        match err {
            RecipeRunError::Recipe(RecipeError::SilentConceptLoss {
                branch_id,
                lost_concepts,
            }) => {
                // branch_id is the winner's UUID string; lost_concepts is empty
                // because the by-id path carries no concept detail.
                assert_eq!(branch_id, winner_id_str);
                assert!(
                    lost_concepts.is_empty(),
                    "by-id path carries no lost-concept detail; got: {lost_concepts:?}"
                );
            }
            other => panic!("expected SilentConceptLoss, got {other:?}"),
        }
        // Nothing was promoted.
        assert_eq!(coord.recall(&h, all_frame(), NOW).unwrap().len(), 0);
    }

    // CK-LIVE-8: a random UUID not in the coordinator's registry →
    // UserConfirmationRequired (guard 2 fires before glk_promote_branch).
    #[test]
    fn ck_live8_by_id_unknown_winner_requires_confirmation() {
        let (mut coord, h) = coord_with_parent();
        let unknown_bid = Uuid::new_v4(); // not minted by any derive

        let err = confirm_migration_promotion_by_id(&mut coord, unknown_bid, &[], &[], &h, NOW)
            .unwrap_err();

        match err {
            RecipeRunError::Recipe(RecipeError::UserConfirmationRequired { action }) => {
                assert!(
                    action.contains(&unknown_bid.to_string()),
                    "action should name the unknown id; got: {action}"
                );
            }
            other => panic!("expected UserConfirmationRequired, got {other:?}"),
        }
    }

    // CK-LIVE-7b: guard ORDER proof — a winner id that is BOTH unknown to
    // the coordinator AND in the disqualified set raises SilentConceptLoss,
    // not UserConfirmationRequired: the C-5 membership guard runs before
    // id resolution (an inverted implementation would resolve first, get
    // None, and raise the wrong variant).
    #[test]
    fn ck_live7b_by_id_disqualified_unknown_winner_is_still_concept_loss() {
        let (mut coord, h) = coord_with_parent();
        let unknown_bid = Uuid::new_v4(); // never minted, AND disqualified

        let err = confirm_migration_promotion_by_id(
            &mut coord,
            unknown_bid,
            &[],
            &[unknown_bid],
            &h,
            NOW,
        )
        .unwrap_err();

        match err {
            RecipeRunError::Recipe(RecipeError::SilentConceptLoss { branch_id, .. }) => {
                assert_eq!(branch_id, unknown_bid.to_string());
            }
            other => panic!("expected SilentConceptLoss (C-5 precedes resolution), got {other:?}"),
        }
    }

    // CK-LIVE-9: a bogus id in discard_branch_ids is skipped silently —
    // the overall call still returns Ok.
    #[test]
    fn ck_live9_by_id_bogus_discard_id_is_skipped_silently() {
        let (mut coord, h) = coord_with_parent();
        let plans = vec![plan("flat")];
        let origin = origin(&[("e1", "alpha")]);

        let report = {
            let mut sub = LiveRecipeSubstrate::new(&mut coord, h, NOW);
            run_migration_benchmark(&mut sub, &plans, &origin).expect("run")
        };

        let winner_id_str = report
            .plan_results
            .iter()
            .find(|p| p.name == "flat")
            .map(|p| p.branch_id.clone())
            .expect("flat plan result");
        let winner_bid: BranchId = Uuid::parse_str(&winner_id_str).expect("uuid");
        let bogus_bid = Uuid::new_v4(); // not tracked by coordinator

        // Include one bogus discard id — must not error.
        confirm_migration_promotion_by_id(
            &mut coord,
            winner_bid,
            &[bogus_bid], // bogus; glk_discard_branch will return Err, skipped
            &[],
            &h,
            NOW,
        )
        .expect("bogus discard id must be skipped silently");

        // Promotion still happened.
        assert_eq!(coord.recall(&h, all_frame(), NOW).unwrap().len(), 1);
    }
}
