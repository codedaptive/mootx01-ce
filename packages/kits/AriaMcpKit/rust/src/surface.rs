//! Selected ARIA v2 public-surface facade.
//!
//! The Mission01 catalog is the only surface. Its decoder, stable operation
//! identity, policy effect, typed operation, and projection live together here.
//! V2 operations never enter legacy teachme, mode, or runner paths.

use std::collections::BTreeMap;

use std::path::Path;

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use serde_json::json;
use serde::Serialize;
use uuid::Uuid;

use crate::jsonrpc::{JSONRPCError, JsonValue};

use crate::jsonrpc::JSONRPCErrorCode;
use crate::monitoring_control::MonitoringControl;

/// The one catalog selected for a running binary.
pub(crate) struct SelectedSurface {
    tools: serde_json::Value,
    registry: crate::v2::registry::V2EffectiveRegistry,
    memory_list_cursors: Arc<crate::v2::memory_list::MemoryListCursorStore>,
    contradiction_analyses: Arc<Mutex<crate::v2::contradictions::V2ContradictionAnalysisCache>>,
}

/// A decoded v2 operation. Its identity, rather than a public name, drives
/// shared policy decisions.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum SurfaceRequest {
    Help(crate::v2::help::V2HelpRequest),
    FileMemory(crate::v2::core_memory::V2FileMemoryRequest),
    MemorySearch(crate::v2::core_memory::V2MemorySearchRequest),
    MemoryGet(crate::v2::core_memory::V2MemoryGetRequest),
    MemoryList(crate::v2::memory_list::MemoryListRequest),
    ContradictionHunt(crate::v2::contradictions::V2ContradictionHuntRequest),
    ContradictionProposal(crate::v2::contradictions::V2ContradictionProposalRequest),
    MemoryMutation(MemoryMutationRequest),
    KnowledgeJournal(KnowledgeJournalRequest),
    CognitionCatalog {
        operation: crate::v2::cognition_catalog::CognitionCatalogOperation,
        request: crate::v2::cognition_catalog::CognitionCatalogRequest,
    },
    Recall(crate::v2::recall_lens::V2RecallLensRequest),
    Synthesize(crate::v2::orchestration::V2SynthesizeRequest),
    Dream(crate::v2::dream::V2DreamRequest),
    MigrationRun(crate::v2::orchestration::V2RunMigrationRequest),
    MigrationConfirm(crate::v2::orchestration::V2ConfirmMigrationRequest),
    FederatedRecall(crate::v2::orchestration::V2FederatedSearchRequest),
    EstateDiagnostics {
        operation: crate::v2::estate_diagnostics::EstateDiagnosticsOperation,
        request: crate::v2::estate_diagnostics::EstateDiagnosticsRequest,
    },
    VaultLifecycle(VaultLifecycleRequest),
    TranscriptRecall(crate::v2::transcript_recall::V2TranscriptRecallRequest),
    MonitoringSet(crate::v2::monitoring_set::V2MonitoringSetRequest),
    MonitoringStatus,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum MemoryMutationRequest {
    Update(crate::v2::memory_mutations::V2UpdateMemoryRequest),
    Withdraw(crate::v2::memory_mutations::V2WithdrawMemoryRequest),
    Erase(crate::v2::memory_mutations::V2EraseMemoryRequest),
    Confirm(crate::v2::memory_mutations::V2ConfirmMemoryRequest),
    Move(crate::v2::memory_mutations::V2MoveMemoryRequest),
    Link(crate::v2::memory_mutations::V2LinkMemoriesRequest),
    Review(crate::v2::memory_mutations::V2ReviewTunnelRequest),
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum KnowledgeJournalRequest {
    ConnectionSearch(crate::v2::knowledge_journal::V2ConnectionSearchRequest),
    ConnectionMap(crate::v2::knowledge_journal::V2ConnectionMapRequest),
    FileFact(crate::v2::knowledge_journal::V2FileFactRequest),
    FactSearch(crate::v2::knowledge_journal::V2FactSearchRequest),
    RetireFact(crate::v2::knowledge_journal::V2RetireFactRequest),
    FactTimeline(crate::v2::knowledge_journal::V2FactTimelineRequest),
    WriteJournal(crate::v2::knowledge_journal::V2WriteJournalRequest),
    ReadJournal(crate::v2::knowledge_journal::V2ReadJournalRequest),
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum VaultLifecycleRequest {
    Reindex(crate::v2::data_mobility::V2ReindexRequest),
    ReclassifyFdc(crate::v2::data_mobility::V2ReclassifyFdcRequest),
    PalaceImport(crate::v2::data_mobility::V2PalaceImportRequest),
    JsonImport(crate::v2::data_mobility::V2JsonImportRequest),
    FileDataset(crate::v2::data_mobility::V2FileDatasetRequest),
    DatasetQuery(crate::v2::data_mobility::V2DatasetQueryRequest),
    DatasetStats(crate::v2::data_mobility::V2DatasetStatsRequest),
    Export(crate::v2::data_mobility::V2VaultExportRequest),
    Import(crate::v2::data_mobility::V2VaultImportRequest),
    Status(crate::v2::data_mobility::V2VaultStatusRequest),
    Reconcile(crate::v2::data_mobility::V2VaultReconcileRequest),
    Job(crate::v2::data_mobility::V2VaultJobRequest),
}


/// The policy effect attached to a stable v2 operation identity.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SurfaceEffect {
    Inspection,
    Mutation,
}

impl SelectedSurface {
    /// Select the effective catalog. V1's public builders intentionally stay
    /// v1 facades for existing callers and regression fixtures.
    pub(crate) fn selected(vault_on: bool, memory_on: bool) -> Self {
        {
            let _ = memory_on;
            let registry = crate::v2::catalog::selected_registry_with_vault(vault_on);
            Self {
                tools: crate::v2::catalog::selected_tools_for_registry(&registry),
                registry,
                memory_list_cursors: Arc::new(crate::v2::memory_list::MemoryListCursorStore::new()),
                contradiction_analyses: Arc::new(Mutex::new(crate::v2::contradictions::V2ContradictionAnalysisCache::new())),
            }
        }

    }

    pub(crate) fn catalog(&self) -> &serde_json::Value {
        &self.tools
    }

    pub(crate) fn registry(&self) -> &crate::v2::registry::V2EffectiveRegistry {
        &self.registry
    }

    pub(crate) fn capability_digest(&self) -> String {
        crate::v2::capability_digest::registry_capability_digest(&self.registry)
    }

    /// Return the keys advertised by this selected catalog. V2's decoder is
    /// deliberately stricter than the legacy hint-only accepted-key helper.
    pub(crate) fn accepted_arg_keys(&self, name: &str) -> Option<HashSet<String>> {
        let tools = self.tools.as_array()?;
        let tool = tools
            .iter()
            .find(|tool| tool["name"].as_str() == Some(name))?;
        let properties = tool["inputSchema"]["properties"].as_object()?;
        Some(properties.keys().cloned().collect())
    }

    /// Decode the selected v2 request after name/argument parsing and before
    /// frozen posture or session processing. Names outside the v2 catalog
    /// fail here with `METHOD_NOT_FOUND`; every name the catalog admits
    /// decodes to `Ok(Some(_))` — this never returns `Ok(None)`.
    pub(crate) fn decode(
        &self,
        name: &str,
        args: &BTreeMap<String, JsonValue>,
    ) -> Result<Option<SurfaceRequest>, JSONRPCError> {
        {
            if self.accepted_arg_keys(name).is_none() {
                return Err(JSONRPCError::new(
                    JSONRPCErrorCode::METHOD_NOT_FOUND,
                    format!("Unknown tool for active ARIA v2 surface: {name}"),
                ));
            }
            let value = JsonValue::Object(args.clone());
            let request = match name {
                "moot_help" => SurfaceRequest::Help(
                    crate::v2::help::V2HelpRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_file_memory" => SurfaceRequest::FileMemory(
                    crate::v2::core_memory::V2FileMemoryRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_memory_search" => SurfaceRequest::MemorySearch(
                    crate::v2::core_memory::V2MemorySearchRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_memory_get" => SurfaceRequest::MemoryGet(
                    crate::v2::core_memory::V2MemoryGetRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_memory_list" => SurfaceRequest::MemoryList(
                    crate::v2::memory_list::MemoryListRequest::decode(
                        &serde_json::to_value(&value).map_err(jsonrpc_internal)?,
                    )
                        .map_err(memory_list_decode_error)?),
                "moot_hunt_contradictions" => SurfaceRequest::ContradictionHunt(
                    crate::v2::contradictions::V2ContradictionHuntRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_propose_contradictions" => SurfaceRequest::ContradictionProposal(
                    crate::v2::contradictions::V2ContradictionProposalRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_update_memory" => SurfaceRequest::MemoryMutation(MemoryMutationRequest::Update(
                    crate::v2::memory_mutations::V2UpdateMemoryRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_withdraw_memory" => SurfaceRequest::MemoryMutation(MemoryMutationRequest::Withdraw(
                    crate::v2::memory_mutations::V2WithdrawMemoryRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_erase_memory" => SurfaceRequest::MemoryMutation(MemoryMutationRequest::Erase(
                    crate::v2::memory_mutations::V2EraseMemoryRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_confirm_memory" => SurfaceRequest::MemoryMutation(MemoryMutationRequest::Confirm(
                    crate::v2::memory_mutations::V2ConfirmMemoryRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_move_memory" => SurfaceRequest::MemoryMutation(MemoryMutationRequest::Move(
                    crate::v2::memory_mutations::V2MoveMemoryRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_link_memories" => SurfaceRequest::MemoryMutation(MemoryMutationRequest::Link(
                    crate::v2::memory_mutations::V2LinkMemoriesRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_review_tunnel" => SurfaceRequest::MemoryMutation(MemoryMutationRequest::Review(
                    crate::v2::memory_mutations::V2ReviewTunnelRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_connection_search" => SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::ConnectionSearch(
                    crate::v2::knowledge_journal::V2ConnectionSearchRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_connection_map" => SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::ConnectionMap(
                    crate::v2::knowledge_journal::V2ConnectionMapRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_file_fact" => SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::FileFact(
                    crate::v2::knowledge_journal::V2FileFactRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_fact_search" => SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::FactSearch(
                    crate::v2::knowledge_journal::V2FactSearchRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_retire_fact" => SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::RetireFact(
                    crate::v2::knowledge_journal::V2RetireFactRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_fact_timeline" => SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::FactTimeline(
                    crate::v2::knowledge_journal::V2FactTimelineRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_write_journal" => SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::WriteJournal(
                    crate::v2::knowledge_journal::V2WriteJournalRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_read_journal" => SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::ReadJournal(
                    crate::v2::knowledge_journal::V2ReadJournalRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_list_lenses" => SurfaceRequest::CognitionCatalog {
                    operation: crate::v2::cognition_catalog::CognitionCatalogOperation::Lenses,
                    request: cognition_catalog_request(&value)?,
                },
                "moot_list_recipes" => SurfaceRequest::CognitionCatalog {
                    operation: crate::v2::cognition_catalog::CognitionCatalogOperation::Recipes,
                    request: cognition_catalog_request(&value)?,
                },
                "moot_recall_precise" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::RecallPrecise, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_recall_temporal" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::RecallTemporal, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_recall_connected" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::RecallConnected, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_recall_shaped" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::RecallShaped, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_recall_distilled" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::RecallDistilled, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_recall_vague" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::RecallVague, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_recall_walk" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::RecallWalk, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_keystones" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensKeystones, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_constellation" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensConstellation, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_free_association" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensFreeAssociation, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_bias" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensBias, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_cohesion" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensCohesion, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_contradiction" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensContradiction, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_theme_weather" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensThemeWeather, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_latent_themes" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensLatentThemes, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_drift" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensDrift, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_trust_synthesis" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensTrustSynthesis, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_partial_cue" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensPartialCue, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_anticipate" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensAnticipate, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_node_motion" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensNodeMotion, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_successors" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensSuccessors, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_overlap" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensOverlap, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_divergence" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensDivergence, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_associations" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensAssociations, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_concepts" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensConcepts, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_apriori" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensApriori, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_moment" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensMoment, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_rhythm" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensRhythm, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_precedence" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensPrecedence, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_lens_complexity" => SurfaceRequest::Recall(crate::v2::recall_lens::V2RecallLensRequest::decode(crate::v2::recall_lens::V2RecallLensOperation::LensComplexity, &value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_synthesize" => SurfaceRequest::Synthesize(
                    crate::v2::orchestration::V2SynthesizeRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_dream" => SurfaceRequest::Dream(crate::v2::dream::V2DreamRequest::decode(&value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_migration_run" => SurfaceRequest::MigrationRun(crate::v2::orchestration::V2RunMigrationRequest::decode(&value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_migration_confirm" => SurfaceRequest::MigrationConfirm(crate::v2::orchestration::V2ConfirmMigrationRequest::decode(&value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_federated_recall" => SurfaceRequest::FederatedRecall(crate::v2::orchestration::V2FederatedSearchRequest::decode(&value).map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_estate_ping" => SurfaceRequest::EstateDiagnostics {
                    operation: crate::v2::estate_diagnostics::EstateDiagnosticsOperation::Ping,
                    request: estate_diagnostics_request(&value)?,
                },
                "moot_estate_status" => SurfaceRequest::EstateDiagnostics {
                    operation: crate::v2::estate_diagnostics::EstateDiagnosticsOperation::Status,
                    request: estate_diagnostics_request(&value)?,
                },
                "moot_estate_map" => SurfaceRequest::EstateDiagnostics {
                    operation: crate::v2::estate_diagnostics::EstateDiagnosticsOperation::Map,
                    request: estate_diagnostics_request(&value)?,
                },
                "moot_drain_status" => SurfaceRequest::EstateDiagnostics {
                    operation: crate::v2::estate_diagnostics::EstateDiagnosticsOperation::Drain,
                    request: estate_diagnostics_request(&value)?,
                },
                "moot_rebuild_status" => SurfaceRequest::EstateDiagnostics {
                    operation: crate::v2::estate_diagnostics::EstateDiagnosticsOperation::Rebuild,
                    request: estate_diagnostics_request(&value)?,
                },
                "moot_timing_report" => SurfaceRequest::EstateDiagnostics {
                    operation: crate::v2::estate_diagnostics::EstateDiagnosticsOperation::Timing,
                    request: estate_diagnostics_request(&value)?,
                },
                "moot_reindex" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Reindex(
                    crate::v2::data_mobility::V2ReindexRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_reclassify_fdc" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::ReclassifyFdc(
                    crate::v2::data_mobility::V2ReclassifyFdcRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_palace_import" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::PalaceImport(
                    crate::v2::data_mobility::V2PalaceImportRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_json_import" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::JsonImport(
                    crate::v2::data_mobility::V2JsonImportRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_file_dataset" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::FileDataset(
                    crate::v2::data_mobility::V2FileDatasetRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_dataset_query" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::DatasetQuery(
                    crate::v2::data_mobility::V2DatasetQueryRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_dataset_stats" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::DatasetStats(
                    crate::v2::data_mobility::V2DatasetStatsRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_vault_export" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Export(
                    crate::v2::data_mobility::V2VaultExportRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_vault_import" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Import(
                    crate::v2::data_mobility::V2VaultImportRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_vault_status" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Status(
                    crate::v2::data_mobility::V2VaultStatusRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_vault_reconcile" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Reconcile(
                    crate::v2::data_mobility::V2VaultReconcileRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_vault_job" => SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Job(
                    crate::v2::data_mobility::V2VaultJobRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?)),
                "moot_memory_recall_transcript" => SurfaceRequest::TranscriptRecall(
                    crate::v2::transcript_recall::V2TranscriptRecallRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                "moot_monitoring_status" => {
                    if let Some((key, _)) = args.iter().next() {
                        return Err(invalid_argument(
                            key,
                            "moot_monitoring_status is inspection-only in ARIA v2 and accepts no arguments",
                        ));
                    }
                    SurfaceRequest::MonitoringStatus
                }
                "moot_monitoring_set" => SurfaceRequest::MonitoringSet(
                    crate::v2::monitoring_set::V2MonitoringSetRequest::decode(&value)
                        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)?),
                _ => unreachable!("selected catalog admitted an unknown v2 operation"),
            };
            Ok(Some(request))
        }

    }
}

impl SurfaceRequest {
    pub(crate) fn effect(&self) -> SurfaceEffect {
        match self {
            SurfaceRequest::Help(_)
            | SurfaceRequest::MemorySearch(_)
            | SurfaceRequest::MemoryGet(_)
            | SurfaceRequest::MemoryList(_)
            | SurfaceRequest::ContradictionHunt(_)
            | SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::ConnectionSearch(_))
            | SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::ConnectionMap(_))
            | SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::FactSearch(_))
            | SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::FactTimeline(_))
            | SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::ReadJournal(_))
            | SurfaceRequest::CognitionCatalog { .. }
            | SurfaceRequest::Recall(_)
            | SurfaceRequest::Synthesize(_)
            | SurfaceRequest::MigrationRun(_)
            | SurfaceRequest::FederatedRecall(_)
            | SurfaceRequest::EstateDiagnostics { .. }
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::DatasetQuery(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::DatasetStats(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Status(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Export(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Job(_))
            | SurfaceRequest::TranscriptRecall(_)
            | SurfaceRequest::MonitoringStatus => SurfaceEffect::Inspection,
            SurfaceRequest::FileMemory(_)
            | SurfaceRequest::Dream(_)
            | SurfaceRequest::MigrationConfirm(_)
            | SurfaceRequest::ContradictionProposal(_)
            | SurfaceRequest::MemoryMutation(_)
            | SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::FileFact(_))
            | SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::RetireFact(_))
            | SurfaceRequest::KnowledgeJournal(KnowledgeJournalRequest::WriteJournal(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Reindex(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::ReclassifyFdc(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::PalaceImport(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::JsonImport(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::FileDataset(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Import(_))
            | SurfaceRequest::VaultLifecycle(VaultLifecycleRequest::Reconcile(_))
            | SurfaceRequest::MonitoringSet(_) => SurfaceEffect::Mutation,
        }
    }
}

struct FixedV2Clock(i64);

impl crate::v2::core_memory::V2MemoryClock for FixedV2Clock {
    fn now_millis(&self) -> i64 { self.0 }
}

struct SelectedV2Authorization;

impl crate::v2::core_memory::V2MemoryAuthorization for SelectedV2Authorization {
    fn authorize(
        &self,
        _operation: crate::v2::core_memory::V2CoreMemoryOperation,
        _context: &crate::v2::core_memory::V2MemoryOperationContext,
    ) -> Result<(), crate::v2::core_memory::V2MemoryFailure> { Ok(()) }
}

/// Execute one typed selected-surface request against direct typed services.
pub(crate) fn execute(
    selected_surface: &SelectedSurface,
    posture: crate::estate_posture::EstatePosture,
    request: SurfaceRequest,
    registry: &crate::estate_registry::EstateRegistry,
    sensitivity_ledger: &crate::sensitivity_grant_ledger::SensitivityGrantLedger,
    surfaced_recall_ledger: &crate::surfaced_recall_ledger::SurfacedRecallLedger,
    vault_ledger: &crate::vault_tools::VaultJobLedger,
    monitoring_control: Option<&dyn MonitoringControl>,
    build_id: &str,
    now_millis: i64,
) -> Result<serde_json::Value, JSONRPCError> {
    let meta = crate::v2::render::V2ResultMeta::incomplete(
        build_id,
        selected_surface.capability_digest(),
        crate::v2::operation::V2OperationEffect::Read,
    );
    let service = crate::v2::estate_memory::EstateV2MemoryService::new(registry, posture);
    let clock = FixedV2Clock(now_millis);
    let authorization = SelectedV2Authorization;
    let dependencies = crate::v2::core_memory::V2CoreMemoryDependencies {
        service: &service,
        authorization: &authorization,
        clock: &clock,
        sensitivity_ledger,
        surfaced_recall_ledger,
        caller_identity: &registry.server_identity,
        meta: meta.clone(),
    };
    match request {
        SurfaceRequest::Help(help_request) => {
            match crate::v2::help::resolve_help(selected_surface.registry(), &help_request) {
                Some(help) => crate::v2::render::success(
                    "moot_help", &help.as_value(), &meta,
                    "ARIA v2 help returned the exact currently callable operation set.",
                ).map_err(jsonrpc_internal),
                None => Ok(crate::v2::render::refusal("moot_help", &crate::v2::render::V2OperationalRefusal {
                    code: "unknown_operation".to_owned(), message: "No callable ARIA v2 operation matched that help request.".to_owned(), retryable: false,
                    recovery: Some(serde_json::json!({"tool":"moot_help","arguments":{}})),
                }, &meta)),
            }
        }
        SurfaceRequest::FileMemory(request) =>
            crate::v2::core_memory::execute_file_memory(request, &dependencies),
        SurfaceRequest::MemorySearch(request) =>
            crate::v2::core_memory::execute_memory_search(request, &dependencies),
        SurfaceRequest::MemoryGet(request) =>
            crate::v2::core_memory::execute_memory_get(request, &dependencies),
        SurfaceRequest::MemoryList(request) =>
            execute_memory_list(request, registry, &selected_surface.memory_list_cursors, &meta, now_millis),
        SurfaceRequest::ContradictionHunt(request) =>
            execute_contradiction_hunt(request, registry, &selected_surface.contradiction_analyses, &meta, now_millis),
        SurfaceRequest::ContradictionProposal(request) =>
            execute_contradiction_proposal(request, registry, &selected_surface.contradiction_analyses, &meta, now_millis),
        SurfaceRequest::MemoryMutation(request) =>
            execute_memory_mutation(request, registry, &meta, now_millis, posture, surfaced_recall_ledger),
        SurfaceRequest::KnowledgeJournal(request) =>
            execute_knowledge_journal(request, registry, sensitivity_ledger, &meta, now_millis),
        SurfaceRequest::CognitionCatalog { operation, request } =>
            execute_cognition_catalog(operation, request, selected_surface, registry, &meta),
        SurfaceRequest::Recall(request) => execute_recall(request, registry, &meta, now_millis),
        SurfaceRequest::Synthesize(request) => execute_synthesize(request, registry, &meta),
        SurfaceRequest::Dream(request) => execute_dream(request, registry, &meta, now_millis),
        SurfaceRequest::MigrationRun(request) => execute_migration_run(request, registry, &meta),
        SurfaceRequest::MigrationConfirm(request) => execute_migration_confirm(request, registry, &meta),
        SurfaceRequest::FederatedRecall(request) => execute_federated_recall(request, registry, &meta),
        SurfaceRequest::EstateDiagnostics { operation, request } =>
            execute_estate_diagnostics(operation, request, registry, build_id, now_millis, &meta),
        SurfaceRequest::VaultLifecycle(request) =>
            execute_vault_lifecycle(request, registry, vault_ledger, &meta, now_millis),
        SurfaceRequest::TranscriptRecall(request) =>
            crate::v2::transcript_recall::execute(request, registry, &meta, now_millis),
        SurfaceRequest::MonitoringSet(request) => {
            let write_meta = packet_meta(&meta, crate::v2::operation::V2OperationEffect::Write);
            crate::v2::monitoring_set::execute(request, monitoring_control, &write_meta)
        }
        SurfaceRequest::MonitoringStatus => {
            let monitoring = match monitoring_control.and_then(|control| control.read()) {
                Some(true) => "enabled",
                Some(false) => "disabled",
                None => "unavailable",
            };
            Ok(render_monitoring_status(monitoring, &meta))
        }
    }
}

/// Renders a mutation outcome as the wire string for the `outcome` field.
///
/// `ErasedPartially` is handled explicitly because the Swift port hard-codes
/// `"erased_partially"` (see `AriaV2MemoryMutations.swift:346`), while
/// `format!("{:?}", …).to_lowercase()` produces `"erasedpartially"` — no
/// separator — for a two-word variant.  Every other variant is a single word
/// and renders correctly via Debug + lowercase.
///
/// The tunnel variants (`TunnelAccepted`, `TunnelEndorsed`, `TunnelRejected`)
/// also have two components, but they are NOT exposed on this code path from
/// Swift and their current wire values (`"tunnelaccepted"`, etc.) are part of
/// the shipped Rust-only contract.  Changing them here would be an unmandated
/// wire-value change.  If parity is ever required for those variants, update
/// this function and the wire-contract docs at the same time.
fn mutation_outcome_wire_value(outcome: crate::v2::memory_mutations::V2MemoryMutationOutcome) -> String {
    match outcome {
        crate::v2::memory_mutations::V2MemoryMutationOutcome::ErasedPartially => "erased_partially".to_owned(),
        other => format!("{:?}", other).to_lowercase(),
    }
}

fn execute_memory_mutation(
    request: MemoryMutationRequest,
    registry: &crate::estate_registry::EstateRegistry,
    meta: &crate::v2::render::V2ResultMeta,
    now_millis: i64,
    posture: crate::estate_posture::EstatePosture,
    surfaced_recall_ledger: &crate::surfaced_recall_ledger::SurfacedRecallLedger,
) -> Result<serde_json::Value, JSONRPCError> {
    use crate::v2::memory_mutations::{
        CoordinatorMemoryMutationLower, V2MemoryMutationError, V2MemoryMutationService,
    };
    let service = V2MemoryMutationService::new(
        SelectedMemoryMutationAuthority { registry, now_millis },
        CoordinatorMemoryMutationLower::new(Arc::clone(&registry.default.coord)),
    );
    // Acting on a surfaced row is a dereference, so the reward sweep hears
    // about it. Fires BEFORE the mutation, as in v1: the caller acted on the id
    // whether or not the write then succeeds. Erase is excluded — v1 did not
    // reward a row it was destroying — as are link and review, which name a
    // tunnel rather than a surfaced memory.
    let dereferenced = match &request {
        MemoryMutationRequest::Update(request) => Some(request.memory_id),
        MemoryMutationRequest::Withdraw(request) => Some(request.memory_id),
        MemoryMutationRequest::Confirm(request) => Some(request.memory_id),
        MemoryMutationRequest::Move(request) => Some(request.memory_id),
        _ => None,
    };
    if let Some(memory_id) = dereferenced {
        let canonical = memory_id.hyphenated().to_string();
        // Both spellings: the two portable writers disagree on UUID case and
        // mark_recall_used matches trace rows by the stored id.
        for spelling in [canonical.clone(), canonical.to_uppercase()] {
            crate::interface_tools::note_usage(
                &spelling, &registry.default, surfaced_recall_ledger, posture);
        }
    }
    let (tool, result) = match request {
        MemoryMutationRequest::Update(request) => (
            crate::v2::memory_mutations::UPDATE_MEMORY_TOOL, service.update(request)),
        MemoryMutationRequest::Withdraw(request) => (
            crate::v2::memory_mutations::WITHDRAW_MEMORY_TOOL, service.withdraw(request)),
        MemoryMutationRequest::Erase(request) => (
            crate::v2::memory_mutations::ERASE_MEMORY_TOOL, service.erase(request)),
        MemoryMutationRequest::Confirm(request) => (
            crate::v2::memory_mutations::CONFIRM_MEMORY_TOOL, service.confirm(request)),
        MemoryMutationRequest::Move(request) => (
            crate::v2::memory_mutations::MOVE_MEMORY_TOOL, service.move_memory(request)),
        MemoryMutationRequest::Link(request) => (
            crate::v2::memory_mutations::LINK_MEMORIES_TOOL, service.link(request)),
        MemoryMutationRequest::Review(request) => (
            crate::v2::memory_mutations::REVIEW_TUNNEL_TOOL, service.review(request)),
    };
    match result {
        Ok(result) => crate::v2::render::success(
            tool,
            &match result.tunnel_review {
                Some(crate::v2::memory_mutations::V2TunnelReviewReceipt::Endorsed {
                    new_endorser, distinct_endorsers, contested,
                }) => json!({
                    "tunnel_id": result.tunnel_id.map(|id| id.hyphenated().to_string()),
                    "new_endorser": new_endorser,
                    "distinct_endorsers": distinct_endorsers,
                    "contested": contested,
                }),
                Some(crate::v2::memory_mutations::V2TunnelReviewReceipt::Settled {
                    withdrawn, contested,
                }) => json!({
                    "tunnel_id": result.tunnel_id.map(|id| id.hyphenated().to_string()),
                    "withdrawn": withdrawn,
                    "contested": contested,
                }),
                None => json!({
                    "operation": result.operation.tool_name(),
                    "outcome": mutation_outcome_wire_value(result.outcome),
                    "memory_id": result.memory_id.map(|id| id.hyphenated().to_string()),
                    "tunnel_id": result.tunnel_id.map(|id| id.hyphenated().to_string()),
                }),
            },
            &packet_meta(meta, crate::v2::operation::V2OperationEffect::Write),
            "Applied the selected typed memory mutation.",
        ).map_err(jsonrpc_internal),
        Err(error) => {
            let (code, message, retryable) = match error {
                V2MemoryMutationError::Unavailable => (
                    "estate_unavailable", "The requested memory mutation is unavailable.", true),
                V2MemoryMutationError::OutcomeUnverified(_) => (
                    "outcome_unverified", "The mutation may have landed but its outcome could not be revalidated.", false),
            };
            Ok(crate::v2::render::refusal(
                tool,
                &crate::v2::render::V2OperationalRefusal {
                    code: code.to_owned(), message: message.to_owned(), retryable, recovery: None,
                },
                &packet_meta(meta, crate::v2::operation::V2OperationEffect::Write),
            ))
        }
    }
}

/// The selected v2 vault slice admits only the default estate and retains the
/// caller binding through the direct lower call and its readback.
struct SelectedVaultMobilityAuthority<'a> {
    registry: &'a crate::estate_registry::EstateRegistry,
    now_millis: i64,
}

impl crate::v2::data_mobility::V2DataMobilityAuthority for SelectedVaultMobilityAuthority<'_> {
    fn admit(
        &self,
        _operation: crate::v2::data_mobility::V2DataMobilityOperation,
        requested_estate_id: Option<Uuid>,
    ) -> Result<crate::v2::data_mobility::V2DataMobilityAdmission, ()> {
        let estate = &self.registry.default;
        if requested_estate_id.is_some_and(|estate_id| estate_id != estate.estate_id) {
            return Err(());
        }
        Ok(crate::v2::data_mobility::V2DataMobilityAdmission {
            estate_id: estate.estate_id,
            estate_handle: estate.handle.clone(),
            caller_binding: self.registry.server_identity.clone(),
            authorization_generation: format!(
                "selected-v2-public:{}:{}",
                estate.estate_id.hyphenated(), self.registry.server_identity,
            ),
            now_millis: self.now_millis,
        })
    }

    fn revalidate(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
    ) -> Result<(), ()> {
        let estate = &self.registry.default;
        (admission.estate_id == estate.estate_id
            && admission.caller_binding == self.registry.server_identity)
            .then_some(())
            .ok_or(())
    }
}

/// Concrete selected-estate bridge for the three callable vault lifecycle
/// operations.  It consumes the typed lower receipts and never reads v1 text
/// or JSON back into a v2 result.
struct SelectedVaultMobilityLower<'a> {
    registry: &'a crate::estate_registry::EstateRegistry,
    ledger: &'a crate::vault_tools::VaultJobLedger,
}

impl SelectedVaultMobilityLower<'_> {
    fn direct_args(
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
    ) -> BTreeMap<String, JsonValue> {
        BTreeMap::from([(
            "estateID".to_owned(),
            JsonValue::String(admission.estate_id.hyphenated().to_string()),
        )])
    }
}

impl crate::v2::data_mobility::V2DataMobilityLower for SelectedVaultMobilityLower<'_> {
    fn reindex(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2ReindexRequest,
    ) -> Result<crate::v2::data_mobility::V2ReindexState, ()> {
        crate::v2::data_mobility::V2DataMobilityLower::reindex(
            &crate::v2::data_mobility_lower::DirectDataMobilityLower::new(self.registry), admission, request,
        )
    }

    fn reclassify_fdc(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2ReclassifyFdcRequest,
    ) -> Result<crate::v2::data_mobility::V2ReclassifyFdcReport, ()> {
        crate::v2::data_mobility::V2DataMobilityLower::reclassify_fdc(
            &crate::v2::data_mobility_lower::DirectDataMobilityLower::new(self.registry), admission, request,
        )
    }

    fn palace_import(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2PalaceImportRequest,
    ) -> Result<crate::v2::data_mobility::V2PalaceImportReport, ()> {
        crate::v2::data_mobility::V2DataMobilityLower::palace_import(
            &crate::v2::data_mobility_lower::DirectDataMobilityLower::new(self.registry), admission, request,
        )
    }

    fn json_import(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2JsonImportRequest,
    ) -> Result<crate::v2::data_mobility::V2JsonImportReport, ()> {
        crate::v2::data_mobility::V2DataMobilityLower::json_import(
            &crate::v2::data_mobility_lower::DirectDataMobilityLower::new(self.registry), admission, request,
        )
    }

    fn file_dataset(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2FileDatasetRequest,
    ) -> Result<crate::v2::data_mobility::V2DatasetFiled, ()> {
        crate::v2::data_mobility::V2DataMobilityLower::file_dataset(
            &crate::v2::data_mobility_lower::DirectDataMobilityLower::new(self.registry), admission, request,
        )
    }

    fn dataset_query(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2DatasetQueryRequest,
    ) -> Result<crate::v2::data_mobility::V2DatasetQueryResult, ()> {
        crate::v2::data_mobility::V2DataMobilityLower::dataset_query(
            &crate::v2::data_mobility_lower::DirectDataMobilityLower::new(self.registry), admission, request,
        )
    }

    fn dataset_stats(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2DatasetStatsRequest,
    ) -> Result<crate::v2::data_mobility::V2DatasetStatsResult, ()> {
        crate::v2::data_mobility::V2DataMobilityLower::dataset_stats(
            &crate::v2::data_mobility_lower::DirectDataMobilityLower::new(self.registry), admission, request,
        )
    }

    fn vault_export(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2VaultExportRequest,
    ) -> Result<crate::v2::data_mobility::V2VaultExportResult, ()> {
        let scope = match request.scope.as_deref() {
            Some(scope) => vault_kit::VaultExportScope::from_str(scope).ok_or(())?,
            None => vault_kit::VaultExportScope::default(),
        };
        let launch = crate::vault_tools::launch_export(
            &Self::direct_args(admission), self.registry, Path::new(&request.vault_path),
            scope, self.ledger,
        ).map_err(|_| ())?;
        Ok(crate::v2::data_mobility::V2VaultExportResult {
            job_id: launch.job_id,
            vault: launch.vault_path,
            scope: launch.scope.unwrap_or_else(|| "exportable".to_owned()),
            datasets_exported: u64::try_from(launch.datasets_processed).ok().filter(|count| *count > 0),
            warnings: (!launch.warnings.is_empty()).then_some(launch.warnings),
        })
    }

    fn vault_import(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2VaultImportRequest,
    ) -> Result<crate::v2::data_mobility::V2VaultImportResult, ()> {
        let mut args = Self::direct_args(admission);
        if let Some(mode) = &request.mode {
            args.insert("mode".to_owned(), JsonValue::String(mode.clone()));
        }
        let launch = crate::vault_tools::launch_import(
            &args, self.registry, Path::new(&request.vault_path), self.ledger,
        ).map_err(|_| ())?;
        let crate::vault_tools::VaultJobResult::Imported(report) = launch.result else {
            return Err(());
        };
        Ok(crate::v2::data_mobility::V2VaultImportResult {
            job_id: launch.job_id,
            vault: launch.vault_path,
            note_count: u64::try_from(launch.note_count.unwrap_or(0)).map_err(|_| ())?,
            status: "complete".to_owned(),
            drawers_written: u64::try_from(report.drawers_written).ok(),
            drawers_updated: u64::try_from(report.drawers_updated).ok(),
            items_skipped: u64::try_from(report.items_skipped).ok(),
            tunnels_created: u64::try_from(report.tunnels_created).ok(),
            fdc_classified: u64::try_from(report.fdc_classified).ok(),
            fdc_unclassified: u64::try_from(report.fdc_unclassified).ok(),
            datasets_imported: u64::try_from(launch.datasets_processed).ok().filter(|count| *count > 0),
            warnings: (!launch.warnings.is_empty()).then_some(launch.warnings),
        })
    }

    fn vault_status(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2VaultStatusRequest,
    ) -> Result<crate::v2::data_mobility::V2VaultStatusResult, ()> {
        crate::v2::data_mobility::V2DataMobilityLower::vault_status(
            &crate::v2::data_mobility_lower::DirectDataMobilityLower::new(self.registry), admission, request,
        )
    }

    fn vault_reconcile(
        &self,
        admission: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2VaultReconcileRequest,
    ) -> Result<crate::v2::data_mobility::V2VaultReconcileResult, ()> {
        crate::v2::data_mobility::V2DataMobilityLower::vault_reconcile(
            &crate::v2::data_mobility_lower::DirectDataMobilityLower::new(self.registry), admission, request,
        )
    }

    fn vault_job(
        &self,
        _: &crate::v2::data_mobility::V2DataMobilityAdmission,
        request: &crate::v2::data_mobility::V2VaultJobRequest,
    ) -> Result<crate::v2::data_mobility::V2VaultJobResult, ()> {
        let snapshot = self.ledger.snapshot(request.job_id).ok_or(())?;
        let terminal = match snapshot.result {
            crate::vault_tools::VaultJobResult::Imported(result) => {
                crate::v2::data_mobility::V2VaultJobTerminal::Imported {
                    drawers_written: u64::try_from(result.drawers_written).map_err(|_| ())?,
                    drawers_updated: u64::try_from(result.drawers_updated).map_err(|_| ())?,
                    items_skipped: u64::try_from(result.items_skipped).map_err(|_| ())?,
                    tunnels_created: u64::try_from(result.tunnels_created).map_err(|_| ())?,
                    fdc_classified: u64::try_from(result.fdc_classified).map_err(|_| ())?,
                    fdc_unclassified: u64::try_from(result.fdc_unclassified).map_err(|_| ())?,
                    drawers_skipped_unchanged: u64::try_from(result.drawers_skipped_unchanged).map_err(|_| ())?,
                    drawers_skipped_tombstoned: u64::try_from(result.drawers_skipped_tombstoned).map_err(|_| ())?,
                }
            }
            crate::vault_tools::VaultJobResult::Exported(result) => {
                crate::v2::data_mobility::V2VaultJobTerminal::Exported {
                    note_count: u64::try_from(result.note_count).map_err(|_| ())?,
                    exported_at: result.exported_at,
                }
            }
        };
        Ok(crate::v2::data_mobility::V2VaultJobResult {
            job_id: snapshot.job_id,
            kind: match snapshot.kind {
                crate::vault_tools::VaultJobKind::Import => "import",
                crate::vault_tools::VaultJobKind::Export => "export",
            }.to_owned(),
            vault: snapshot.vault_path,
            status: "complete".to_owned(),
            elapsed_millis: 0,
            terminal: Some(terminal),
        })
    }
}

