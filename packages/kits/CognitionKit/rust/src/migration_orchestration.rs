//! The portable orchestration of MigrationBenchmark — Rust port of the
//! Swift `MigrationOrchestration` in
//! `CognitionKit/Sources/CognitionKit/MigrationOrchestration.swift`.
//!
//! This is CognitionKit's Rust-parity Pass 2. The recipe BODY cannot run
//! live in Rust — the Rust LocusKit estate does not exist (every Rust GLK
//! verb is stubbed) and building it is the substrate missions' lane. But
//! the recipe's *sequencing logic* — the call order (derive → capture-each
//! → benchmark, per plan) and how it threads minted ids + benchmark
//! results into the ranked report — IS portable. The three substrate
//! operations are abstracted behind the `RecipeSubstrate` trait; the
//! orchestration is a pure function of (substrate, plans, origin).
//!
//! Every DECISION (C-13 gate, combined-score, ranking, tie-break,
//! duplicate-plan guard, lost-concept union) is delegated to
//! `crate::migration_ranking`, which is already conformance-gated. So this
//! module adds only the portable call sequence, and the `#[cfg(test)]`
//! block below mirrors the Swift `MigrationOrchestrationTests` fixtures
//! SEAM-1..3 exactly — same inputs, same recorded call sequence, same
//! assembled report, same deterministic minted ids.
//!
//! Live-estate execution still waits on the Rust LocusKit estate; a live
//! adapter conforming to `RecipeSubstrate` is a future bridge.

use crate::error::RecipeError;
use crate::migration_ranking::{
    lost_concepts, rank, DisqualifiedCore, PlanOutcome, RankedPlan,
};

/// One origin reference entry — `(id, content)`, estate-free.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OriginEntry {
    pub id: String,
    pub content: String,
}

/// One candidate plan's parameters, estate-free.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanInput {
    pub name: String,
    pub room: String,
    pub lattice_code: String,
    pub embedding_model_id: String,
    pub sensitivity: i64,
}

/// A captured entry keyed by its minted drawer id — what `benchmark`
/// scores against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CorpusEntry {
    pub id: String,
    pub content: String,
}

/// The recall-fidelity outcome a substrate returns for one branch.
/// `not_found` is keyed by minted (corpus) id.
#[derive(Debug, Clone, PartialEq)]
pub struct BenchmarkOutcome {
    pub recall_overlap: f32,
    pub mean_reciprocal_rank: f32,
    pub not_found: Vec<String>,
}

/// The three substrate operations a migration recipe sequences. A live
/// adapter (a future bridge over the real estate) and the deterministic
/// test fake both implement it; the orchestration neither knows nor cares
/// which. Mirrors the Swift `RecipeSubstrate` protocol.
pub trait RecipeSubstrate {
    /// Derive a COW branch for `plan_name`; return its branch id.
    fn derive_branch(&mut self, plan_name: &str) -> String;

    /// Capture one entry into `branch_id`; return the MINTED drawer id.
    fn capture(
        &mut self,
        branch_id: &str,
        content: &str,
        room: &str,
        lattice_code: &str,
        embedding_model_id: &str,
        sensitivity: i64,
    ) -> String;

    /// Benchmark `branch_id` against `corpus`; return the outcome.
    fn benchmark(&mut self, branch_id: &str, corpus: &[CorpusEntry]) -> BenchmarkOutcome;
}

/// One plan's full per-plan result, in input order. Mirrors Swift
/// `MigrationOrchestration.PlanResultCore`.
#[derive(Debug, Clone, PartialEq)]
pub struct PlanResultCore {
    pub name: String,
    pub branch_id: String,
    pub recall_overlap: f32,
    pub mean_reciprocal_rank: f32,
    pub lost: Vec<String>,
}

/// The assembled orchestration report. Mirrors Swift
/// `MigrationOrchestration.CoreReport`.
#[derive(Debug, Clone, PartialEq)]
pub struct CoreReport {
    pub plan_results: Vec<PlanResultCore>,
    pub rankings: Vec<RankedPlan>,
    pub disqualified: Vec<DisqualifiedCore>,
    pub winner: Option<String>,
}

