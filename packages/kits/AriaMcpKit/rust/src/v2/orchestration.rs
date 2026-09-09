//! Typed, dormant ARIA v2 orchestration foundation.
//!
//! This module has no selected-catalog or surface registration.  Its provider
//! boundary carries the direct lower-engine values for synthesis, migration,
//! explicit promotion, and federated recall.  It never calls the v1 runner or
//! reparses a rendered response.

use uuid::Uuid;
use serde::Serialize;

use crate::jsonrpc::JsonValue;

use super::codec::{
    optional_integer, optional_string, optional_uuid, required_string, required_uuid, strict_object,
    V2DecodeResult, V2InvalidArgument,
};

pub const SYNTHESIZE_TOOL: &str = "moot_synthesize";
pub const RUN_MIGRATION_TOOL: &str = "moot_migration_run";
pub const CONFIRM_MIGRATION_TOOL: &str = "moot_migration_confirm";
pub const FEDERATED_SEARCH_TOOL: &str = "moot_federated_recall";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2OrchestrationOperation {
    Synthesize,
    RunMigration,
    ConfirmMigration,
    FederatedSearch,
}

impl V2OrchestrationOperation {
    pub const fn tool_name(self) -> &'static str {
        match self {
            Self::Synthesize => SYNTHESIZE_TOOL,
            Self::RunMigration => RUN_MIGRATION_TOOL,
            Self::ConfirmMigration => CONFIRM_MIGRATION_TOOL,
            Self::FederatedSearch => FEDERATED_SEARCH_TOOL,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2SynthesizeRequest {
    pub query: Option<String>,
    pub filter: Option<String>,
    pub limit: Option<usize>,
    pub estate_id: Option<Uuid>,
}

impl V2SynthesizeRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["query", "filter", "limit", "estate_id"])?;
        Ok(Self {
            query: optional_string(object, "query")?.map(str::to_owned),
            filter: optional_string(object, "filter")?.map(str::to_owned),
            limit: positive_limit(optional_integer(object, "limit")?, "limit")?,
            estate_id: optional_uuid(object, "estate_id")?,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2MigrationEntry {
    pub id: String,
    pub content: String,
    pub tags: Vec<String>,
}

impl V2MigrationEntry {
    fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["id", "content", "tags"])?;
        let tags = match object.get("tags") {
            None => Vec::new(),
            Some(JsonValue::Array(values)) => values
                .iter()
                .enumerate()
                .map(|(index, value)| match value {
                    JsonValue::String(value) => Ok(value.clone()),
                    _ => Err(V2InvalidArgument::new(
                        format!("$.entries[{index}].tags"),
                        "must contain only strings",
                    )),
                })
                .collect::<V2DecodeResult<Vec<_>>>()?,
            Some(_) => return Err(V2InvalidArgument::new("$.entries.tags", "must be an array")),
        };
        Ok(Self {
            id: required_string(object, "id")?.to_owned(),
            content: required_string(object, "content")?.to_owned(),
            tags,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2MigrationPlan {
    pub name: String,
    pub room: String,
    pub lattice_code: String,
    pub embedding_model_id: String,
    pub sensitivity: Option<String>,
}

impl V2MigrationPlan {
    fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, [
            "name", "room", "latticeCode", "embeddingModelID", "sensitivity",
        ])?;
        Ok(Self {
            name: required_string(object, "name")?.to_owned(),
            room: required_string(object, "room")?.to_owned(),
            lattice_code: required_string(object, "latticeCode")?.to_owned(),
            embedding_model_id: required_string(object, "embeddingModelID")?.to_owned(),
            sensitivity: optional_string(object, "sensitivity")?.map(str::to_owned),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2RunMigrationRequest {
    pub corpus_name: String,
    pub entries: Vec<V2MigrationEntry>,
    pub plans: Vec<V2MigrationPlan>,
    pub estate_id: Option<Uuid>,
}

impl V2RunMigrationRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["corpusName", "entries", "plans", "estate_id"])?;
        let entries = required_array(object, "entries")?
            .iter().map(V2MigrationEntry::decode).collect::<V2DecodeResult<Vec<_>>>()?;
        let plans = required_array(object, "plans")?
            .iter().map(V2MigrationPlan::decode).collect::<V2DecodeResult<Vec<_>>>()?;
        Ok(Self {
            corpus_name: required_string(object, "corpusName")?.to_owned(),
            entries,
            plans,
            estate_id: optional_uuid(object, "estate_id")?,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ConfirmMigrationRequest {
    pub winner_branch_id: Uuid,
    pub discard_branch_ids: Vec<Uuid>,
    pub estate_id: Option<Uuid>,
}

impl V2ConfirmMigrationRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["winner_branch_id", "discard_branch_ids", "estate_id"])?;
        let discard_branch_ids = match object.get("discard_branch_ids") {
            None => Vec::new(),
            Some(JsonValue::Array(values)) => values.iter().enumerate().map(|(index, value)| {
                let JsonValue::String(value) = value else {
                    return Err(V2InvalidArgument::new(format!("$.discard_branch_ids[{index}]"), "must be a UUID"));
                };
                super::codec::decode_uuid(value, &format!("$.discard_branch_ids[{index}]"))
            }).collect::<V2DecodeResult<Vec<_>>>()?,
            Some(_) => return Err(V2InvalidArgument::new("$.discard_branch_ids", "must be an array of UUIDs")),
        };
        Ok(Self {
            winner_branch_id: required_uuid(object, "winner_branch_id")?,
            discard_branch_ids,
            estate_id: optional_uuid(object, "estate_id")?,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2FederatedSearchRequest {
    pub requester_estate_id: Option<Uuid>,
    pub filter: Option<String>,
    pub limit: Option<usize>,
    pub ordering: Option<String>,
    pub hydration_level: Option<String>,
}

impl V2FederatedSearchRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, [
            "requester_estate_id", "filter", "limit", "ordering", "hydration_level",
        ])?;
        Ok(Self {
            requester_estate_id: optional_uuid(object, "requester_estate_id")?,
            filter: optional_string(object, "filter")?.map(str::to_owned),
            limit: positive_limit(optional_integer(object, "limit")?, "limit")?,
            ordering: optional_string(object, "ordering")?.map(str::to_owned),
            hydration_level: optional_string(object, "hydration_level")?.map(str::to_owned),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct V2CompactMemory {
    pub memory_id: Uuid,
    pub subject: Option<String>,
    pub score: Option<f64>,
    pub provenance: Option<String>,
    pub context: Option<String>,
    pub excerpt: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct V2SynthesisData {
    pub summary: String,
    pub cues: Option<Vec<String>>,
    pub results: Vec<V2CompactMemory>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct V2BenchmarkReport {
    pub branch_id: Uuid,
    pub query_count: u64,
    pub recall_overlap: f64,
    pub recall_precision: f64,
    pub mean_reciprocal_rank: f64,
    pub not_found_in_branch: Vec<String>,
    pub new_in_branch: Vec<String>,
    pub evaluated_at: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct V2MigrationRanking {
    pub branch_id: Uuid,
    pub plan_name: String,
    pub combined_score: f64,
    pub recall_overlap: f64,
    pub mean_reciprocal_rank: f64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct V2DisqualifiedMigration {
    pub branch_id: Uuid,
    pub plan_name: String,
    pub lost_concepts: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct V2MigrationData {
    pub reports: Vec<V2BenchmarkReport>,
    pub winner_branch_id: Option<Uuid>,
    pub winner_plan_name: Option<String>,
    pub rankings: Vec<V2MigrationRanking>,
    pub disqualified: Vec<V2DisqualifiedMigration>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum V2DiscardOutcomeStatus { Discarded, AlreadyDiscarded, WinnerSkipped, Unknown, Failed }

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct V2DiscardOutcome { pub branch_id: Uuid, pub status: V2DiscardOutcomeStatus }

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct V2MigrationConfirmationData {
    pub promoted_branch_id: Uuid,
    pub discarded_branch_ids: Vec<Uuid>,
    pub discard_outcomes: Vec<V2DiscardOutcome>,
}

impl V2MigrationConfirmationData {
    /// Reject a lower receipt that merely repeats requested ids.  Only a
    /// completed discard or a verified already-discarded state may appear in
    /// `discarded_branch_ids`.
    pub fn verify(self) -> Result<Self, V2OrchestrationFailure> {
        let verified: std::collections::BTreeSet<Uuid> = self.discard_outcomes.iter()
            .filter_map(|outcome| matches!(outcome.status, V2DiscardOutcomeStatus::Discarded | V2DiscardOutcomeStatus::AlreadyDiscarded).then_some(outcome.branch_id))
            .collect();
        let declared: std::collections::BTreeSet<Uuid> = self.discarded_branch_ids.iter().copied().collect();
        if declared == verified { Ok(self) } else { Err(V2OrchestrationFailure::UnverifiedCleanup) }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct V2FederatedSearchData {
    pub source_estate_id: Uuid,
    pub requester_estate_id: Uuid,
    pub grant_id: Uuid,
    pub results: Vec<V2CompactMemory>,
}

/// Direct lower-kit interface.  Real selected-surface adapters bind these to
/// `run_grounded_synthesis`, migration live APIs, and `federated_recall`.
pub trait V2OrchestrationProvider: Send + Sync {
    fn synthesize(&self, request: V2SynthesizeRequest, selected_estate_id: Uuid) -> Result<V2SynthesisData, V2OrchestrationFailure>;
    fn run_migration(&self, request: V2RunMigrationRequest, selected_estate_id: Uuid) -> Result<V2MigrationData, V2OrchestrationFailure>;
    fn confirm_migration(&self, request: V2ConfirmMigrationRequest, selected_estate_id: Uuid) -> Result<V2MigrationConfirmationData, V2OrchestrationFailure>;
    fn federated_search(&self, request: V2FederatedSearchRequest, selected_estate_id: Uuid) -> Result<V2FederatedSearchData, V2OrchestrationFailure>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2OrchestrationFailure {
    EstateUnavailable,
    UnverifiedCleanup,
    LowerUnavailable,
    UnknownBranch,
    DisqualifiedBranch,
    TerminalBranch,
    FederatedAccessUnavailable,
    FederatedAggregationRequired,
}

pub struct V2OrchestrationService<P> { selected_estate_id: Uuid, provider: P }

impl<P: V2OrchestrationProvider> V2OrchestrationService<P> {
    pub fn new(selected_estate_id: Uuid, provider: P) -> Self { Self { selected_estate_id, provider } }

    pub fn provider(&self) -> &P { &self.provider }

    pub fn synthesize(&self, request: V2SynthesizeRequest) -> Result<V2SynthesisData, V2OrchestrationFailure> {
        self.validate(request.estate_id)?;
        self.provider.synthesize(request, self.selected_estate_id)
    }

    /// Candidate evaluation has no promotion side effect. Confirmation remains
    /// an explicit later call to `confirm_migration`.
    pub fn run_migration(&self, request: V2RunMigrationRequest) -> Result<V2MigrationData, V2OrchestrationFailure> {
        self.validate(request.estate_id)?;
        self.provider.run_migration(request, self.selected_estate_id)
    }

    pub fn confirm_migration(&self, request: V2ConfirmMigrationRequest) -> Result<V2MigrationConfirmationData, V2OrchestrationFailure> {
        self.validate(request.estate_id)?;
        self.provider.confirm_migration(request, self.selected_estate_id)?.verify()
    }

    pub fn federated_search(&self, request: V2FederatedSearchRequest) -> Result<V2FederatedSearchData, V2OrchestrationFailure> {
        if request.requester_estate_id.is_some_and(|id| id != self.selected_estate_id) { return Err(V2OrchestrationFailure::EstateUnavailable); }
        self.provider.federated_search(request, self.selected_estate_id)
    }

    fn validate(&self, requested: Option<Uuid>) -> Result<(), V2OrchestrationFailure> {
        if requested.is_some_and(|id| id != self.selected_estate_id) { Err(V2OrchestrationFailure::EstateUnavailable) } else { Ok(()) }
    }
}

fn positive_limit(value: Option<i64>, key: &str) -> V2DecodeResult<Option<usize>> {
    match value {
        None => Ok(None),
        Some(value) if value > 0 => usize::try_from(value).map(Some).map_err(|_| V2InvalidArgument::new(format!("$.{key}"), "is too large")),
        Some(_) => Err(V2InvalidArgument::new(format!("$.{key}"), "must be an integer of at least 1")),
    }
}

fn required_array<'a>(object: &'a std::collections::BTreeMap<String, JsonValue>, key: &str) -> V2DecodeResult<&'a Vec<JsonValue>> {
    match object.get(key) {
        Some(JsonValue::Array(values)) => Ok(values),
        Some(_) => Err(V2InvalidArgument::new(format!("$.{key}"), "must be an array")),
        None => Err(V2InvalidArgument::new(format!("$.{key}"), "is required")),
    }
}