fn execute_vault_lifecycle(
    request: VaultLifecycleRequest,
    registry: &crate::estate_registry::EstateRegistry,
    ledger: &crate::vault_tools::VaultJobLedger,
    meta: &crate::v2::render::V2ResultMeta,
    now_millis: i64,
) -> Result<serde_json::Value, JSONRPCError> {
    use crate::v2::data_mobility::{V2DataMobilityError, V2DataMobilityService};
    let service = V2DataMobilityService::new(
        SelectedVaultMobilityAuthority { registry, now_millis },
        SelectedVaultMobilityLower { registry, ledger },
    );
    // return_id_map is read before the match consumes `request`. True only for
    // moot_json_import; every other lifecycle tool leaves the reply at one block.
    let return_id_map = matches!(
        &request,
        VaultLifecycleRequest::JsonImport(request) if request.return_id_map
    );
    let (tool, effect, result) = match request {
        VaultLifecycleRequest::Reindex(request) => (
            crate::v2::data_mobility::REINDEX_TOOL,
            crate::v2::operation::V2OperationEffect::Write,
            service.reindex(request),
        ),
        VaultLifecycleRequest::ReclassifyFdc(request) => (
            crate::v2::data_mobility::RECLASSIFY_FDC_TOOL,
            crate::v2::operation::V2OperationEffect::Write,
            service.reclassify_fdc(request),
        ),
        VaultLifecycleRequest::PalaceImport(request) => (
            crate::v2::data_mobility::PALACE_IMPORT_TOOL,
            crate::v2::operation::V2OperationEffect::Write,
            service.palace_import(request),
        ),
        VaultLifecycleRequest::JsonImport(request) => (
            crate::v2::data_mobility::JSON_IMPORT_TOOL,
            crate::v2::operation::V2OperationEffect::Write,
            service.json_import(request),
        ),
        VaultLifecycleRequest::FileDataset(request) => (
            crate::v2::data_mobility::FILE_DATASET_TOOL,
            crate::v2::operation::V2OperationEffect::Write,
            service.file_dataset(request),
        ),
        VaultLifecycleRequest::DatasetQuery(request) => (
            crate::v2::data_mobility::DATASET_QUERY_TOOL,
            crate::v2::operation::V2OperationEffect::Read,
            service.dataset_query(request),
        ),
        VaultLifecycleRequest::DatasetStats(request) => (
            crate::v2::data_mobility::DATASET_STATS_TOOL,
            crate::v2::operation::V2OperationEffect::Read,
            service.dataset_stats(request),
        ),
        VaultLifecycleRequest::Export(request) => (
            crate::v2::data_mobility::VAULT_EXPORT_TOOL,
            crate::v2::operation::V2OperationEffect::Read,
            service.vault_export(request),
        ),
        VaultLifecycleRequest::Import(request) => (
            crate::v2::data_mobility::VAULT_IMPORT_TOOL,
            crate::v2::operation::V2OperationEffect::Write,
            service.vault_import(request),
        ),
        VaultLifecycleRequest::Status(request) => (
            crate::v2::data_mobility::VAULT_STATUS_TOOL,
            crate::v2::operation::V2OperationEffect::Read,
            service.vault_status(request),
        ),
        VaultLifecycleRequest::Reconcile(request) => (
            crate::v2::data_mobility::VAULT_RECONCILE_TOOL,
            crate::v2::operation::V2OperationEffect::Write,
            service.vault_reconcile(request),
        ),
        VaultLifecycleRequest::Job(request) => (
            crate::v2::data_mobility::VAULT_JOB_TOOL,
            crate::v2::operation::V2OperationEffect::Read,
            service.vault_job(request),
        ),
    };
    let meta = packet_meta(meta, effect);
    match result {
        Ok(result) => {
            let text = vault_lifecycle_text(&result);
            let data = vault_lifecycle_data(result);
            let rendered = crate::v2::render::success(tool, &data, &meta, &text)
                .map_err(jsonrpc_internal)?;
            // return_id_map: append the second text block holding the id_map JSON
            // when the caller asked for it. The structured data already carries
            // id_map on every JSON import; this block serves text-only callers
            // that cannot read structuredContent. Swift twin: AriaV2DataMobility
            // .execute appends the same block after AriaV2Envelope.success.
            Ok(if return_id_map {
                crate::v2::render::append_id_map_block(rendered, &data)
            } else {
                rendered
            })
        },
        Err(V2DataMobilityError::Unavailable) => Ok(crate::v2::render::refusal(
            tool,
            &crate::v2::render::V2OperationalRefusal {
                code: "mobility_unavailable".to_owned(),
                message: "The requested data-mobility operation is unavailable in the selected estate.".to_owned(),
                retryable: false,
                recovery: None,
            },
            &meta,
        )),
        Err(V2DataMobilityError::OutcomeUnverified(_)) => Ok(crate::v2::render::refusal(
            tool,
            &crate::v2::render::V2OperationalRefusal {
                code: "outcome_unverified".to_owned(),
                message: "The data-mobility outcome could not be revalidated.".to_owned(),
                retryable: true,
                recovery: None,
            },
            &meta,
        )),
    }
}

