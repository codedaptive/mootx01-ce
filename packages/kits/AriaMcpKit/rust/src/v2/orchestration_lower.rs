//! Direct selected-surface adapter for the four typed orchestration operations.
//!
//! This is deliberately a lower-engine adapter.  It does not invoke the v1
//! dispatcher, tool runner, transport payloads, or rendered output.  The
//! selected estate is fixed at construction, and every operation revalidates
//! that identity before touching a lower kit.

use std::collections::{HashMap, HashSet};

use cognition_kit::{
    migration_live::{discard_disqualified_branches, LiveRecipeSubstrate},
    migration_ranking::lost_concepts,
    run_grounded_synthesis_with_provenance_gate_and_scoring, run_migration_benchmark, OriginEntry,
    PlanInput,
};
use genius_locus_kit::{
    branches::BranchStatus,
    coordinator::FederatedReadRefusalReason,
    EstateCoordinator, EstateHandle, GeniusLocusKitError,
};
use locus_kit::{
    adjectives::AdjectiveSensitivity,
    filter::{Filter, HydrationLevel, Ordering, RecallFrame},
};
use neuron_kit::{benchmark_branch, BenchmarkReport as LowerBenchmarkReport, RecallFrameTuning};
use uuid::Uuid;

use crate::estate_registry::EstateRegistry;

use super::orchestration::{
    V2BenchmarkReport, V2CompactMemory, V2ConfirmMigrationRequest, V2DiscardOutcome,
    V2DiscardOutcomeStatus, V2DisqualifiedMigration, V2FederatedSearchData,
    V2FederatedSearchRequest, V2MigrationConfirmationData, V2MigrationData,
    V2MigrationRanking, V2OrchestrationFailure, V2OrchestrationProvider, V2RunMigrationRequest,
    V2SynthesisData, V2SynthesizeRequest,
};

const DEFAULT_LIMIT: usize = 20;

/// Adapter over the registry's selected default estate.  It admits no direct
/// route to an additional estate: federation is the only cross-estate read.
pub struct SelectedOrchestrationLower<'a> {
    registry: &'a EstateRegistry,
}

impl<'a> SelectedOrchestrationLower<'a> {
    pub fn new(registry: &'a EstateRegistry) -> Self {
        Self { registry }
    }

    fn selected(&self, selected_estate_id: Uuid) -> Result<EstateHandle, V2OrchestrationFailure> {
        if selected_estate_id != self.registry.default.estate_id {
            return Err(V2OrchestrationFailure::EstateUnavailable);
        }
        Ok(self.registry.default.handle)
    }

    /// Bind federation sources to the estates already opened in this local
    /// registry. Source selection never inspects corpus content, and the
    /// selected requester is excluded so a self read cannot produce a
    /// federated receipt.
    fn registered_peer_handles(&self, requester: EstateHandle) -> Vec<EstateHandle> {
        let requester_id = Uuid::from_bytes(requester.estate_uuid);
        let mut peers: Vec<_> = self
            .registry
            .extras
            .values()
            .filter(|estate| Uuid::from_bytes(estate.handle.estate_uuid) != requester_id)
            .map(|estate| estate.handle)
            .collect();
        peers.sort_by_key(|handle| Uuid::from_bytes(handle.estate_uuid).to_string());
        peers
    }