/// Run the migration-benchmark orchestration over `substrate`.
///
/// Sequence, per plan in input order: derive a branch, capture each
/// migratable origin entry (recording the minted id), benchmark the
/// branch against the id-correlated corpus, compute the lost set. Then
/// `migration_ranking::rank` applies the C-13 gate and ranks survivors.
///
/// Errors mirror the production guards: `DuplicatePlanName` on a repeated
/// plan name, `InsufficientBranches { minimum: 1, provided: 0 }` on empty
/// `plans`. Both are raised BEFORE any substrate call.
pub fn run_migration_benchmark<S: RecipeSubstrate>(
    substrate: &mut S,
    plans: &[PlanInput],
    origin: &[OriginEntry],
) -> Result<CoreReport, RecipeError> {
    if plans.is_empty() {
        return Err(RecipeError::InsufficientBranches {
            minimum: 1,
            provided: 0,
        });
    }
    let names: Vec<String> = plans.iter().map(|p| p.name.clone()).collect();
    if let Some(dup) = crate::migration_ranking::first_duplicate(&names) {
        return Err(RecipeError::DuplicatePlanName(dup));
    }

    // Partition the origin ONCE — migratable vs dropped is plan-independent.
    let mut migratable: Vec<&OriginEntry> = Vec::new();
    let mut dropped: Vec<String> = Vec::new();
    for entry in origin {
        if entry.content.trim().is_empty() {
            dropped.push(entry.id.clone());
        } else {
            migratable.push(entry);
        }
    }

    let mut plan_results: Vec<PlanResultCore> = Vec::with_capacity(plans.len());
    let mut outcomes: Vec<PlanOutcome> = Vec::with_capacity(plans.len());
    for plan in plans {
        let branch_id = substrate.derive_branch(&plan.name);
        let mut corpus: Vec<CorpusEntry> = Vec::with_capacity(migratable.len());
        for entry in &migratable {
            let minted = substrate.capture(
                &branch_id,
                &entry.content,
                &plan.room,
                &plan.lattice_code,
                &plan.embedding_model_id,
                plan.sensitivity,
            );
            corpus.push(CorpusEntry {
                id: minted,
                content: entry.content.clone(),
            });
        }
        let outcome = substrate.benchmark(&branch_id, &corpus);
        let lost = lost_concepts(&dropped, &outcome.not_found);
        plan_results.push(PlanResultCore {
            name: plan.name.clone(),
            branch_id,
            recall_overlap: outcome.recall_overlap,
            mean_reciprocal_rank: outcome.mean_reciprocal_rank,
            lost: lost.clone(),
        });
        outcomes.push(PlanOutcome {
            name: plan.name.clone(),
            recall_overlap: outcome.recall_overlap,
            mean_reciprocal_rank: outcome.mean_reciprocal_rank,
            lost,
        });
    }

    let ranked = rank(&outcomes);
    Ok(CoreReport {
        plan_results,
        rankings: ranked.rankings,
        disqualified: ranked.disqualified,
        winner: ranked.winner,
    })
}

#[cfg(test)]
mod tests {
    //! Conformance fixtures — mirror Swift `MigrationOrchestrationTests`
    //! (SEAM-1..3 + guards). Same inputs, same recorded call sequence,
    //! same deterministic minted ids ("branch-<plan>",
    //! "drawer-<branchID>-<index>"), same assembled report.
    use super::*;
    use std::collections::HashSet;

    /// Deterministic in-memory substrate. Records every call so the test
    /// asserts the exact orchestration sequence. Identical to the Swift
    /// `FakeSubstrate`.
    struct FakeSubstrate {
        calls: Vec<String>,
        unrecallable: HashSet<String>,
        capture_count: std::collections::HashMap<String, usize>,
    }

    impl FakeSubstrate {
        fn new(unrecallable: &[&str]) -> Self {
            Self {
                calls: Vec::new(),
                unrecallable: unrecallable.iter().map(|s| s.to_string()).collect(),
                capture_count: std::collections::HashMap::new(),
            }
        }
    }

    impl RecipeSubstrate for FakeSubstrate {
        fn derive_branch(&mut self, plan_name: &str) -> String {
            self.calls.push(format!("derive:{}", plan_name));
            format!("branch-{}", plan_name)
        }

        fn capture(
            &mut self,
            branch_id: &str,
            content: &str,
            _room: &str,
            _lattice_code: &str,
            _embedding_model_id: &str,
            _sensitivity: i64,
        ) -> String {
            let n = *self.capture_count.get(branch_id).unwrap_or(&0);
            self.capture_count.insert(branch_id.to_string(), n + 1);
            self.calls.push(format!("capture:{}:{}", branch_id, content));
            format!("drawer-{}-{}", branch_id, n)
        }

        fn benchmark(&mut self, branch_id: &str, corpus: &[CorpusEntry]) -> BenchmarkOutcome {
            self.calls.push(format!("benchmark:{}", branch_id));
            let not_found: Vec<String> = corpus
                .iter()
                .filter(|e| self.unrecallable.contains(&e.content))
                .map(|e| e.id.clone())
                .collect();
            let total = corpus.len();
            let found = total - not_found.len();
            let overlap = if total == 0 {
                0.0
            } else {
                found as f32 / total as f32
            };
            let mrr = if found == 0 { 0.0 } else { 1.0 };
            BenchmarkOutcome {
                recall_overlap: overlap,
                mean_reciprocal_rank: mrr,
                not_found,
            }
        }
    }