fn vault_lifecycle_data(
    result: crate::v2::data_mobility::V2DataMobilityResult,
) -> serde_json::Value {
    use crate::v2::data_mobility::{V2DataMobilityResult, V2VaultJobTerminal};
    match result {
        V2DataMobilityResult::Reindex(result) => json!({
            "state": match result {
                crate::v2::data_mobility::V2ReindexState::Running => "running",
                crate::v2::data_mobility::V2ReindexState::AlreadyRunning => "already_running",
            },
        }),
        V2DataMobilityResult::ReclassifyFdc(result) => {
            // Build the data object, then insert the four optional fields only
            // when they carry a value. The optional keys must be absent (not
            // null) when there is no stored floor — the catalog schema declares
            // them outside the required list and additionalProperties:false
            // means any unexpected key is a validation failure.
            let mut data = json!({
                "applied": result.applied,
                "mode": result.mode,
                "estate_id": result.estate_id.hyphenated().to_string(),
                "fdc_data_version": result.fdc_data_version,
                "fdc_recalculation_version": result.fdc_recalculation_version,
                "scanned": result.scanned,
                "unchanged": result.unchanged,
                "empty_content": result.empty_content,
                "candidates": result.candidates,
                "updated": result.updated,
                "would_update": result.would_update,
                "unclassified_after": result.unclassified_after,
                "skipped_non_candidate_changes": result.skipped_non_candidate_changes,
                "floor_stamp": result.floor_stamp,
                "changes": result.changes.iter().map(|c| {
                    let mut entry = json!({
                        "id": c.id,
                        "old_code": c.old_code,
                        "new_code": c.new_code,
                    });
                    if let Some(ref q) = c.old_qid {
                        entry.as_object_mut().unwrap().insert("old_qid".to_owned(), json!(q));
                    }
                    if let Some(ref q) = c.new_qid {
                        entry.as_object_mut().unwrap().insert("new_qid".to_owned(), json!(q));
                    }
                    entry
                }).collect::<Vec<_>>(),
                "changes_omitted": result.changes_omitted,
            });
            if let Some(ref v) = result.estate_recalced_data_version_before {
                data.as_object_mut().unwrap().insert(
                    "estate_recalced_data_version_before".to_owned(),
                    json!(v),
                );
            }
            if let Some(ref v) = result.estate_recalced_data_version_after {
                data.as_object_mut().unwrap().insert(
                    "estate_recalced_data_version_after".to_owned(),
                    json!(v),
                );
            }
            data
        },
        V2DataMobilityResult::PalaceImport(result) => json!({
            "drawers_written": result.drawers_written,
            "drawers_updated": result.drawers_updated,
            "drawers_skipped_unchanged": result.drawers_skipped_unchanged,
            "drawers_skipped_tombstoned": result.drawers_skipped_tombstoned,
            "drawers_skipped_partial_write": result.drawers_skipped_partial_write,
            "tunnels_created": result.tunnels_created,
            "items_skipped": result.items_skipped,
            "fdc_classified": result.fdc_classified,
            "fdc_unclassified": result.fdc_unclassified,
            "fields_dropped": result.fields_dropped,
            "enqueued_for_encode": result.enqueued_for_encode,
        }),
        V2DataMobilityResult::JsonImport(result) => {
            let mut data = json!({
                "seed_name": result.seed_name,
                "drawers_written": result.drawers_written,
                "facts_written": result.facts_written,
                "tunnels_created": result.tunnels_created,
                "enqueued_for_encode": result.enqueued_for_encode,
                "subjects_provided": result.subjects_provided,
                "subjects_debt": result.subjects_debt,
                "seed_sha256": result.seed_sha256,
            });
            if let Some(id_map) = result.id_map {
                data.as_object_mut().expect("fixed JSON import object").insert("id_map".to_owned(), json!(
                    id_map.into_iter().map(|(record_id, drawer_id)| (
                        record_id, drawer_id.hyphenated().to_string(),
                    )).collect::<BTreeMap<_, _>>()
                ));
            }
            data
        }
        V2DataMobilityResult::DatasetFiled(result) => {
            let mut data = json!({
                "dataset_id": result.dataset_id.hyphenated().to_string(),
                "handle_memory_id": result.handle_memory_id.hyphenated().to_string(),
                "name": result.name,
                "location": result.location,
                "columns": result.columns,
                "rows": result.rows,
                "source": result.source,
                "sensitivity": result.sensitivity,
                "signatures": result.signatures,
            });
            if let Some(wing) = result.wing {
                data.as_object_mut().expect("fixed dataset-filed object").insert("wing".to_owned(), json!(wing));
            }
            data
        }
        V2DataMobilityResult::DatasetQuery(result) => {
            let mut data = json!({
                "dataset_id": result.dataset_id.hyphenated().to_string(),
                "handle_memory_id": result.handle_memory_id.hyphenated().to_string(),
                "state": result.state,
                "sensitivity": result.sensitivity,
                "rows_returned": result.rows_returned,
                "limit": result.limit,
                "rows": result.rows,
            });
            let object = data.as_object_mut().expect("fixed dataset-query object");
            if let Some(columns) = result.columns { object.insert("columns".to_owned(), json!(columns)); }
            if let Some(row_count) = result.handle_row_count { object.insert("handle_row_count".to_owned(), json!(row_count)); }
            data
        }
        V2DataMobilityResult::DatasetStats(result) => json!({
            "dataset_id": result.dataset_id.hyphenated().to_string(),
            "handle_memory_id": result.handle_memory_id.hyphenated().to_string(),
            "stats": result.stats.into_iter().map(|(column, stat)| (column, json!({
                "count": stat.count,
                "distinct_count": stat.distinct_count,
                "null_count": stat.null_count,
                "min": stat.min,
                "max": stat.max,
            }))).collect::<BTreeMap<_, _>>(),
        }),
        V2DataMobilityResult::VaultExport(result) => {
            let mut data = json!({
                "job_id": result.job_id.hyphenated().to_string(),
                "vault": result.vault,
                "scope": result.scope,
                "status": "complete",
            });
            let object = data.as_object_mut().expect("fixed vault export object");
            if let Some(count) = result.datasets_exported { object.insert("datasets_exported".to_owned(), json!(count)); }
            if let Some(warnings) = result.warnings { object.insert("warnings".to_owned(), json!(warnings)); }
            data
        }
        V2DataMobilityResult::VaultImport(result) => {
            let mut data = json!({
                "job_id": result.job_id.hyphenated().to_string(),
                "vault": result.vault,
                "note_count": result.note_count,
                "status": result.status,
            });
            let object = data.as_object_mut().expect("fixed vault import object");
            for (name, value) in [
                ("drawers_written", result.drawers_written), ("drawers_updated", result.drawers_updated),
                ("items_skipped", result.items_skipped), ("tunnels_created", result.tunnels_created),
                ("fdc_classified", result.fdc_classified), ("fdc_unclassified", result.fdc_unclassified),
                ("datasets_imported", result.datasets_imported),
            ] {
                if let Some(value) = value { object.insert(name.to_owned(), json!(value)); }
            }
            if let Some(warnings) = result.warnings { object.insert("warnings".to_owned(), json!(warnings)); }
            data
        }
        V2DataMobilityResult::VaultStatus(result) => {
            let mut data = json!({
                "manifest_present": result.manifest_present,
                "path": result.path,
            });
            let object = data.as_object_mut().expect("fixed vault status object");
            if let Some(last_export) = result.last_export { object.insert("last_export".to_owned(), json!(last_export)); }
            if let Some(note_count) = result.note_count { object.insert("note_count".to_owned(), json!(note_count)); }
            data
        }
        V2DataMobilityResult::VaultReconcile(result) => {
            let mut data = json!({
                "added": result.added,
                "modified": result.modified,
                "deleted": result.deleted,
                "missing": result.missing,
                "import_set_count": result.import_set_count,
                "candidate_count": result.candidate_count,
                "missing_count": result.missing_count,
                "applied": result.applied,
            });
            if let Some(candidates) = result.candidates {
                data.as_object_mut().expect("fixed vault reconcile object").insert("candidates".to_owned(), json!(
                    candidates.into_iter().map(|candidate| json!({
                        "stable_source_key": candidate.stable_source_key,
                        "vault_path": candidate.vault_path,
                        "sha256": candidate.sha256,
                    })).collect::<Vec<_>>()
                ));
            }
            data
        }
        V2DataMobilityResult::VaultJob(result) => {
            let mut data = json!({
                "job_id": result.job_id.hyphenated().to_string(),
                "kind": result.kind,
                "vault": result.vault,
                "status": result.status,
                "elapsed_ms": result.elapsed_millis,
            });
            if let Some(terminal) = result.terminal {
                let terminal = match terminal {
                    V2VaultJobTerminal::Imported {
                        drawers_written, drawers_updated, items_skipped, tunnels_created,
                        fdc_classified, fdc_unclassified, drawers_skipped_unchanged,
                        drawers_skipped_tombstoned,
                    } => json!({"import": {
                        "drawers_written": drawers_written, "drawers_updated": drawers_updated,
                        "items_skipped": items_skipped, "tunnels_created": tunnels_created,
                        "fdc_classified": fdc_classified, "fdc_unclassified": fdc_unclassified,
                        "drawers_skipped_unchanged": drawers_skipped_unchanged,
                        "drawers_skipped_tombstoned": drawers_skipped_tombstoned,
                    }}),
                    V2VaultJobTerminal::Exported { note_count, exported_at } =>
                        json!({"export": {"note_count": note_count, "exported_at": exported_at}}),
                };
                data.as_object_mut().expect("fixed vault job object").extend(
                    terminal.as_object().expect("fixed terminal object").clone(),
                );
            }
            data
        }
    }
}