    fn now_millis() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64
    }

    fn filter(value: Option<&str>) -> Result<Vec<Filter>, V2OrchestrationFailure> {
        use locus_kit::drawer_operational::DrawerFeatureFlags;

        match value {
            None => Ok(Vec::new()),
            Some("unconfirmed") => Ok(vec![Filter::Unconfirmed]),
            Some("userConfirmed") => Ok(vec![Filter::UserConfirmed]),
            Some("exportable") => Ok(vec![Filter::Exportable]),
            Some("contained") => Ok(vec![Filter::Contained]),
            Some("currentlyBelieve") => Ok(vec![Filter::CurrentlyBelieve]),
            Some("pinned") => Ok(vec![Filter::HasFeatureFlag(DrawerFeatureFlags::IS_PINNED)]),
            Some("hasLinks") => Ok(vec![Filter::HasFeatureFlag(DrawerFeatureFlags::HAS_LINKS)]),
            Some(_) => Err(V2OrchestrationFailure::LowerUnavailable),
        }
    }

    fn grounding_terms(query: &str) -> Vec<String> {
        // This is the typed equivalent of GroundedSynthesis's caller-side cue
        // selection. It is local request preparation, never a v1 dispatch call.
        const STOPWORDS: &[&str] = &[
            "the", "and", "for", "are", "was", "were", "has", "have", "had", "did", "does", "not",
            "with", "that", "this", "from", "they", "their", "them", "then", "than", "there", "these",
            "those", "you", "your", "what", "when", "where", "which", "who", "whom", "why", "how",
            "will", "would", "could", "should", "about", "been", "being", "into", "over", "under", "after",
            "before", "between", "during", "any", "all", "each", "most", "some", "such", "can", "may",
            "might", "must", "shall", "its", "his", "her", "him", "she", "our", "out", "but", "per",
            "via", "also", "just", "only", "very", "much", "more",
        ];
        let mut terms = Vec::new();
        for raw in query.split(|character: char| !character.is_alphanumeric()) {
            let term = raw.to_lowercase();
            if term.is_empty()
                || (term.chars().count() < 3 && !term.chars().any(|character| character.is_numeric()))
                || STOPWORDS.contains(&term.as_str())
                || terms.contains(&term)
            {
                continue;
            }
            terms.push(term);
            if terms.len() == 12 {
                break;
            }
        }
        terms
    }

    fn compact_memory(drawer: &locus_kit::drawer::Drawer) -> Result<V2CompactMemory, V2OrchestrationFailure> {
        if !Self::public_capture_provenance(drawer.provenance) {
            return Err(V2OrchestrationFailure::LowerUnavailable);
        }
        Ok(V2CompactMemory {
            memory_id: Uuid::parse_str(&drawer.id).map_err(|_| V2OrchestrationFailure::LowerUnavailable)?,
            subject: drawer.subject.clone(),
            score: None,
            provenance: Some(format!("{:?}", drawer.source_type()).to_lowercase()),
            context: None,
            excerpt: (!drawer.content.is_empty()).then(|| drawer.content.chars().take(512).collect()),
        })
    }

    fn public_capture_provenance(provenance: i64) -> bool {
        matches!((provenance >> 30) & 0x3f, 0 | 16)
    }

    fn node_names(
        coordinator: &EstateCoordinator,
        handle: &EstateHandle,
    ) -> Result<HashMap<String, (String, String)>, V2OrchestrationFailure> {
        let drawers = coordinator
            .all_drawers(handle)
            .map_err(|_| V2OrchestrationFailure::LowerUnavailable)?;
        let node_ids: Vec<_> = drawers.into_iter().map(|drawer| drawer.parent_node_id).collect();
        Ok(coordinator.resolve_drawer_node_names(handle, &node_ids))
    }

    fn sensitivity(value: Option<&str>) -> Result<i64, V2OrchestrationFailure> {
        match value {
            None | Some("normal") => Ok(AdjectiveSensitivity::Normal.raw_value()),
            Some("elevated") => Ok(AdjectiveSensitivity::Elevated.raw_value()),
            Some("restricted") => Ok(AdjectiveSensitivity::Restricted.raw_value()),
            Some("secret") => Ok(AdjectiveSensitivity::Secret.raw_value()),
            Some(_) => Err(V2OrchestrationFailure::LowerUnavailable),
        }
    }

    fn migration_data(
        report: cognition_kit::migration_orchestration::CoreReport,
        reports: Vec<LowerBenchmarkReport>,
    ) -> Result<V2MigrationData, V2OrchestrationFailure> {
        let branch_id_for = |plan_name: &str| {
            report
                .plan_results
                .iter()
                .find(|result| result.name == plan_name)
                .ok_or(V2OrchestrationFailure::LowerUnavailable)
                .and_then(|result| {
                    Uuid::parse_str(&result.branch_id).map_err(|_| V2OrchestrationFailure::LowerUnavailable)
                })
        };
        let rankings = report
            .rankings
            .iter()
            .map(|ranking| {
                Ok(V2MigrationRanking {
                    branch_id: branch_id_for(&ranking.name)?,
                    plan_name: ranking.name.clone(),
                    combined_score: ranking.combined_score as f64,
                    recall_overlap: ranking.recall_overlap as f64,
                    mean_reciprocal_rank: ranking.mean_reciprocal_rank as f64,
                })
            })
            .collect::<Result<Vec<_>, V2OrchestrationFailure>>()?;
        let disqualified = report
            .disqualified
            .iter()
            .map(|disqualified| {
                Ok(V2DisqualifiedMigration {
                    branch_id: branch_id_for(&disqualified.name)?,
                    plan_name: disqualified.name.clone(),
                    lost_concepts: disqualified.lost_concepts.clone(),
                })
            })
            .collect::<Result<Vec<_>, V2OrchestrationFailure>>()?;
        let winner_branch_id = report.winner.as_deref().map(branch_id_for).transpose()?;
        let reports = reports
            .into_iter()
            .map(|report| {
                Ok(V2BenchmarkReport {
                    branch_id: Uuid::parse_str(&report.branch_id)
                        .map_err(|_| V2OrchestrationFailure::LowerUnavailable)?,
                    query_count: report.query_count as u64,
                    recall_overlap: report.recall_overlap as f64,
                    recall_precision: report.recall_precision as f64,
                    mean_reciprocal_rank: report.mean_reciprocal_rank as f64,
                    not_found_in_branch: report.not_found_in_branch,
                    new_in_branch: report.new_in_branch,
                    evaluated_at: neuron_kit::topology_analysis::epoch_to_iso8601(report.evaluated_at),
                })
            })
            .collect::<Result<Vec<_>, V2OrchestrationFailure>>()?;
        Ok(V2MigrationData {
            reports,
            winner_branch_id,
            winner_plan_name: report.winner,
            rankings,
            disqualified,
        })
    }

    fn migration_query(content: &str) -> RecallFrame {
        let mut frame = RecallFrame::new(vec![
            Filter::Unconfirmed,
            Filter::ContentMatches(content.to_owned()),
        ]);
        frame.hydration_level = HydrationLevel::Structured;
        frame.ordering = Ordering::ByCaptureTimeDesc;
        frame
    }

    fn migration_full_frame() -> RecallFrame {
        let mut frame = RecallFrame::new(vec![Filter::Unconfirmed]);
        frame.hydration_level = HydrationLevel::Full;
        frame.ordering = Ordering::ByCaptureTimeDesc;
        frame
    }

    /// Re-read each newly minted branch through NeuronKit's public benchmark
    /// lower engine.  The migration core retains overlap/MRR and the C-13
    /// decision but intentionally drops precision, novelty, and the evaluation
    /// instant; this restores those values without parsing a legacy response.
    fn migration_reports(
        coordinator: &EstateCoordinator,
        report: &cognition_kit::migration_orchestration::CoreReport,
        origin: &[OriginEntry],
        now_millis: i64,
    ) -> Result<Vec<LowerBenchmarkReport>, V2OrchestrationFailure> {
        let migratable: Vec<_> = origin.iter().filter(|entry| !entry.content.trim().is_empty()).collect();
        let dropped: Vec<_> = origin
            .iter()
            .filter(|entry| entry.content.trim().is_empty())
            .map(|entry| entry.id.clone())
            .collect();
        let mut reports = Vec::with_capacity(report.plan_results.len());
        for plan in &report.plan_results {
            let branch_id = Uuid::parse_str(&plan.branch_id)
                .map_err(|_| V2OrchestrationFailure::LowerUnavailable)?;
            let branch = coordinator
                .branch_handle_for(branch_id)
                .ok_or(V2OrchestrationFailure::LowerUnavailable)?;
            let new_ids: HashSet<_> = branch
                .compare_to_parent(now_millis)
                .new_in_branch
                .into_iter()
                .collect();
            let newly_minted = branch
                .recall_with(Self::migration_full_frame(), now_millis)
                .into_iter()
                .filter(|drawer| new_ids.contains(&drawer.id))
                .collect::<Vec<_>>();
            let mut expected_ids = Vec::with_capacity(migratable.len());
            let mut query_frames = Vec::with_capacity(migratable.len());
            for entry in &migratable {
                let matching: Vec<_> = newly_minted
                    .iter()
                    .filter(|drawer| drawer.content == entry.content)
                    .collect();
                // A duplicate content body cannot be paired to one immutable
                // minted identity by the current lower interface. Refuse before
                // reporting a fabricated MRR correspondence.
                let [drawer] = matching.as_slice() else {
                    return Err(V2OrchestrationFailure::LowerUnavailable);
                };
                expected_ids.push(drawer.id.clone());
                query_frames.push(Self::migration_query(&entry.content));
            }
            let lower = benchmark_branch(branch, &expected_ids, query_frames, now_millis);
            let expected_lost = lost_concepts(&dropped, &lower.not_found_in_branch);
            if plan.lost != expected_lost
                || plan.recall_overlap != lower.recall_overlap
                || plan.mean_reciprocal_rank != lower.mean_reciprocal_rank
            {
                return Err(V2OrchestrationFailure::LowerUnavailable);
            }
            reports.push(lower);
        }
        Ok(reports)
    }

    fn discard(
        coordinator: &mut EstateCoordinator,
        branch_id: Uuid,
        winner_branch_id: Uuid,
        now_millis: i64,
    ) -> V2DiscardOutcome {
        if branch_id == winner_branch_id {
            return V2DiscardOutcome { branch_id, status: V2DiscardOutcomeStatus::WinnerSkipped };
        }
        let Some(branch) = coordinator.branch_handle_for(branch_id) else {
            return V2DiscardOutcome { branch_id, status: V2DiscardOutcomeStatus::Unknown };
        };
        if branch.status() == BranchStatus::Discarded {
            return V2DiscardOutcome { branch_id, status: V2DiscardOutcomeStatus::AlreadyDiscarded };
        }
        let discarded = coordinator.glk_discard_branch(branch_id, now_millis).is_ok()
            && coordinator
                .branch_handle_for(branch_id)
                .is_some_and(|branch| branch.status() == BranchStatus::Discarded);
        V2DiscardOutcome {
            branch_id,
            status: if discarded { V2DiscardOutcomeStatus::Discarded } else { V2DiscardOutcomeStatus::Failed },
        }
    }

    fn confirmed_data(promoted_branch_id: Uuid, discard_outcomes: Vec<V2DiscardOutcome>) -> V2MigrationConfirmationData {
        let discarded_branch_ids = discard_outcomes
            .iter()
            .filter_map(|outcome| {
                matches!(
                    outcome.status,
                    V2DiscardOutcomeStatus::Discarded | V2DiscardOutcomeStatus::AlreadyDiscarded
                )
                .then_some(outcome.branch_id)
            })
            .collect();
        V2MigrationConfirmationData { promoted_branch_id, discarded_branch_ids, discard_outcomes }
    }
}