    fn plan(name: &str, room: &str, code: &str) -> PlanInput {
        PlanInput {
            name: name.into(),
            room: room.into(),
            lattice_code: code.into(),
            embedding_model_id: "test-v1".into(),
            sensitivity: 0,
        }
    }

    fn origin(pairs: &[(&str, &str)]) -> Vec<OriginEntry> {
        pairs
            .iter()
            .map(|(id, content)| OriginEntry {
                id: id.to_string(),
                content: content.to_string(),
            })
            .collect()
    }

    // SEAM-1 — clean, two plans: full sequence + tie-break ranking
    #[test]
    fn seam1_clean_two_plans() {
        let mut fake = FakeSubstrate::new(&[]);
        let report = run_migration_benchmark(
            &mut fake,
            &[plan("flat", "r1", "000"), plan("nested", "r2", "100")],
            &origin(&[("a", "alpha"), ("b", "beta")]),
        )
        .unwrap();

        assert_eq!(
            fake.calls,
            vec![
                "derive:flat",
                "capture:branch-flat:alpha",
                "capture:branch-flat:beta",
                "benchmark:branch-flat",
                "derive:nested",
                "capture:branch-nested:alpha",
                "capture:branch-nested:beta",
                "benchmark:branch-nested",
            ]
        );
        assert!(report.disqualified.is_empty());
        assert_eq!(
            report.rankings.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(),
            vec!["flat", "nested"]
        );
        assert_eq!(report.winner, Some("flat".to_string()));
        assert_eq!(
            report.plan_results.iter().map(|p| p.branch_id.as_str()).collect::<Vec<_>>(),
            vec!["branch-flat", "branch-nested"]
        );
        assert!((report.plan_results[0].recall_overlap - 1.0).abs() < 1e-6);
    }

    // SEAM-2 — empty-content entry dropped (never captured) -> disqualified
    #[test]
    fn seam2_empty_content_dropped() {
        let mut fake = FakeSubstrate::new(&[]);
        let report = run_migration_benchmark(
            &mut fake,
            &[plan("only", "r1", "000")],
            &origin(&[("good", "valid"), ("blank", "   ")]),
        )
        .unwrap();

        assert_eq!(
            fake.calls,
            vec![
                "derive:only",
                "capture:branch-only:valid",
                "benchmark:branch-only",
            ]
        );
        assert!(report.rankings.is_empty());
        assert_eq!(report.winner, None);
        assert_eq!(
            report.disqualified.iter().map(|d| d.name.as_str()).collect::<Vec<_>>(),
            vec!["only"]
        );
        assert_eq!(report.disqualified[0].lost_concepts, vec!["blank".to_string()]);
    }

    // SEAM-3 — benchmark marks one captured entry unrecallable
    #[test]
    fn seam3_benchmark_not_found() {
        let mut fake = FakeSubstrate::new(&["beta"]);
        let report = run_migration_benchmark(
            &mut fake,
            &[plan("p", "r1", "000")],
            &origin(&[("a", "alpha"), ("b", "beta")]),
        )
        .unwrap();

        assert_eq!(
            fake.calls,
            vec![
                "derive:p",
                "capture:branch-p:alpha",
                "capture:branch-p:beta",
                "benchmark:branch-p",
            ]
        );
        assert!(report.rankings.is_empty());
        assert_eq!(
            report.disqualified.iter().map(|d| d.name.as_str()).collect::<Vec<_>>(),
            vec!["p"]
        );
        // "beta" captured second -> minted id "drawer-branch-p-1".
        assert_eq!(
            report.disqualified[0].lost_concepts,
            vec!["drawer-branch-p-1".to_string()]
        );
    }

    #[test]
    fn empty_plans_throws_before_any_call() {
        let mut fake = FakeSubstrate::new(&[]);
        let err = run_migration_benchmark(&mut fake, &[], &[]).unwrap_err();
        assert_eq!(
            err,
            RecipeError::InsufficientBranches {
                minimum: 1,
                provided: 0
            }
        );
        assert!(fake.calls.is_empty());
    }

    #[test]
    fn duplicate_plan_name_throws_before_any_call() {
        let mut fake = FakeSubstrate::new(&[]);
        let err = run_migration_benchmark(
            &mut fake,
            &[plan("dup", "r1", "000"), plan("dup", "r2", "100")],
            &origin(&[("a", "x")]),
        )
        .unwrap_err();
        assert_eq!(err, RecipeError::DuplicatePlanName("dup".to_string()));
        assert!(fake.calls.is_empty());
    }
}