/// Build the compact human report text for a vault lifecycle result.
///
/// For `ReclassifyFdc` this mirrors the Swift canonical output at
/// `AriaV2DataMobility.swift:583-620`: "estate: {name} [{uuid}]" and the
/// same line sequence. Swift is the primary port and wins all divergence.
///
/// All other eleven tools return the generic string unchanged, preserving
/// byte-identical output for those variants.
fn vault_lifecycle_text(result: &crate::v2::data_mobility::V2DataMobilityResult) -> String {
    use crate::v2::data_mobility::V2DataMobilityResult;
    match result {
        V2DataMobilityResult::ReclassifyFdc(r) => {
            // Swift emits \(handle.estateUUID) which calls UUID.description — always uppercase.
            // r.estate_id.to_string() is lowercase; .to_uppercase() matches Swift exactly.
            let estate_uuid_upper = r.estate_id.to_string().to_uppercase();
            // Mirrors Swift AriaV2DataMobility.swift:588:
            //   let limitSuffix = limit.map { " (limit \($0))" } ?? ""
            // One space before '(', word 'limit', one space, the number, ')'.
            let limit_suffix = r.limit.map(|n| format!(" (limit {n})")).unwrap_or_default();
            let mut lines = vec![
                format!("fdc_reclassify: {}", if r.applied { "applied" } else { "dry-run" }),
                format!("mode: {}", r.mode),
                // Swift emits "estate: {name} [{uuid}]" with UUID.description (uppercase).
                // The v2 builder carries estate_name and uses uppercase UUID to match Swift exactly.
                format!("estate: {} [{}]", r.estate_name, estate_uuid_upper),
                format!("fdc_data_version: {}", r.fdc_data_version),
                format!("fdc_recalculation_version: {}", r.fdc_recalculation_version),
                format!("estate_recalced_data_version_before: {}", r.estate_recalced_data_version_before.as_deref().unwrap_or("none")),
                format!("scanned: {} active drawer(s){}", r.scanned, limit_suffix),
                format!("unchanged: {}", r.unchanged),
                format!("empty_content: {}", r.empty_content),
                format!("candidates: {}", r.candidates),
                if r.applied { format!("updated: {}", r.updated) } else { format!("would_update: {}", r.would_update) },
                format!("unclassified_after: {}", r.unclassified_after),
                format!("skipped_non_candidate_changes: {}", r.skipped_non_candidate_changes),
                format!("estate_recalced_data_version_after: {}", r.estate_recalced_data_version_after.as_deref().unwrap_or("none")),
                format!("floor_stamp: {}", r.floor_stamp),
            ];
            if !r.applied {
                lines.push("dry_run: pass apply=true to write candidate anchor changes".to_owned());
            }
            if r.mode == "suspectOnly" && r.skipped_non_candidate_changes > 0 {
                lines.push(format!(
                    "note: mode=suspectOnly left {} changed non-suspect anchor(s) untouched; rerun with mode=all to reset every changed active drawer from content",
                    r.skipped_non_candidate_changes
                ));
            }
            if !r.changes.is_empty() {
                lines.push("changes:".to_owned());
                for change in &r.changes {
                    // Label format: "code [qid]" when QID present, "code" when absent.
                    // Mirrors FdcReclassifyChange::label() used by the v1 text builder.
                    let old_label = match &change.old_qid {
                        Some(q) => format!("{} [{}]", change.old_code, q),
                        None => change.old_code.clone(),
                    };
                    let new_label = match &change.new_qid {
                        Some(q) => format!("{} [{}]", change.new_code, q),
                        None => change.new_code.clone(),
                    };
                    lines.push(format!("  {}: {} -> {}", change.id, old_label, new_label));
                }
                if r.changes_omitted > 0 {
                    lines.push(format!("  ... {} more", r.changes_omitted));
                }
            }
            lines.join("\n")
        }
        _ => "Returned a direct typed vault lifecycle result.".to_owned(),
    }
}