impl V2OrchestrationProvider for SelectedOrchestrationLower<'_> {
    fn synthesize(
        &self,
        request: V2SynthesizeRequest,
        selected_estate_id: Uuid,
    ) -> Result<V2SynthesisData, V2OrchestrationFailure> {
        let handle = self.selected(selected_estate_id)?;
        let filter_chain = Self::filter(request.filter.as_deref())?;
        let limit = request.limit.unwrap_or(DEFAULT_LIMIT);
        let mut frame = RecallFrame::new(filter_chain);
        frame.hydration_level = HydrationLevel::Structured;
        frame.ordering = Ordering::ByCaptureTimeDesc;
        frame.limit = Some(limit);
        let cues = request.query.as_deref().map(Self::grounding_terms).unwrap_or_default();
        // A caller who SENT a cue must never receive an unscoped estate
        // digest: answering from the whole estate returns something that reads
        // like an answer to the question asked, which is worse than a refusal.
        if request.query.is_some() && cues.is_empty() {
            return Err(V2OrchestrationFailure::InvalidCue);
        }
        let now_millis = Self::now_millis();
        let coordinator = self.registry.default.coord.lock().map_err(|_| V2OrchestrationFailure::EstateUnavailable)?;
        let node_names = Self::node_names(&coordinator, &handle)?;
        let output = run_grounded_synthesis_with_provenance_gate_and_scoring(
            &coordinator,
            &handle,
            frame,
            RecallFrameTuning::default(),
            now_millis,
            &node_names,
            &cues,
            request.query.as_ref().map(|_| limit),
            request.query.as_deref(),
            genius_locus_kit::recall::GLKRecallScoring::MatrixAware,
        )
        .map_err(|_| V2OrchestrationFailure::LowerUnavailable)?;
        let ids: Vec<_> = output.ranked_ids.iter().map(String::as_str).collect();
        let rows = coordinator
            .get_drawers(&handle, &ids)
            .map_err(|_| V2OrchestrationFailure::LowerUnavailable)?;
        let mut rows_by_id = HashMap::with_capacity(rows.len());
        for row in &rows {
            if rows_by_id.insert(row.id.as_str(), row).is_some() {
                return Err(V2OrchestrationFailure::LowerUnavailable);
            }
        }
        let results = output
            .ranked_ids
            .iter()
            .map(|id| {
                rows_by_id
                    .get(id.as_str())
                    .ok_or(V2OrchestrationFailure::LowerUnavailable)
                    .and_then(|row| Self::compact_memory(row))
            })
            .collect::<Result<Vec<_>, V2OrchestrationFailure>>()?;
        Ok(V2SynthesisData {
            summary: output.context.summary,
            cues: (!cues.is_empty()).then_some(cues),
            results,
        })
    }

    fn run_migration(
        &self,
        request: V2RunMigrationRequest,
        selected_estate_id: Uuid,
    ) -> Result<V2MigrationData, V2OrchestrationFailure> {
        let handle = self.selected(selected_estate_id)?;
        let mut contents = HashSet::new();
        if request
            .entries
            .iter()
            .filter(|entry| !entry.content.trim().is_empty())
            .any(|entry| !contents.insert(entry.content.clone()))
        {
            return Err(V2OrchestrationFailure::LowerUnavailable);
        }
        let plans = request
            .plans
            .iter()
            .map(|plan| {
                Ok(PlanInput {
                    name: plan.name.clone(),
                    room: plan.room.clone(),
                    lattice_code: plan.lattice_code.clone(),
                    embedding_model_id: plan.embedding_model_id.clone(),
                    sensitivity: Self::sensitivity(plan.sensitivity.as_deref())?,
                })
            })
            .collect::<Result<Vec<_>, V2OrchestrationFailure>>()?;
        let origin = request
            .entries
            .iter()
            .map(|entry| OriginEntry { id: entry.id.clone(), content: entry.content.clone() })
            .collect::<Vec<_>>();
        let now_millis = Self::now_millis();
        let mut coordinator = self.registry.default.coord.lock().map_err(|_| V2OrchestrationFailure::EstateUnavailable)?;
        let mut substrate = LiveRecipeSubstrate::new(&mut coordinator, handle, now_millis);
        let report = run_migration_benchmark(&mut substrate, &plans, &origin)
            .map_err(|_| V2OrchestrationFailure::LowerUnavailable)?;
        drop(substrate);
        let reports = Self::migration_reports(&coordinator, &report, &origin, now_millis)?;
        discard_disqualified_branches(&mut coordinator, &report, now_millis);
        Self::migration_data(report, reports)
    }

    fn confirm_migration(
        &self,
        request: V2ConfirmMigrationRequest,
        selected_estate_id: Uuid,
    ) -> Result<V2MigrationConfirmationData, V2OrchestrationFailure> {
        let handle = self.selected(selected_estate_id)?;
        let now_millis = Self::now_millis();
        let mut coordinator = self.registry.default.coord.lock().map_err(|_| V2OrchestrationFailure::EstateUnavailable)?;
        match coordinator.branch_handle_for(request.winner_branch_id).map(|branch| branch.status()) {
            Some(BranchStatus::Active) => {}
            Some(BranchStatus::Discarded) => return Err(V2OrchestrationFailure::DisqualifiedBranch),
            Some(BranchStatus::Won | BranchStatus::Merged) => return Err(V2OrchestrationFailure::TerminalBranch),
            None => return Err(V2OrchestrationFailure::UnknownBranch),
        }
        coordinator
            .glk_promote_branch(request.winner_branch_id, &handle, now_millis)
            .map_err(|_| V2OrchestrationFailure::LowerUnavailable)?;
        if !matches!(
            coordinator.branch_handle_for(request.winner_branch_id).map(|branch| branch.status()),
            Some(BranchStatus::Won)
        ) {
            return Err(V2OrchestrationFailure::LowerUnavailable);
        }
        let winner_branch_id = request.winner_branch_id;
        let mut discard_outcomes = request
            .discard_branch_ids
            .into_iter()
            .map(|branch_id| Self::discard(&mut coordinator, branch_id, winner_branch_id, now_millis))
            .collect::<Vec<_>>();
        // V2 UUID enumerations are canonical byte order, independent of the
        // caller's input order.  This also matches the Swift lower receipt.
        discard_outcomes.sort_by(|left, right| {
            left.branch_id.as_bytes().cmp(right.branch_id.as_bytes())
        });
        // Promotion is already complete. A later cleanup failure is reported in
        // its own receipt entry and never erases the verified winner identity.
        Ok(Self::confirmed_data(winner_branch_id, discard_outcomes))
    }

    fn federated_search(
        &self,
        request: V2FederatedSearchRequest,
        selected_estate_id: Uuid,
    ) -> Result<V2FederatedSearchData, V2OrchestrationFailure> {
        if request.requester_estate_id.is_some_and(|estate_id| estate_id != selected_estate_id) {
            return Err(V2OrchestrationFailure::EstateUnavailable);
        }
        let requester_handle = self.selected(selected_estate_id)?;
        let mut frame = RecallFrame::new(Self::filter(request.filter.as_deref())?);
        frame.hydration_level = match request.hydration_level.as_deref() {
            None | Some("full") => HydrationLevel::Full,
            Some("structured") => HydrationLevel::Structured,
            Some("bitmapOnly") => HydrationLevel::BitmapOnly,
            Some(_) => return Err(V2OrchestrationFailure::LowerUnavailable),
        };
        frame.ordering = match request.ordering.as_deref() {
            None | Some("captureTimeDesc") => Ordering::ByCaptureTimeDesc,
            Some("captureTimeAsc") => Ordering::ByCaptureTimeAsc,
            Some(_) => return Err(V2OrchestrationFailure::LowerUnavailable),
        };
        frame.limit = Some(request.limit.unwrap_or(DEFAULT_LIMIT));
        let now_millis = Self::now_millis();
        let candidates = self.registered_peer_handles(requester_handle);
        if candidates.len() > 1 {
            return Err(V2OrchestrationFailure::FederatedAggregationRequired);
        }

        let mut coordinator = self.registry.default.coord.lock().map_err(|_| V2OrchestrationFailure::EstateUnavailable)?;
        let Some(source_handle) = candidates.into_iter().next() else {
            return Err(V2OrchestrationFailure::FederatedAccessUnavailable);
        };
        let result = match coordinator.federated_recall(
            frame,
            &source_handle,
            &requester_handle,
            now_millis as f64,
            now_millis,
        ) {
            Ok(result) => result,
            Err(GeniusLocusKitError::CrossEstateReadRefused {
                reason:
                    FederatedReadRefusalReason::NoActiveGrant
                    | FederatedReadRefusalReason::GrantExpired
                    | FederatedReadRefusalReason::GrantRevoked,
                ..
            }) => return Err(V2OrchestrationFailure::FederatedAccessUnavailable),
            Err(_) => return Err(V2OrchestrationFailure::LowerUnavailable),
        };
        super::report_withheld::record(result.withheld_by_sensitivity);
        let results = result
            .drawers
            .iter()
            .map(Self::compact_memory)
            .collect::<Result<Vec<_>, V2OrchestrationFailure>>()?;
        Ok(V2FederatedSearchData {
            source_estate_id: Uuid::from_bytes(result.source_handle.estate_uuid),
            requester_estate_id: Uuid::from_bytes(result.requester_handle.estate_uuid),
            grant_id: result.grant.id,
            results,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn confirmation_receipt_only_declares_verified_cleanup() {
        let winner = Uuid::from_u128(1);
        let discarded = Uuid::from_u128(2);
        let unknown = Uuid::from_u128(3);
        let receipt = SelectedOrchestrationLower::confirmed_data(
            winner,
            vec![
                V2DiscardOutcome { branch_id: winner, status: V2DiscardOutcomeStatus::WinnerSkipped },
                V2DiscardOutcome { branch_id: discarded, status: V2DiscardOutcomeStatus::Discarded },
                V2DiscardOutcome { branch_id: unknown, status: V2DiscardOutcomeStatus::Unknown },
            ],
        );
        assert_eq!(receipt.promoted_branch_id, winner);
        assert_eq!(receipt.discarded_branch_ids, vec![discarded]);
        assert!(receipt.verify().is_ok());
    }

    #[test]
    fn filter_rejects_unknown_values() {
        assert!(matches!(
            SelectedOrchestrationLower::filter(Some("unrecognized")),
            Err(V2OrchestrationFailure::LowerUnavailable)
        ));
    }

    #[test]
    fn grounding_terms_are_distinctive_and_bounded() {
        assert_eq!(
            SelectedOrchestrationLower::grounding_terms("The Q8 model and Q8 signal"),
            vec!["q8", "model", "signal"]
        );
    }

    #[test]
    fn migration_data_keeps_all_lower_benchmark_report_fields() {
        let branch_id = Uuid::from_u128(7);
        let report = cognition_kit::migration_orchestration::CoreReport {
            plan_results: vec![cognition_kit::migration_orchestration::PlanResultCore {
                name: "candidate".to_owned(),
                branch_id: branch_id.to_string(),
                recall_overlap: 0.75,
                mean_reciprocal_rank: 0.5,
                lost: Vec::new(),
            }],
            rankings: vec![cognition_kit::migration_ranking::RankedPlan {
                name: "candidate".to_owned(),
                recall_overlap: 0.75,
                mean_reciprocal_rank: 0.5,
                combined_score: 0.625,
            }],
            disqualified: Vec::new(),
            winner: Some("candidate".to_owned()),
        };
        let data = SelectedOrchestrationLower::migration_data(
            report,
            vec![LowerBenchmarkReport {
                branch_id: branch_id.to_string(),
                query_count: 3,
                recall_overlap: 0.75,
                recall_precision: 0.6,
                mean_reciprocal_rank: 0.5,
                not_found_in_branch: vec!["lost".to_owned()],
                new_in_branch: vec!["new".to_owned()],
                evaluated_at: 0,
            }],
        )
        .expect("valid lower benchmark report");

        assert_eq!(data.reports.len(), 1);
        assert_eq!(data.reports[0].branch_id, branch_id);
        assert_eq!(data.reports[0].query_count, 3);
        assert_eq!(data.reports[0].recall_overlap, 0.75_f32 as f64);
        assert_eq!(data.reports[0].recall_precision, 0.6_f32 as f64);
        assert_eq!(data.reports[0].mean_reciprocal_rank, 0.5_f32 as f64);
        assert_eq!(data.reports[0].not_found_in_branch, vec!["lost"]);
        assert_eq!(data.reports[0].new_in_branch, vec!["new"]);
        assert_eq!(data.reports[0].evaluated_at, "1970-01-01T00:00:00Z");
    }

    #[test]
    fn confirmation_preserves_existing_branch_lifecycle_failures() {
        let registry = EstateRegistry::new_inmemory_bare();
        let lower = SelectedOrchestrationLower::new(&registry);
        let selected = registry.default.estate_id;
        let request = |winner_branch_id| V2ConfirmMigrationRequest {
            winner_branch_id,
            discard_branch_ids: Vec::new(),
            estate_id: None,
        };

        assert_eq!(
            lower.confirm_migration(request(Uuid::from_u128(1)), selected),
            Err(V2OrchestrationFailure::UnknownBranch)
        );

        let discarded = {
            let mut coordinator = registry.coord.lock().expect("in-memory coordinator lock");
            let branch = coordinator
                .glk_derive_branch("discarded", &registry.default.handle, 1)
                .expect("derive branch");
            coordinator.glk_discard_branch(branch, 2).expect("discard branch");
            branch
        };
        assert_eq!(
            lower.confirm_migration(request(discarded), selected),
            Err(V2OrchestrationFailure::DisqualifiedBranch)
        );

        let terminal = {
            let mut coordinator = registry.coord.lock().expect("in-memory coordinator lock");
            let branch = coordinator
                .glk_derive_branch("terminal", &registry.default.handle, 3)
                .expect("derive branch");
            coordinator
                .glk_promote_branch(branch, &registry.default.handle, 4)
                .expect("promote branch");
            branch
        };
        assert_eq!(
            lower.confirm_migration(request(terminal), selected),
            Err(V2OrchestrationFailure::TerminalBranch)
        );
    }

    #[test]
    fn confirmation_orders_actual_cleanup_receipts_by_branch_uuid() {
        let registry = EstateRegistry::new_inmemory_bare();
        let lower = SelectedOrchestrationLower::new(&registry);
        let selected = registry.default.estate_id;
        let (winner, first_loser, second_loser) = {
            let mut coordinator = registry.coord.lock().expect("in-memory coordinator lock");
            let winner = coordinator
                .glk_derive_branch("winner", &registry.default.handle, 1)
                .expect("derive winner");
            let first_loser = coordinator
                .glk_derive_branch("first loser", &registry.default.handle, 2)
                .expect("derive first loser");
            let second_loser = coordinator
                .glk_derive_branch("second loser", &registry.default.handle, 3)
                .expect("derive second loser");
            (winner, first_loser, second_loser)
        };
        let unknown = Uuid::nil();
        let receipt = lower
            .confirm_migration(
                V2ConfirmMigrationRequest {
                    winner_branch_id: winner,
                    // Deliberately noncanonical: the lower receipt must not
                    // preserve this request order.
                    discard_branch_ids: vec![winner, second_loser, unknown, first_loser],
                    estate_id: None,
                },
                selected,
            )
            .expect("promotion and observed cleanup");

        let mut expected_outcome_ids = vec![winner, second_loser, unknown, first_loser];
        expected_outcome_ids.sort_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
        let mut expected_discarded_ids = vec![first_loser, second_loser];
        expected_discarded_ids.sort_by(|left, right| left.as_bytes().cmp(right.as_bytes()));
        assert_eq!(receipt.promoted_branch_id, winner);
        assert_eq!(
            receipt.discard_outcomes.iter().map(|outcome| outcome.branch_id).collect::<Vec<_>>(),
            expected_outcome_ids
        );
        assert_eq!(receipt.discarded_branch_ids, expected_discarded_ids);
        assert_eq!(
            receipt.discard_outcomes.iter().find(|outcome| outcome.branch_id == winner).unwrap().status,
            V2DiscardOutcomeStatus::WinnerSkipped
        );
        assert_eq!(
            receipt.discard_outcomes.iter().find(|outcome| outcome.branch_id == unknown).unwrap().status,
            V2DiscardOutcomeStatus::Unknown
        );
        assert!(receipt.verify().is_ok());
    }

    #[test]
    fn federation_refuses_multiple_sources_until_the_v2_dto_can_aggregate_them() {
        let mut registry = EstateRegistry::new_inmemory_bare();
        registry.register_inmemory("second");
        registry.register_inmemory("third");
        let selected = registry.default.estate_id;
        let lower = SelectedOrchestrationLower::new(&registry);

        assert_eq!(
            lower.federated_search(
                V2FederatedSearchRequest {
                    requester_estate_id: None,
                    filter: None,
                    limit: None,
                    ordering: None,
                    hydration_level: None,
                },
                selected,
            ),
            Err(V2OrchestrationFailure::FederatedAggregationRequired)
        );
    }

    #[test]
    fn federation_returns_the_registered_peer_grant_receipt() {
        use genius_locus_kit::{CustodyMode, GrantLifetime, GrantOptions, GrantScope, ReSharePermission};

        let mut registry = EstateRegistry::new_inmemory();
        let source_estate_id = registry.register_inmemory("v2-federation-peer");
        let requester = registry.default.handle;
        let source = registry
            .extras
            .get(&source_estate_id)
            .expect("registered peer must remain in the estate registry")
            .handle;
        let grant_id = {
            let mut coordinator = registry.coord.lock().expect("in-memory coordinator lock");
            let grant = coordinator
                .issue_grant(
                    &source,
                    GrantOptions {
                        grantee_estate_id: Uuid::from_bytes(requester.estate_uuid),
                        scope: GrantScope::WholeEstate,
                        custody_mode: CustodyMode::Mediated,
                        lifetime: GrantLifetime::Permanent,
                        content_level: 0,
                        re_share_permission: ReSharePermission::None,
                    },
                    &[0xA5; 32],
                    0.0,
                )
                .expect("registered peer grant must issue");
            coordinator
                .grant_store_mut(&source)
                .expect("registered peer grant store")
                .set_budget(grant.grant.id, 1.0)
                .expect("grant budget must be provisioned");
            grant.grant.id
        };
        let lower = SelectedOrchestrationLower::new(&registry);

        let data = lower
            .federated_search(
                V2FederatedSearchRequest {
                    requester_estate_id: None,
                    filter: None,
                    limit: None,
                    ordering: None,
                    hydration_level: None,
                },
                registry.default.estate_id,
            )
            .expect("a registered peer's active grant must admit typed federation");

        assert_eq!(data.source_estate_id, Uuid::from_bytes(source.estate_uuid));
        assert_eq!(data.requester_estate_id, Uuid::from_bytes(requester.estate_uuid));
        assert_eq!(data.grant_id, grant_id);
    }
}