fn execute_knowledge_journal(
    request: KnowledgeJournalRequest,
    registry: &crate::estate_registry::EstateRegistry,
    sensitivity_ledger: &crate::sensitivity_grant_ledger::SensitivityGrantLedger,
    meta: &crate::v2::render::V2ResultMeta,
    now_millis: i64,
) -> Result<serde_json::Value, JSONRPCError> {
    use crate::v2::knowledge_journal::{
        CoordinatorKnowledgeJournalLower, V2KnowledgeJournalError,
        V2KnowledgeJournalService,
    };
    let service = V2KnowledgeJournalService::new(
        SelectedKnowledgeJournalAuthority {
            registry,
            now_millis,
            maximum_sensitivity: sensitivity_ledger
                .ceiling_sensitivity(now_millis)
                .unwrap_or(locus_kit::adjectives::AdjectiveSensitivity::Elevated),
        },
        CoordinatorKnowledgeJournalLower::new(Arc::clone(&registry.default.coord)),
    );
    let (tool, effect, result) = match request {
        KnowledgeJournalRequest::ConnectionSearch(request) => (
            crate::v2::knowledge_journal::CONNECTION_SEARCH_TOOL,
            crate::v2::operation::V2OperationEffect::Read,
            service.connection_search(request),
        ),
        KnowledgeJournalRequest::ConnectionMap(request) => (
            crate::v2::knowledge_journal::CONNECTION_MAP_TOOL,
            crate::v2::operation::V2OperationEffect::Read,
            service.connection_map(request),
        ),
        KnowledgeJournalRequest::FileFact(request) => (
            crate::v2::knowledge_journal::FILE_FACT_TOOL,
            crate::v2::operation::V2OperationEffect::Write,
            service.file_fact(request),
        ),
        KnowledgeJournalRequest::FactSearch(request) => (
            crate::v2::knowledge_journal::FACT_SEARCH_TOOL,
            crate::v2::operation::V2OperationEffect::Read,
            service.fact_search(request),
        ),
        KnowledgeJournalRequest::RetireFact(request) => (
            crate::v2::knowledge_journal::RETIRE_FACT_TOOL,
            crate::v2::operation::V2OperationEffect::Write,
            service.retire_fact(request),
        ),
        KnowledgeJournalRequest::FactTimeline(request) => (
            crate::v2::knowledge_journal::FACT_TIMELINE_TOOL,
            crate::v2::operation::V2OperationEffect::Read,
            service.fact_timeline(request),
        ),
        KnowledgeJournalRequest::WriteJournal(request) => (
            crate::v2::knowledge_journal::WRITE_JOURNAL_TOOL,
            crate::v2::operation::V2OperationEffect::Write,
            service.write_journal(request),
        ),
        KnowledgeJournalRequest::ReadJournal(request) => (
            crate::v2::knowledge_journal::READ_JOURNAL_TOOL,
            crate::v2::operation::V2OperationEffect::Read,
            service.read_journal(request),
        ),
    };
    match result {
        Ok(result) => crate::v2::render::success(
            tool,
            &knowledge_journal_data(result),
            &packet_meta(meta, effect),
            "Returned a typed selected knowledge or journal result.",
        ).map_err(jsonrpc_internal),
        Err(V2KnowledgeJournalError::Unavailable) => Ok(crate::v2::render::refusal(
            tool,
            &crate::v2::render::V2OperationalRefusal {
                code: "estate_unavailable".to_owned(),
                message: "The requested knowledge or journal operation is unavailable.".to_owned(),
                retryable: true,
                recovery: None,
            },
            &packet_meta(meta, effect),
        )),
    }
}

fn knowledge_journal_data(result: crate::v2::knowledge_journal::V2KnowledgeJournalResult) -> serde_json::Value {
    use crate::v2::knowledge_journal::V2KnowledgeJournalResult;
    match result {
        V2KnowledgeJournalResult::Tunnels(edges) => json!({
            "edges": edges.into_iter().map(knowledge_tunnel_json).collect::<Vec<_>>()
        }),
        V2KnowledgeJournalResult::Fact(fact) => knowledge_fact_json(fact),
        V2KnowledgeJournalResult::Facts(facts) => json!({
            "facts": facts.into_iter().map(knowledge_fact_json).collect::<Vec<_>>()
        }),
        V2KnowledgeJournalResult::Retired { fact_id } => json!({
            "fact_id": fact_id.hyphenated().to_string()
        }),
        V2KnowledgeJournalResult::JournalEntry(entry) => knowledge_journal_entry_json(entry),
        V2KnowledgeJournalResult::JournalEntries(entries) => json!({
            "entries": entries.into_iter().map(knowledge_journal_entry_json).collect::<Vec<_>>()
        }),
    }
}

fn knowledge_tunnel_json(tunnel: crate::v2::knowledge_journal::V2KnowledgeTunnel) -> serde_json::Value {
    let mut value = json!({
        "tunnel_id": tunnel.tunnel_id.hyphenated().to_string(),
        "kind": tunnel.kind,
    });
    let object = value.as_object_mut().expect("fixed tunnel object");
    if let Some(from_id) = tunnel.from_id { object.insert("from_id".to_owned(), json!(from_id.hyphenated().to_string())); }
    if let Some(to_id) = tunnel.to_id { object.insert("to_id".to_owned(), json!(to_id.hyphenated().to_string())); }
    value
}

fn knowledge_fact_json(fact: crate::v2::knowledge_journal::V2KnowledgeFact) -> serde_json::Value {
    let mut value = json!({
        "fact_id": fact.fact_id.hyphenated().to_string(),
        "subject": fact.subject,
        "predicate": fact.predicate,
        "object": fact.object,
        "event_time": epoch_millis_to_rfc3339(fact.event_time_millis),
        "state": fact.state,
    });
    if let Some(source_memory_id) = fact.source_memory_id {
        value.as_object_mut().expect("fixed fact object").insert(
            "source_memory_id".to_owned(), json!(source_memory_id.hyphenated().to_string()),
        );
    }
    value
}

fn knowledge_journal_entry_json(entry: crate::v2::knowledge_journal::V2JournalEntry) -> serde_json::Value {
    json!({
        "agent_name": entry.agent_name,
        "entry": entry.entry,
        "written_at": epoch_millis_to_rfc3339(entry.written_at_millis),
    })
}

fn epoch_millis_to_rfc3339(millis: i64) -> String {
    let seconds = millis.div_euclid(1_000);
    let fraction = millis.rem_euclid(1_000);
    let days = seconds.div_euclid(86_400);
    let day_seconds = seconds.rem_euclid(86_400);
    let z = days + 719_468;
    let era = (if z >= 0 { z } else { z - 146_096 }).div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096).div_euclid(365);
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2).div_euclid(153);
    let day = doy - (153 * mp + 2).div_euclid(5) + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += (month <= 2) as i64;
    let hour = day_seconds / 3_600;
    let minute = (day_seconds % 3_600) / 60;
    let second = day_seconds % 60;
    if fraction == 0 {
        format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
    } else {
        format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{fraction:03}Z")
    }
}

fn cognition_catalog_request(
    value: &JsonValue,
) -> Result<crate::v2::cognition_catalog::CognitionCatalogRequest, JSONRPCError> {
    crate::v2::cognition_catalog::CognitionCatalogRequest::decode(value)
        .map_err(crate::v2::codec::V2InvalidArgument::into_jsonrpc_error)
}

fn execute_cognition_catalog(
    operation: crate::v2::cognition_catalog::CognitionCatalogOperation,
    request: crate::v2::cognition_catalog::CognitionCatalogRequest,
    selected_surface: &SelectedSurface,
    registry: &crate::estate_registry::EstateRegistry,
    meta: &crate::v2::render::V2ResultMeta,
) -> Result<serde_json::Value, JSONRPCError> {
    use crate::v2::cognition_catalog::CognitionCatalogOperation;
    let service = crate::v2::cognition_catalog::CognitionCatalogService::new(
        selected_memory_list_estate_id(registry),
        selected_surface.registry().operations()
            .map(|descriptor| descriptor.public_name.clone())
            .collect(),
    );
    let tool = match operation {
        CognitionCatalogOperation::Lenses => crate::v2::cognition_catalog::LIST_LENSES_TOOL,
        CognitionCatalogOperation::Recipes => crate::v2::cognition_catalog::LIST_RECIPES_TOOL,
    };
    // Typed responses carry the data; text is built from it to match Swift.
    match operation {
        CognitionCatalogOperation::Lenses => {
            match service.lenses(request) {
                Err(error) => Ok(crate::v2::render::refusal(
                    tool,
                    &crate::v2::render::V2OperationalRefusal {
                        code: error.code.to_owned(),
                        message: error.message.to_owned(),
                        retryable: error.retryable,
                        recovery: None,
                    },
                    meta,
                )),
                Ok(typed) => {
                    let count = typed.tools.len();
                    let data = serde_json::to_value(&typed)
                        .expect("typed cognition lens data must serialize");
                    // Parity with Swift: verbose emits "Listed N callable cognition
                    // tools (full schema). Tools: name1, name2, …"; terse emits
                    // "Listed N callable cognition tools." with a hint appended.
                    let text = if request.verbose {
                        let name_list: Vec<&str> = typed.tools.iter()
                            .map(|t| t.name.as_str()).collect();
                        format!(
                            "Listed {} callable cognition tools (full schema). Tools: {}",
                            count,
                            name_list.join(", ")
                        )
                    } else {
                        format!("Listed {} callable cognition tools.", count)
                    };
                    let result = crate::v2::render::success(tool, &data, meta, &text)
                        .map_err(jsonrpc_internal)?;
                    if request.verbose {
                        Ok(result)
                    } else {
                        Ok(crate::v2::render::apply_hint(
                            result, "(terse — pass verbose:true for the full schema row)",
                        ))
                    }
                }
            }
        }
        CognitionCatalogOperation::Recipes => {
            match service.recipes(request) {
                Err(error) => Ok(crate::v2::render::refusal(
                    tool,
                    &crate::v2::render::V2OperationalRefusal {
                        code: error.code.to_owned(),
                        message: error.message.to_owned(),
                        retryable: error.retryable,
                        recovery: None,
                    },
                    meta,
                )),
                Ok(typed) => {
                    let count = typed.recipes.len();
                    let data = serde_json::to_value(&typed)
                        .expect("typed cognition recipe data must serialize");
                    // Parity with Swift: verbose emits "Listed N recipe(s)." plus
                    // "\n<name> requires: <caps>…" lines when recipes have required
                    // capabilities. Terse emits "Listed N recipe(s)." with a hint appended.
                    let text = if request.verbose {
                        let caps_lines: Vec<String> = typed.recipes.iter()
                            .filter_map(|r| {
                                let caps = r.required_capabilities.as_deref()?;
                                if caps.is_empty() { return None; }
                                Some(format!("{} requires: {}", r.name, caps.join(", ")))
                            })
                            .collect();
                        if caps_lines.is_empty() {
                            format!("Listed {} recipe(s).", count)
                        } else {
                            format!("Listed {} recipe(s).\n{}", count, caps_lines.join("\n"))
                        }
                    } else {
                        format!("Listed {} recipe(s).", count)
                    };
                    let result = crate::v2::render::success(tool, &data, meta, &text)
                        .map_err(jsonrpc_internal)?;
                    if request.verbose {
                        Ok(result)
                    } else {
                        Ok(crate::v2::render::apply_hint(
                            result, "(terse — pass verbose:true for the full schema row)",
                        ))
                    }
                }
            }
        }
    }
}

fn execute_synthesize(
    request: crate::v2::orchestration::V2SynthesizeRequest,
    registry: &crate::estate_registry::EstateRegistry,
    meta: &crate::v2::render::V2ResultMeta,
) -> Result<serde_json::Value, JSONRPCError> {
    let service = crate::v2::orchestration::V2OrchestrationService::new(
        registry.default.estate_id,
        crate::v2::orchestration_lower::SelectedOrchestrationLower::new(registry),
    );
    match service.synthesize(request) {
        Ok(data) => crate::v2::render::success(
            "moot_synthesize",
            &synthesis_json(data),
            meta,
            "Grounded synthesis completed for the selected estate.",
        ).map_err(jsonrpc_internal),
        Err(error) => Ok(crate::v2::render::refusal(
            "moot_synthesize",
            &crate::v2::render::V2OperationalRefusal {
                code: match error {
                    crate::v2::orchestration::V2OrchestrationFailure::EstateUnavailable => "estate_unavailable",
                    crate::v2::orchestration::V2OrchestrationFailure::InvalidCue => "invalid_argument",
                    _ => "synthesis_unavailable",
                }.to_owned(),
                message: match error {
                    crate::v2::orchestration::V2OrchestrationFailure::InvalidCue =>
                        "query contains no usable terms (all tokens are stopwords or too short); provide distinctive words to ground on".to_owned(),
                    _ => "The selected estate could not produce a grounded synthesis.".to_owned(),
                },
                // A bad cue is the caller's to fix; the same call will not
                // start working.
                retryable: !matches!(error, crate::v2::orchestration::V2OrchestrationFailure::InvalidCue),
                recovery: None,
            },
            meta,
        )),
    }
}

struct SelectedDreamAuthority<'a> { registry: &'a crate::estate_registry::EstateRegistry, now_millis: i64 }

impl crate::v2::dream::V2DreamAuthority for SelectedDreamAuthority<'_> {
    fn admit(
        &self,
        requested: Option<Uuid>,
        requested_now: Option<i64>,
    ) -> Result<crate::v2::dream::V2DreamAdmission, crate::v2::dream::V2DreamAuthorityError> {
        let estate = &self.registry.default;
        if requested.is_some_and(|id| id != estate.estate_id) {
            return Err(crate::v2::dream::V2DreamAuthorityError::Unavailable);
        }
        // Resolve effective cycle clock.  A caller-proposed instant is admitted
        // when it falls within 24 hours of the authority clock; a further-future
        // value would advance pruneRecallTraces beyond the safe 30-day horizon.
        let effective_now = if let Some(proposed) = requested_now {
            let ceiling_millis = self.now_millis + 24 * 3600 * 1_000;
            if proposed > ceiling_millis {
                return Err(crate::v2::dream::V2DreamAuthorityError::InvalidArgument(
                    "Argument 'now' must not be more than 24 hours in the future.".to_owned(),
                ));
            }
            proposed
        } else {
            self.now_millis
        };
        Ok(crate::v2::dream::V2DreamAdmission {
            estate_id: estate.estate_id,
            estate_handle: estate.handle.clone(),
            caller_binding: self.registry.server_identity.clone(),
            authorization_generation: "selected-v2-public".to_owned(),
            now_millis: effective_now,
        })
    }
    fn revalidate(&self, admission: &crate::v2::dream::V2DreamAdmission) -> Result<(), ()> {
        (admission.estate_id == self.registry.default.estate_id).then_some(()).ok_or(())
    }
}

fn execute_dream(request: crate::v2::dream::V2DreamRequest, registry: &crate::estate_registry::EstateRegistry, meta: &crate::v2::render::V2ResultMeta, now_millis: i64) -> Result<serde_json::Value, JSONRPCError> {
    use crate::v2::dream::{V2DreamError, V2DreamService, V2DreamStatus, V2GeniusLocusDreamLower};
    let service = V2DreamService::new(SelectedDreamAuthority { registry, now_millis }, V2GeniusLocusDreamLower::new(Arc::clone(&registry.default.coord)));
    match service.execute(request) {
        Ok(result) if result.status == V2DreamStatus::Completed => crate::v2::render::success("moot_dream", &result.cycle.expect("completed dream receipt"), &packet_meta(meta, crate::v2::operation::V2OperationEffect::Write), "Dreaming cycle completed.").map_err(jsonrpc_internal),
        Ok(result) => Ok(crate::v2::render::refusal("moot_dream", &crate::v2::render::V2OperationalRefusal { code: format!("dream_{:?}", result.status).to_lowercase(), message: "The dreaming cycle did not complete.".to_owned(), retryable: true, recovery: None }, &packet_meta(meta, crate::v2::operation::V2OperationEffect::Write))),
        Err(V2DreamError::Unavailable) => Ok(crate::v2::render::refusal("moot_dream", &crate::v2::render::V2OperationalRefusal { code: "dream_unavailable".to_owned(), message: "The selected estate could not complete its dreaming cycle.".to_owned(), retryable: true, recovery: None }, &packet_meta(meta, crate::v2::operation::V2OperationEffect::Write))),
        Err(V2DreamError::OutcomeUnverified) => Ok(crate::v2::render::refusal("moot_dream", &crate::v2::render::V2OperationalRefusal { code: "outcome_unverified".to_owned(), message: "The dreaming outcome could not be revalidated.".to_owned(), retryable: false, recovery: None }, &packet_meta(meta, crate::v2::operation::V2OperationEffect::Write))),
        // Semantic range violation: caller-supplied now is too far in the future.
        // Raise -32602 so the destructive pruneRecallTraces path is never reached.
        Err(V2DreamError::InvalidArgument(message)) => {
            use crate::v2::codec::V2InvalidArgument;
            Err(V2InvalidArgument::new("now", message)
                .correction("Provide a 'now' no more than 24 hours in the future.")
                .into_jsonrpc_error())
        }
    }
}

fn execute_migration_run(request: crate::v2::orchestration::V2RunMigrationRequest, registry: &crate::estate_registry::EstateRegistry, meta: &crate::v2::render::V2ResultMeta) -> Result<serde_json::Value, JSONRPCError> {
    let service = crate::v2::orchestration::V2OrchestrationService::new(registry.default.estate_id, crate::v2::orchestration_lower::SelectedOrchestrationLower::new(registry));
    render_orchestration("moot_migration_run", service.run_migration(request), meta)
}

fn execute_migration_confirm(request: crate::v2::orchestration::V2ConfirmMigrationRequest, registry: &crate::estate_registry::EstateRegistry, meta: &crate::v2::render::V2ResultMeta) -> Result<serde_json::Value, JSONRPCError> {
    let service = crate::v2::orchestration::V2OrchestrationService::new(registry.default.estate_id, crate::v2::orchestration_lower::SelectedOrchestrationLower::new(registry));
    render_orchestration("moot_migration_confirm", service.confirm_migration(request), &packet_meta(meta, crate::v2::operation::V2OperationEffect::Write))
}

fn execute_federated_recall(request: crate::v2::orchestration::V2FederatedSearchRequest, registry: &crate::estate_registry::EstateRegistry, meta: &crate::v2::render::V2ResultMeta) -> Result<serde_json::Value, JSONRPCError> {
    let service = crate::v2::orchestration::V2OrchestrationService::new(registry.default.estate_id, crate::v2::orchestration_lower::SelectedOrchestrationLower::new(registry));
    render_orchestration("moot_federated_recall", service.federated_search(request), meta)
}

fn render_orchestration<T: Serialize>(tool: &str, result: Result<T, crate::v2::orchestration::V2OrchestrationFailure>, meta: &crate::v2::render::V2ResultMeta) -> Result<serde_json::Value, JSONRPCError> {
    match result {
        Ok(data) => crate::v2::render::success(tool, &data, meta, "The selected typed orchestration operation completed.").map_err(jsonrpc_internal),
        Err(error) => Ok(crate::v2::render::refusal(tool, &crate::v2::render::V2OperationalRefusal { code: if matches!(error, crate::v2::orchestration::V2OrchestrationFailure::EstateUnavailable) { "estate_unavailable" } else { "orchestration_unavailable" }.to_owned(), message: "The selected typed orchestration operation is unavailable.".to_owned(), retryable: true, recovery: None }, meta)),
    }
}

fn synthesis_json(data: crate::v2::orchestration::V2SynthesisData) -> serde_json::Value {
    let results = data.results.into_iter().map(|memory| {
        let memory_id = memory.memory_id.to_string();
        let mut value = json!({
            "memory_id": memory_id,
            "fetch": {"tool":"moot_memory_get","arguments":{"memory_id":memory.memory_id.to_string()}},
        });
        let object = value.as_object_mut().expect("synthesis memory is an object");
        if let Some(subject) = memory.subject { object.insert("subject".to_owned(), json!(subject)); }
        if let Some(score) = memory.score { object.insert("score".to_owned(), json!(score)); }
        if let Some(provenance) = memory.provenance { object.insert("provenance".to_owned(), json!(provenance)); }
        if let Some(context) = memory.context { object.insert("context".to_owned(), json!(context)); }
        if let Some(excerpt) = memory.excerpt { object.insert("excerpt".to_owned(), json!(excerpt)); }
        value
    }).collect::<Vec<_>>();
    let mut value = json!({"summary":data.summary,"results":results});
    if let Some(cues) = data.cues {
        value.as_object_mut().expect("synthesis data is an object")
            .insert("cues".to_owned(), json!(cues));
    }
    value
}

fn execute_recall(request: crate::v2::recall_lens::V2RecallLensRequest, registry: &crate::estate_registry::EstateRegistry, meta: &crate::v2::render::V2ResultMeta, now_millis: i64) -> Result<serde_json::Value, JSONRPCError> {
    use crate::v2::recall_lens::{V2PreciseRecallFailure, V2RecallLensOperation};
    let tool = request.operation.tool_name();
    if request.estate_id.is_some_and(|id| id != selected_memory_list_estate_id(registry)) { return Ok(crate::v2::render::refusal(tool, &crate::v2::render::V2OperationalRefusal { code: "estate_unavailable".into(), message: "The requested estate is not available to this caller.".into(), retryable: false, recovery: None }, meta)); }
    if matches!(
        request.operation,
        V2RecallLensOperation::LensKeystones
            | V2RecallLensOperation::LensConstellation
            | V2RecallLensOperation::LensFreeAssociation
            | V2RecallLensOperation::LensBias
            | V2RecallLensOperation::LensCohesion
            | V2RecallLensOperation::LensContradiction
            | V2RecallLensOperation::LensThemeWeather
            | V2RecallLensOperation::LensLatentThemes
            | V2RecallLensOperation::LensDrift
            | V2RecallLensOperation::LensTrustSynthesis
            | V2RecallLensOperation::LensPartialCue
            | V2RecallLensOperation::LensAnticipate
            | V2RecallLensOperation::LensNodeMotion
            | V2RecallLensOperation::LensSuccessors
            | V2RecallLensOperation::LensOverlap
            | V2RecallLensOperation::LensDivergence
            | V2RecallLensOperation::LensAssociations
            | V2RecallLensOperation::LensConcepts
            | V2RecallLensOperation::LensApriori
            | V2RecallLensOperation::LensMoment
            | V2RecallLensOperation::LensRhythm
            | V2RecallLensOperation::LensPrecedence
            | V2RecallLensOperation::LensComplexity
    ) {
        use crate::v2::recall_lens::V2RecallLensLower;
        let admission = crate::v2::recall_lens::V2RecallLensAdmission {
            estate_id: selected_memory_list_estate_id(registry),
            estate_handle: registry.default.handle.clone(),
            caller_binding: registry.server_identity.clone(),
            authorization_generation: format!(
                "selected-v2-public:{}:{}",
                selected_memory_list_estate_id(registry).hyphenated(),
                registry.server_identity,
            ),
            now_millis,
        };
        let lower = crate::v2::lens_lower::CoordinatorRecallLensLower::new(
            Arc::clone(&registry.default.coord),
        );
        return match lower.execute(&admission, &request) {
            Ok(result) => {
                let data = crate::v2::lens_lower::project_data(&result)
                    .map_err(|_| JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, "typed lens projection failed"))?;
                crate::v2::render::success(
                    tool,
                    &data,
                    meta,
                    "Returned a direct typed lens result.",
                ).map_err(jsonrpc_internal)
            }
            Err(()) => Ok(crate::v2::render::refusal(
                tool,
                &crate::v2::render::V2OperationalRefusal {
                    code: "lens_unavailable".into(),
                    message: "The requested lens operation is unavailable in the selected estate.".into(),
                    retryable: false,
                    recovery: None,
                },
                meta,
            )),
        };
    }
    let coordinator = registry.default.coord.lock().map_err(|_| {
        JSONRPCError::new(
            JSONRPCErrorCode::INTERNAL_ERROR,
            "selected estate coordinator lock poisoned",
        )
    })?;
    let result = match request.operation {
        V2RecallLensOperation::RecallPrecise => crate::v2::recall_lens::execute_precise_recall(&coordinator, &registry.default.handle, &request, now_millis).map(|data| crate::v2::recall_lens::V2RecipeRecallData { results: data.results, metadata: data.capabilities }),
        V2RecallLensOperation::RecallTemporal => crate::v2::recall_lens::execute_temporal_recall(&coordinator, &registry.default.handle, &request, now_millis),
        V2RecallLensOperation::RecallConnected => crate::v2::recall_lens::execute_connected_recall(&coordinator, &registry.default.handle, &request, now_millis),
        V2RecallLensOperation::RecallShaped => crate::v2::recall_lens::execute_shaped_recall(&coordinator, &registry.default.handle, &request, now_millis),
        V2RecallLensOperation::RecallDistilled => crate::v2::recall_lens::execute_distilled_recall(&coordinator, &registry.default.handle, &request, now_millis),
        V2RecallLensOperation::RecallVague => crate::v2::recall_lens::execute_vague_recall(&coordinator, &registry.default.handle, &request),
        V2RecallLensOperation::RecallWalk => crate::v2::recall_lens::execute_walk_recall(&coordinator, &registry.default.handle, &request, now_millis),
        _ => return Err(JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, "unsupported selected recall operation")),
    };
    match result {
        Ok(data) => {
            // moot_recall_distilled appends its savings display line after the
            // count; no other recall operation carries a distillation object.
            let mut text = format!("Returned {} typed recall result(s).", data.results.len());
            if let Some(display) = data.metadata.as_ref().and_then(|capabilities| capabilities["distillation"]["display"].as_str()) {
                text.push('\n');
                text.push_str(display);
            }
            crate::v2::render::success(tool, &data, meta, &text).map_err(jsonrpc_internal)
        }
        Err(V2PreciseRecallFailure::Invalid(error)) => Err(error.into_jsonrpc_error()),
        Err(V2PreciseRecallFailure::Unavailable) => Ok(crate::v2::render::refusal(tool, &crate::v2::render::V2OperationalRefusal { code: "recall_unavailable".into(), message: "Recall is unavailable for the selected estate.".into(), retryable: true, recovery: None }, meta)),
    }
}

fn estate_diagnostics_request(
    value: &JsonValue,
) -> Result<crate::v2::estate_diagnostics::EstateDiagnosticsRequest, JSONRPCError> {
    crate::v2::estate_diagnostics::EstateDiagnosticsRequest::decode(
        &serde_json::to_value(value).map_err(jsonrpc_internal)?,
    ).map_err(estate_diagnostics_decode_error)
}

fn estate_diagnostics_decode_error(
    error: crate::v2::estate_diagnostics::EstateDiagnosticsFailure,
) -> JSONRPCError {
    let (path, message) = error.message.split_once(' ').unwrap_or(("$", error.message.as_str()));
    JSONRPCError {
        code: JSONRPCErrorCode::INVALID_PARAMS,
        message: "Invalid arguments".to_owned(),
        data: Some(crate::v2::codec::V2InvalidArgument::new(path, message)
            .correction("correct the argument and retry this estate diagnostic")
            .data()),
    }
}

fn serialize_estate_diagnostics<T: Serialize>(
    result: Result<T, crate::v2::estate_diagnostics::EstateDiagnosticsFailure>,
) -> Result<serde_json::Value, crate::v2::estate_diagnostics::EstateDiagnosticsFailure> {
    result.map(|data| serde_json::to_value(data).expect("typed estate diagnostics data must serialize"))
}

fn execute_estate_diagnostics(
    operation: crate::v2::estate_diagnostics::EstateDiagnosticsOperation,
    request: crate::v2::estate_diagnostics::EstateDiagnosticsRequest,
    registry: &crate::estate_registry::EstateRegistry,
    build_id: &str,
    now_millis: i64,
    meta: &crate::v2::render::V2ResultMeta,
) -> Result<serde_json::Value, JSONRPCError> {
    use crate::v2::estate_diagnostics::EstateDiagnosticsOperation;
    let tool = match operation {
        EstateDiagnosticsOperation::Status => crate::v2::estate_diagnostics::ESTATE_STATUS_TOOL,
        EstateDiagnosticsOperation::Map => crate::v2::estate_diagnostics::ESTATE_MAP_TOOL,
        EstateDiagnosticsOperation::Ping => crate::v2::estate_diagnostics::ESTATE_PING_TOOL,
        EstateDiagnosticsOperation::Drain => crate::v2::estate_diagnostics::DRAIN_STATUS_TOOL,
        EstateDiagnosticsOperation::Rebuild => crate::v2::estate_diagnostics::REBUILD_STATUS_TOOL,
        EstateDiagnosticsOperation::Timing => crate::v2::estate_diagnostics::TIMING_REPORT_TOOL,
    };
    let context = crate::v2::estate_diagnostics::EstateDiagnosticsContext {
        caller_binding: registry.server_identity.clone(),
        session_id: "selected-v2-public".to_owned(),
        clock_millis: now_millis,
        build_serial: build_id.to_owned(),
    };
    let service = crate::v2::estate_diagnostics::EstateDiagnosticsService::new(
        crate::v2::estate_diagnostics_provider::SelectedEstateDiagnosticsAuthority::new(registry),
    );
    let result = match operation {
        EstateDiagnosticsOperation::Status => serialize_estate_diagnostics(service.status(request, &context)),
        EstateDiagnosticsOperation::Map => serialize_estate_diagnostics(service.map(request, &context)),
        EstateDiagnosticsOperation::Ping => serialize_estate_diagnostics(service.ping(request, &context)),
        EstateDiagnosticsOperation::Drain => serialize_estate_diagnostics(service.drain(request, &context)),
        EstateDiagnosticsOperation::Rebuild => serialize_estate_diagnostics(service.rebuild(request, &context)),
        EstateDiagnosticsOperation::Timing => serialize_estate_diagnostics(service.timing(request, &context)),
    };
    match result {
        Ok(data) => crate::v2::render::success(
            tool, &data, meta, "Returned current selected-estate diagnostics.",
        ).map_err(jsonrpc_internal),
        Err(error) => Ok(crate::v2::render::refusal(
            tool,
            &crate::v2::render::V2OperationalRefusal {
                code: error.code.to_owned(),
                message: error.message,
                retryable: error.retryable,
                recovery: None,
            },
            meta,
        )),
    }
}

fn execute_memory_list(
    request: crate::v2::memory_list::MemoryListRequest,
    registry: &crate::estate_registry::EstateRegistry,
    cursors: &Arc<crate::v2::memory_list::MemoryListCursorStore>,
    meta: &crate::v2::render::V2ResultMeta,
    now_millis: i64,
) -> Result<serde_json::Value, JSONRPCError> {
    let authority = SelectedMemoryListAuthority { registry };
    let provider = crate::v2::memory_list_snapshot_provider::AriaMemoryListSnapshotProvider::new(
        Arc::clone(&registry.default.coord),
        authority,
    );
    let service = crate::v2::memory_list::MemoryListService::new_with_cursor_store(
        provider,
        selected_memory_list_estate_id(registry),
        Arc::clone(cursors),
    );
    match service.list(request, now_millis) {
        Ok(page) => crate::v2::render::success(
            crate::v2::memory_list::MEMORY_LIST_TOOL,
            &page,
            meta,
            "Enumerated a complete current authorized memory inventory.",
        ).map_err(jsonrpc_internal),
        Err(error) => Ok(memory_list_refusal(error, meta)),
    }
}

fn contradiction_binding(
    registry: &crate::estate_registry::EstateRegistry,
) -> crate::v2::contradictions::V2ContradictionAnalysisBinding {
    let estate_id = selected_memory_list_estate_id(registry);
    crate::v2::contradictions::V2ContradictionAnalysisBinding {
        estate_id,
        authorization_context: format!("selected-v2-public:{}", registry.server_identity),
        // The lower serializable proposal boundary recomputes the selected
        // source/evidence digests, so a changed row cannot become a proposal
        // merely because the public caller binding is unchanged.
        analysis_revision: format!("selected-v2-contradictions:{}:{}", estate_id.hyphenated(), registry.server_identity),
    }
}

fn contradiction_refusal(
    tool: &str,
    code: &str,
    message: &str,
    retryable: bool,
    meta: &crate::v2::render::V2ResultMeta,
) -> serde_json::Value {
    crate::v2::render::refusal(tool, &crate::v2::render::V2OperationalRefusal {
        code: code.to_owned(), message: message.to_owned(), retryable, recovery: None,
    }, meta)
}

fn execute_contradiction_hunt(
    request: crate::v2::contradictions::V2ContradictionHuntRequest,
    registry: &crate::estate_registry::EstateRegistry,
    analyses: &Arc<Mutex<crate::v2::contradictions::V2ContradictionAnalysisCache>>,
    meta: &crate::v2::render::V2ResultMeta,
    now_millis: i64,
) -> Result<serde_json::Value, JSONRPCError> {
    if request.estate_id.is_some_and(|id| id != selected_memory_list_estate_id(registry)) {
        return Ok(contradiction_refusal(
            crate::v2::contradictions::CONTRADICTION_HUNT_TOOL, "estate_unavailable",
            "The requested estate is not available to this caller.", false, meta,
        ));
    }
    let mut analyses = match analyses.lock() {
        Ok(analyses) => analyses,
        Err(_) => return Ok(contradiction_refusal(
            crate::v2::contradictions::CONTRADICTION_HUNT_TOOL, "analysis_unavailable",
            "Contradiction analysis state is unavailable.", true, meta,
        )),
    };
    let result = crate::v2::contradictions::execute_coordinator_hunt(
        &registry.default.coord, &registry.default.handle, &mut analyses,
        contradiction_binding(registry), request.limit.unwrap_or(50), now_millis,
    );
    match result {
        Ok(result) => {
            let evidence = match crate::v2::contradictions::coordinator_candidate_evidence(
                &registry.default.coord,
                &registry.default.handle,
                &result.candidates,
            ) {
                Ok(evidence) => evidence,
                Err(_) => return Ok(contradiction_refusal(
                    crate::v2::contradictions::CONTRADICTION_HUNT_TOOL, "analysis_unavailable",
                    "Contradiction evidence changed before it could be rendered; run the hunt again.", true, meta,
                )),
            };
            crate::v2::render::success(
                crate::v2::contradictions::CONTRADICTION_HUNT_TOOL,
                &json!({
                    "analysis_ref": result.analysis_ref,
                    "expires_at": epoch_millis_to_rfc3339(result.expires_at_ms),
                    "candidates": evidence.into_iter().map(|candidate| json!({
                        "candidate_id": candidate.candidate_id,
                        "reason": candidate.reason,
                        "source": contradiction_endpoint(candidate.source_memory_id, candidate.source_excerpt),
                        "target": contradiction_endpoint(candidate.target_memory_id, candidate.target_excerpt),
                    })).collect::<Vec<_>>(),
                }), meta, "Contradiction candidates are retained for explicit selection.",
            ).map_err(jsonrpc_internal)
        }
        Err(_) => Ok(contradiction_refusal(
            crate::v2::contradictions::CONTRADICTION_HUNT_TOOL, "analysis_unavailable",
            "Contradiction analysis is unavailable.", true, meta,
        )),
    }
}

fn contradiction_endpoint(memory_id: String, excerpt: String) -> serde_json::Value {
    json!({
        "memory_id": memory_id.clone(),
        "excerpt": excerpt,
        "fetch": {
            "tool": crate::v2::core_memory::MEMORY_GET_TOOL,
            "arguments": {"memory_id": memory_id},
        },
    })
}

fn execute_contradiction_proposal(
    request: crate::v2::contradictions::V2ContradictionProposalRequest,
    registry: &crate::estate_registry::EstateRegistry,
    analyses: &Arc<Mutex<crate::v2::contradictions::V2ContradictionAnalysisCache>>,
    meta: &crate::v2::render::V2ResultMeta,
    now_millis: i64,
) -> Result<serde_json::Value, JSONRPCError> {
    let write_meta = packet_meta(meta, crate::v2::operation::V2OperationEffect::Write);
    if request.estate_id.is_some_and(|id| id != selected_memory_list_estate_id(registry)) {
        return Ok(contradiction_refusal(
            crate::v2::contradictions::CONTRADICTION_PROPOSE_TOOL, "estate_unavailable",
            "The requested estate is not available to this caller.", false, &write_meta,
        ));
    }
    let mut analyses = match analyses.lock() {
        Ok(analyses) => analyses,
        Err(_) => return Ok(contradiction_refusal(
            crate::v2::contradictions::CONTRADICTION_PROPOSE_TOOL, "proposal_unavailable",
            "Contradiction proposal state is unavailable.", true, &write_meta,
        )),
    };
    let expires_at_ms = match analyses.expires_at_ms(&request.analysis_ref, now_millis) {
        Some(expires_at_ms) => expires_at_ms,
        None => return Ok(contradiction_refusal(
            crate::v2::contradictions::CONTRADICTION_PROPOSE_TOOL, "proposal_expired",
            "The contradiction analysis reference expired or was evicted; run the hunt again.", true, &write_meta,
        )),
    };
    let candidate_ids = request.candidate_ids.clone();
    match crate::v2::contradictions::execute_coordinator_proposal(
        &registry.default.coord, &registry.default.handle, &mut analyses, &request,
        &contradiction_binding(registry), now_millis,
    ) {
        Ok(statuses) => crate::v2::render::success(
            crate::v2::contradictions::CONTRADICTION_PROPOSE_TOOL,
            &json!({
                "analysis_ref": request.analysis_ref,
                "expires_at": epoch_millis_to_rfc3339(expires_at_ms),
                "candidates": candidate_ids.into_iter().zip(statuses).map(|(candidate_id, status)| {
                    let mut value = serde_json::to_value(status).expect("typed contradiction status serializes");
                    value.as_object_mut().expect("typed contradiction status is an object").insert("candidate_id".to_owned(), json!(candidate_id));
                    value
                }).collect::<Vec<_>>(),
            }), &write_meta, "Selected contradiction candidates were filed or resolved.",
        ).map_err(jsonrpc_internal),
        Err(refusal) => Ok(contradiction_refusal(
            crate::v2::contradictions::CONTRADICTION_PROPOSE_TOOL, refusal.code,
            &refusal.message, refusal.retryable, &write_meta,
        )),
    }
}

struct SelectedMemoryListAuthority<'a> {
    registry: &'a crate::estate_registry::EstateRegistry,
}

impl SelectedMemoryListAuthority<'_> {
    fn context(&self) -> crate::v2::memory_list_snapshot_provider::MemoryListAuthorizedContext {
        const CONTEXT: &str = "selected-v2-public";
        const POLICY: &str = "aria-v2-memory-list-public-v1";
        let estate = &self.registry.default;
        let estate_id = selected_memory_list_estate_id(self.registry);
        let generation = format!(
            "v1:{}:{}:{}",
            estate_id.hyphenated(),
            self.registry.server_identity.len(),
            self.registry.server_identity,
        );
        crate::v2::memory_list_snapshot_provider::MemoryListAuthorizedContext {
            estate_id,
            estate_handle: estate.handle.clone(),
            caller_binding: self.registry.server_identity.clone(),
            context_id: CONTEXT.to_owned(),
            policy_version: POLICY.to_owned(),
            authorization_generation: generation,
        }
    }
}

impl crate::v2::memory_list_snapshot_provider::MemoryListAuthorizationAuthority
    for SelectedMemoryListAuthority<'_>
{
    fn authorize_memory_list(
        &self,
        requested_estate_id: Option<Uuid>,
    ) -> Result<crate::v2::memory_list_snapshot_provider::MemoryListAuthorizedContext, crate::v2::memory_list::MemoryListError> {
        if requested_estate_id.is_some_and(|estate_id| estate_id != selected_memory_list_estate_id(self.registry)) {
            return Err(crate::v2::memory_list::MemoryListError::operational(
                "estate_unavailable",
                "The requested estate is not available to this caller.",
                false,
            ));
        }
        Ok(self.context())
    }

    fn revalidate_memory_list(
        &self,
        authorization: &crate::v2::memory_list::MemoryListAuthorization,
    ) -> Result<crate::v2::memory_list_snapshot_provider::MemoryListAuthorizedContext, crate::v2::memory_list::MemoryListError> {
        let context = self.context();
        let expected = crate::v2::memory_list::MemoryListAuthorization {
            caller_binding: context.caller_binding.clone(),
            context_id: context.context_id.clone(),
            policy_version: context.policy_version.clone(),
        };
        if *authorization != expected {
            return Err(crate::v2::memory_list::MemoryListError::operational(
                "inventory_unavailable",
                "The complete authorized memory inventory is unavailable.",
                true,
            ));
        }
        Ok(context)
    }
}

fn selected_memory_list_estate_id(registry: &crate::estate_registry::EstateRegistry) -> Uuid {
    Uuid::from_bytes(registry.default.handle.estate_uuid)
}

/// Selected-v2 mutation admission stays bound to the single public estate.
/// The lower service revalidates this binding after every write before the
/// surface can claim a completed result.
struct SelectedMemoryMutationAuthority<'a> {
    registry: &'a crate::estate_registry::EstateRegistry,
    now_millis: i64,
}

impl crate::v2::memory_mutations::V2MemoryMutationAuthority
    for SelectedMemoryMutationAuthority<'_>
{
    fn admit(
        &self,
        _operation: crate::v2::memory_mutations::V2MemoryMutationOperation,
        requested_estate_id: Option<Uuid>,
    ) -> Result<crate::v2::memory_mutations::V2MemoryMutationAdmission, ()> {
        let estate = &self.registry.default;
        if requested_estate_id.is_some_and(|estate_id| estate_id != estate.estate_id) {
            return Err(());
        }
        Ok(crate::v2::memory_mutations::V2MemoryMutationAdmission {
            estate_id: estate.estate_id,
            estate_handle: estate.handle.clone(),
            caller_binding: self.registry.server_identity.clone(),
            now_millis: self.now_millis,
            authorization_generation: format!(
                "selected-v2-public:{}:{}",
                estate.estate_id.hyphenated(), self.registry.server_identity,
            ),
        })
    }

    fn revalidate(
        &self,
        admission: &crate::v2::memory_mutations::V2MemoryMutationAdmission,
    ) -> Result<(), ()> {
        let estate = &self.registry.default;
        (admission.estate_id == estate.estate_id
            && admission.caller_binding == self.registry.server_identity)
            .then_some(())
            .ok_or(())
    }
}

struct SelectedKnowledgeJournalAuthority<'a> {
    registry: &'a crate::estate_registry::EstateRegistry,
    now_millis: i64,
    maximum_sensitivity: locus_kit::adjectives::AdjectiveSensitivity,
}

impl crate::v2::knowledge_journal::V2KnowledgeJournalAuthority
    for SelectedKnowledgeJournalAuthority<'_>
{
    fn admit(
        &self,
        _operation: crate::v2::knowledge_journal::V2KnowledgeJournalOperation,
        requested_estate_id: Option<Uuid>,
    ) -> Result<crate::v2::knowledge_journal::V2KnowledgeJournalAdmission, ()> {
        let estate = &self.registry.default;
        if requested_estate_id.is_some_and(|estate_id| estate_id != estate.estate_id) {
            return Err(());
        }
        Ok(crate::v2::knowledge_journal::V2KnowledgeJournalAdmission {
            estate_id: estate.estate_id,
            estate_handle: estate.handle.clone(),
            caller_binding: self.registry.server_identity.clone(),
            maximum_sensitivity: self.maximum_sensitivity,
            now_millis: self.now_millis,
        })
    }
}

fn memory_list_refusal(
    error: crate::v2::memory_list::MemoryListError,
    meta: &crate::v2::render::V2ResultMeta,
) -> serde_json::Value {
    crate::v2::render::refusal(
        crate::v2::memory_list::MEMORY_LIST_TOOL,
        &crate::v2::render::V2OperationalRefusal {
            code: error.code.to_owned(),
            message: error.message,
            retryable: error.retryable,
            recovery: None,
        },
        meta,
    )
}

fn memory_list_decode_error(error: crate::v2::memory_list::MemoryListError) -> JSONRPCError {
    let path = error.path.unwrap_or_else(|| "$".to_owned());
    JSONRPCError {
        code: JSONRPCErrorCode::INVALID_PARAMS,
        message: "Invalid arguments".to_owned(),
        data: Some(crate::v2::codec::V2InvalidArgument::new(path, error.message)
            .correction("correct the argument and retry moot_memory_list")
            .data()),
    }
}

/// Historical name; not a work-packet function. The name predates the
/// work-packet capability withdrawal (2026-09-10) and is preserved to
/// avoid churn at seven live call sites. This helper builds an incomplete
/// [`crate::v2::render::V2ResultMeta`] for any write-effect operation
/// that must report a side effect without a fully-resolved final state.
///
/// Live callers (none are packet operations):
/// - `execute`
/// - `execute_memory_mutation`
/// - `execute_vault_lifecycle`
/// - `execute_knowledge_journal`
/// - `execute_dream`
/// - `execute_migration_confirm`
/// - `execute_contradiction_proposal`
fn packet_meta(
    base: &crate::v2::render::V2ResultMeta,
    effect: crate::v2::operation::V2OperationEffect,
) -> crate::v2::render::V2ResultMeta {
    crate::v2::render::V2ResultMeta::incomplete(
        base.build_id.clone(), base.capability_digest.clone(), effect,
    )
}

fn render_monitoring_status(
    monitoring: &str,
    meta: &crate::v2::render::V2ResultMeta,
) -> serde_json::Value {
    json!({
        "content": [{
            "type": "text",
            "text": format!("monitoring: {monitoring}\nsurface: v2 (incomplete)")
        }],
        "structuredContent": {
            "surface_version": "v2",
            "tool": "moot_monitoring_status",
            "data": { "monitoring": monitoring },
            "meta": {
                "build_id": meta.build_id,
                "capability_digest": meta.capability_digest,
                "completeness": meta.completeness,
                "effect": meta.effect
            }
        },
        "isError": false
    })
}

fn jsonrpc_internal(error: serde_json::Error) -> JSONRPCError {
    JSONRPCError::new(JSONRPCErrorCode::INTERNAL_ERROR, error.to_string())
}

fn invalid_argument(path: &str, message: &str) -> JSONRPCError {
    JSONRPCError {
        code: JSONRPCErrorCode::INVALID_PARAMS,
        message: message.to_owned(),
        data: Some(json!({
            "code": "invalid_argument",
            "path": path,
            "message": message,
            "correction": "Call moot_monitoring_status with an empty arguments object."
        })),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selected_catalog_and_admission_match_each_other() {
        let surface = SelectedSurface::selected(false, true);
        {
            assert_eq!(surface.catalog().as_array().unwrap().len(), 73);
            assert!(surface
                .catalog()
                .as_array()
                .unwrap()
                .iter()
                .any(|tool| tool["name"] == "moot_monitoring_status"));
            assert!(surface.accepted_arg_keys("moot_vault_export").is_none());
            assert!(surface
                .decode("moot_vault_export", &BTreeMap::new())
                .is_err());
            assert_eq!(
                surface.accepted_arg_keys("moot_monitoring_status"),
                Some(HashSet::new())
            );
            assert!(surface
                .decode("moot_monitoring_status", &BTreeMap::new())
                .unwrap()
                .is_some());
            assert!(surface
                .decode("moot_file_memory", &BTreeMap::new())
                .is_err());

            let enabled = SelectedSurface::selected(true, false);
            assert_eq!(enabled.catalog().as_array().unwrap().len(), 80);
            assert!(enabled.accepted_arg_keys("moot_vault_export").is_some());
            assert_ne!(surface.capability_digest(), enabled.capability_digest());
            let help = crate::v2::help::resolve_help(
                surface.registry(),
                &crate::v2::help::V2HelpRequest::default(),
            )
            .unwrap()
            .as_value();
            assert_eq!(help["operations"].as_array().unwrap().len(), 73);
            assert!(help["operations"].as_array().unwrap().iter().all(|operation| {
                operation["name"].as_str() != Some("moot_vault_export")
            }));
        }
    }

    /// Gate: `ErasedPartially` renders as `"erased_partially"` (with underscore)
    /// to match the Swift port wire value.  Before the fix the Debug-plus-lowercase
    /// path produced `"erasedpartially"` (no separator).
    ///
    /// These tests FAIL against the original code (line 665 of the pre-fix surface.rs
    /// returned `format!("{:?}", outcome).to_lowercase()` for every variant) and
    /// PASS after the fix introduces `mutation_outcome_wire_value`.
    #[test]
    fn erased_partially_outcome_renders_with_underscore_matching_swift_port() {
        // Pre-fix assertion failure text:
        //   assertion `left == right` failed
        //     left: "erasedpartially"
        //    right: "erased_partially"
        assert_eq!(
            mutation_outcome_wire_value(
                crate::v2::memory_mutations::V2MemoryMutationOutcome::ErasedPartially
            ),
            "erased_partially",
            "ErasedPartially must render as \"erased_partially\" to match the Swift port"
        );
    }

    /// Gate: a full erase must still emit `"erased"`, not `"erased_partially"`.
    /// A careless fix that routes every erase through the explicit arm would
    /// break this.
    #[test]
    fn erased_outcome_renders_as_erased_not_partially() {
        assert_eq!(
            mutation_outcome_wire_value(
                crate::v2::memory_mutations::V2MemoryMutationOutcome::Erased
            ),
            "erased",
            "Erased must render as \"erased\", not \"erased_partially\""
        );
    }

    /// Gate: `execute_memory_mutation` emits `"erased_partially"` (with underscore)
    /// in the actual JSON response for an erase whose outcome is `ErasedPartially`.
    ///
    /// This test exercises the emission path — line 686 in `execute_memory_mutation` —
    /// not just the helper function `mutation_outcome_wire_value`.  Reverting line 686
    /// to `format!("{:?}", result.outcome).to_lowercase()` (while leaving the helper
    /// defined but unwired) produces `"erasedpartially"` (no separator) and causes
    /// this assertion to fail.
    ///
    /// Setup: seed an accepted drawer (D1) and an active sibling (D2) in the same
    /// lineage.  The audit gate refuses D1 during expunge, so erasing D2 yields
    /// `ErasedPartially` and the response carries the partially-erased outcome.
    #[test]
    fn execute_memory_mutation_emits_erased_partially_for_emission_path() {
        use locus_kit::adjectives::Trust;
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;
        use locus_kit::frames::{CaptureFrame, MutationKind};
        use crate::estate_posture::EstatePosture;
        use crate::estate_registry::EstateRegistry;
        use crate::surfaced_recall_ledger::SurfacedRecallLedger;
        use crate::v2::memory_mutations::V2EraseMemoryRequest;
        use crate::v2::operation::V2OperationEffect;
        use crate::v2::render::V2ResultMeta;

        // Milliseconds — matches INIT_NOW used by InMemoryDrawerStore.
        const NOW: i64 = 1_700_000_000_000_i64;

        let registry = EstateRegistry::new_inmemory();
        let handle = registry.default.handle.clone();

        // Seed D1 (accepted) and D2 (active sibling in the same lineage).
        // The audit gate refuses D1 during expunge (S-3: Accepted → Tombstoned
        // is a forbidden transition), so erasing D2 yields ErasedPartially.
        let d2_id: String = {
            let coord = registry.coord.lock().expect("coord lock");

            let d1 = coord.capture(
                &handle,
                CaptureFrame::new(
                    "accepted anchor kept by audit gate during partial lineage expunge",
                    CaptureChannel::Typed,
                    "default",
                    LatticeAnchor::udc("000"),
                    "test",
                    "test-embed-v1",
                ),
                NOW,
            ).expect("capture d1");

            coord.mutate(&handle, &d1.id, MutationKind::CorrectTrust(Trust::Canonical), None)
                .expect("correct trust to canonical");
            coord.mutate(&handle, &d1.id, MutationKind::Accept, None)
                .expect("accept d1");

            let mut d2_frame = CaptureFrame::new(
                "active sibling to erase — triggers ErasedPartially because D1 is refused",
                CaptureChannel::Typed,
                "default",
                LatticeAnchor::udc("000"),
                "test",
                "test-embed-v1",
            );
            d2_frame.lineage_id = Some(d1.lineage_id);

            let d2 = coord.capture(&handle, d2_frame, NOW + 100)
                .expect("capture d2");
            d2.id.clone()
        }; // Mutex guard dropped here before execute_memory_mutation re-acquires it.

        let d2_uuid = Uuid::parse_str(&d2_id).expect("parse d2 uuid");
        let meta = V2ResultMeta::incomplete("test-build", "test-digest", V2OperationEffect::Write);
        let ledger = SurfacedRecallLedger::new();

        // This call drives line 686 inside execute_memory_mutation.
        let response = execute_memory_mutation(
            MemoryMutationRequest::Erase(V2EraseMemoryRequest {
                memory_id: d2_uuid,
                confirmation: true,
                reason: None,
                estate_id: None,
            }),
            &registry,
            &meta,
            NOW + 200,
            EstatePosture::Live,
            &ledger,
        ).expect("erase must succeed");

        // The "outcome" field is at structuredContent.data.outcome in the
        // v2 response envelope (see v2/render.rs: success wraps data inside
        // structuredContent).  If line 686 is reverted to the old
        // `format!("{:?}", result.outcome).to_lowercase()` path, the value
        // here is "erasedpartially" (no underscore) and this assertion fails.
        assert_eq!(
            response["structuredContent"]["data"]["outcome"],
            "erased_partially",
            "execute_memory_mutation must emit \"erased_partially\" (with underscore) \
             for ErasedPartially; a revert to format! debug+lowercase yields \"erasedpartially\""
        );
    }

    /// Negative case: a full erase (no refused siblings) must emit `"erased"`,
    /// not `"erased_partially"`.  Exercises the same emission path as the
    /// partial-erase gate above.
    #[test]
    fn execute_memory_mutation_emits_erased_for_full_erase_emission_path() {
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::estate_types::LatticeAnchor;
        use locus_kit::frames::CaptureFrame;
        use crate::estate_posture::EstatePosture;
        use crate::estate_registry::EstateRegistry;
        use crate::surfaced_recall_ledger::SurfacedRecallLedger;
        use crate::v2::memory_mutations::V2EraseMemoryRequest;
        use crate::v2::operation::V2OperationEffect;
        use crate::v2::render::V2ResultMeta;

        const NOW: i64 = 1_700_000_000_000_i64;

        let registry = EstateRegistry::new_inmemory();
        let handle = registry.default.handle.clone();

        let d1_id: String = {
            let coord = registry.coord.lock().expect("coord lock");
            let d1 = coord.capture(
                &handle,
                CaptureFrame::new(
                    "memory with no accepted siblings — full erase expected",
                    CaptureChannel::Typed,
                    "default",
                    LatticeAnchor::udc("000"),
                    "test",
                    "test-embed-v1",
                ),
                NOW,
            ).expect("capture d1");
            d1.id.clone()
        };

        let d1_uuid = Uuid::parse_str(&d1_id).expect("parse uuid");
        let meta = V2ResultMeta::incomplete("test-build", "test-digest", V2OperationEffect::Write);
        let ledger = SurfacedRecallLedger::new();

        let response = execute_memory_mutation(
            MemoryMutationRequest::Erase(V2EraseMemoryRequest {
                memory_id: d1_uuid,
                confirmation: true,
                reason: None,
                estate_id: None,
            }),
            &registry,
            &meta,
            NOW + 200,
            EstatePosture::Live,
            &ledger,
        ).expect("full erase must succeed");

        assert_eq!(
            response["structuredContent"]["data"]["outcome"],
            "erased",
            "execute_memory_mutation must emit \"erased\" for a full erase with no refused siblings"
        );
    }
}
