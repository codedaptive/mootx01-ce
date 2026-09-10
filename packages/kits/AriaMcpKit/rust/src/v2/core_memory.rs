//! Typed ARIA v2 core-memory operations.
//!
//! This is deliberately a narrow typed boundary.  It decodes the three v2
//! core-memory requests once, admits them against injected request context,
//! and calls an injected GeniusLocus/EstateCoordinator service.  It never
//! invokes `interface_tools`, `dispatch`, or a text/JSON legacy runner.

use std::collections::BTreeSet;

use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

use crate::{
    jsonrpc::{JSONRPCError, JsonValue},
    sensitivity_grant_ledger::SensitivityGrantLedger,
    surfaced_recall_ledger::SurfacedRecallLedger,
};

use super::{
    codec::{canonical_uuid, optional_bool, optional_integer, optional_string, optional_uuid, required_string, strict_object, V2DecodeResult, V2InvalidArgument},
    render::{refusal, success, V2OperationalRefusal, V2ResultMeta},
};

pub const FILE_MEMORY_TOOL: &str = "moot_file_memory";
pub const MEMORY_SEARCH_TOOL: &str = "moot_memory_search";
pub const MEMORY_GET_TOOL: &str = "moot_memory_get";
pub const DEFAULT_SEARCH_LIMIT: usize = 20;
pub const MAX_SEARCH_LIMIT: usize = 500;
pub const MAX_GET_IDS: usize = 50;
pub const SUBJECT_LENGTH_CONTRACT: usize = 120;

/// Request time is injected.  The operation must not substitute wall time for
/// an estate/authorization/ledger decision made during the same request.
pub trait V2MemoryClock: Send + Sync {
    fn now_millis(&self) -> i64;
}

/// The selected surface supplies caller and estate admission.  Keeping this
/// seam explicit prevents a v2 operation from inventing authorization from a
/// default estate or from silently dropping a denied row.
pub trait V2MemoryAuthorization: Send + Sync {
    fn authorize(&self, operation: V2CoreMemoryOperation, context: &V2MemoryOperationContext)
        -> Result<(), V2MemoryFailure>;
}

/// The only execution seam available to this module.  Its production adapter
/// calls typed `EstateCoordinator`/GeniusLocus methods; the adapter belongs to
/// selected-surface wiring because an `EstateCoordinator` cannot be created
/// from an MCP request and owns host registrations.  No method accepts or
/// returns an untyped runner payload.
pub trait V2CoreMemoryService: Send + Sync {
    fn file_memory(
        &self,
        context: &V2MemoryOperationContext,
        request: &V2FileMemoryRequest,
    ) -> Result<V2FiledMemory, V2MemoryFailure>;

    fn search_memories(
        &self,
        context: &V2MemoryOperationContext,
        request: &V2MemorySearchRequest,
    ) -> Result<Vec<V2CompactMemory>, V2MemoryFailure>;

    /// This service is responsible for applying the same authorization and
    /// provenance/redaction gate to an absent and an inaccessible id.  The
    /// caller receives only authorized rows, so no existence oracle escapes
    /// through this v2 projection.
    fn get_memories(
        &self,
        context: &V2MemoryOperationContext,
        request: &V2MemoryGetRequest,
    ) -> Result<Vec<V2Memory>, V2MemoryFailure>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2CoreMemoryOperation {
    File,
    Search,
    Get,
}

/// Typed context carried unchanged across decode, admission, service, and
/// result projection.  `estate_id` remains optional until selected-surface
/// wiring resolves the caller's default estate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2MemoryOperationContext {
    pub estate_id: Option<Uuid>,
    pub caller_identity: String,
    pub now_millis: i64,
    pub sensitivity_ceiling: Option<V2Sensitivity>,
}

pub struct V2CoreMemoryDependencies<'a> {
    pub service: &'a dyn V2CoreMemoryService,
    pub authorization: &'a dyn V2MemoryAuthorization,
    pub clock: &'a dyn V2MemoryClock,
    pub sensitivity_ledger: &'a SensitivityGrantLedger,
    pub surfaced_recall_ledger: &'a SurfacedRecallLedger,
    pub caller_identity: &'a str,
    pub meta: V2ResultMeta,
}

#[derive(Debug, Clone, PartialEq)]
pub struct V2MemoryFailure {
    pub code: String,
    pub message: String,
    pub retryable: bool,
    pub recovery: Option<Value>,
}

impl V2MemoryFailure {
    pub fn not_found() -> Self {
        Self {
            code: "memory_not_found".to_owned(),
            // Deliberately does not name an id: hidden and absent rows have
            // exactly this public shape.
            message: "memory not found".to_owned(),
            retryable: false,
            recovery: None,
        }
    }

    fn render(&self, tool: &str, meta: &V2ResultMeta) -> Value {
        refusal(tool, &V2OperationalRefusal {
            code: self.code.clone(),
            message: self.message.clone(),
            retryable: self.retryable,
            recovery: self.recovery.clone(),
        }, meta)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2Sensitivity { Normal, Elevated, Restricted, Secret }

impl V2Sensitivity {
    fn rank(self) -> u8 { match self { Self::Normal => 0, Self::Elevated => 1, Self::Restricted => 2, Self::Secret => 3 } }

    fn parse(value: &str, path: &str) -> V2DecodeResult<Self> {
        match value {
            "normal" => Ok(Self::Normal),
            "elevated" => Ok(Self::Elevated),
            "restricted" => Ok(Self::Restricted),
            "secret" => Ok(Self::Secret),
            _ => Err(V2InvalidArgument::new(path, "must be a supported sensitivity")
                .allowed(["normal", "elevated", "restricted", "secret"].into_iter().map(str::to_owned))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2Exportability { Private, Public }

impl V2Exportability {
    fn parse(value: &str, path: &str) -> V2DecodeResult<Self> {
        match value {
            "private" => Ok(Self::Private),
            "public" => Ok(Self::Public),
            _ => Err(V2InvalidArgument::new(path, "must be private or public")
                .allowed(["private", "public"].into_iter().map(str::to_owned))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2ContentKind { Prose, Code, Transcript, List, StructuredJson, ImageCaption, FingerprintOnly }

impl V2ContentKind {
    fn parse(value: &str, path: &str) -> V2DecodeResult<Self> {
        match value {
            "prose" => Ok(Self::Prose), "code" => Ok(Self::Code), "transcript" => Ok(Self::Transcript),
            "list" => Ok(Self::List), "structured_json" => Ok(Self::StructuredJson),
            "image_caption" => Ok(Self::ImageCaption), "fingerprint_only" => Ok(Self::FingerprintOnly),
            _ => Err(V2InvalidArgument::new(path, "must be a supported content kind").allowed(
                ["prose", "code", "transcript", "list", "structured_json", "image_caption", "fingerprint_only"]
                    .into_iter().map(str::to_owned))),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2FileMemoryRequest {
    pub estate_id: Option<Uuid>,
    pub content: String,
    pub subject: String,
    pub location: String,
    pub wing: Option<String>,
    pub sensitivity: Option<V2Sensitivity>,
    pub exportability: Option<V2Exportability>,
    pub kind: Option<V2ContentKind>,
    /// The concrete estate adapter performs the existing strict RFC-3339
    /// conversion before `CaptureFrame` construction; this boundary keeps the
    /// value typed as an optional event-time field rather than re-parsing it.
    pub event_time: Option<String>,
    pub impatient: bool,
}

impl V2FileMemoryRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["content", "subject", "location", "wing", "sensitivity", "exportability", "kind", "event_time", "impatient", "estate_id"])?;
        let content = nonempty(required_string(object, "content")?, "$.content")?.to_owned();
        let subject = nonempty(required_string(object, "subject")?.trim(), "$.subject")?.to_owned();
        if subject.chars().count() > SUBJECT_LENGTH_CONTRACT {
            return Err(V2InvalidArgument::new("$.subject", "exceeds the subject length contract")
                .correction("provide at most 120 Unicode scalar values"));
        }
        let location = nonempty(required_string(object, "location")?, "$.location")?.to_owned();
        let sensitivity = optional_string(object, "sensitivity")?
            .map(|value| V2Sensitivity::parse(value, "$.sensitivity")).transpose()?;
        let exportability = optional_string(object, "exportability")?
            .map(|value| V2Exportability::parse(value, "$.exportability")).transpose()?;
        let impatient = match object.get("impatient") {
            None => false,
            Some(JsonValue::Bool(value)) => *value,
            Some(_) => return Err(V2InvalidArgument::new("$.impatient", "must be a boolean")),
        };
        Ok(Self {
            estate_id: optional_uuid(object, "estate_id")?, content, subject, location,
            wing: optional_string(object, "wing")?.map(str::to_owned), sensitivity, exportability,
            kind: optional_string(object, "kind")?.map(|value| V2ContentKind::parse(value, "$.kind")).transpose()?,
            event_time: optional_string(object, "event_time")?.map(str::to_owned), impatient,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2SearchTarget { Query(String), Near(Uuid) }

/// Validated filter values for `moot_memory_search`. Unknown spellings are
/// rejected at decode with `V2InvalidArgument`, producing a -32602 INVALID_PARAMS
/// error rather than a success-shaped refusal envelope. Mirrors Swift decodeFilterChain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2SearchFilter { Unconfirmed, UserConfirmed, Exportable, Contained, Pinned }

/// Validated media_type values for `moot_memory_search`. Only "voice" and "image"
/// are accepted. Unknown spellings are rejected at decode with -32602.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2SearchMediaType { Voice, Image }

/// Validated door values for `moot_memory_search`. "guess" is a legal spelling at
/// decode; the service resolves it against the provisioned DoorManifest because that
/// requires the estate handle. "hedge" and "thorough" are reserved at the recipe
/// layer and unknown here; they are rejected at decode with -32602.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2SearchDoor { Guess, Raw, Rrf, MatrixAware, Discriminative }

/// Validated scoring values for `moot_memory_search`. Applied when door is absent.
/// Unknown spellings are rejected at decode with -32602.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2SearchScoring { Raw, Rrf, MatrixAware, Discriminative }

/// Validated ordering values for `moot_memory_search`. "byRelevanceDesc" is accepted
/// as a distinct input spelling; the service maps it to ByCaptureTimeDesc because the
/// scored unionBest path already owns final relevance ordering. Unknown spellings are
/// rejected at decode with -32602.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2SearchOrdering { ByCaptureTimeDesc, ByCaptureTimeAsc, ByRoomAsc, ByRelevanceDesc }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2MemorySearchRequest {
    pub estate_id: Option<Uuid>,
    pub target: V2SearchTarget,
    pub limit: usize,
    /// Validated at decode; unknown values return -32602 INVALID_PARAMS.
    pub filter: Option<V2SearchFilter>,
    /// Every string including empty is valid; no validation at decode.
    pub wing: Option<String>,
    /// Validated at decode; only "voice" and "image" are accepted.
    pub media_type: Option<V2SearchMediaType>,
    pub explain: Option<bool>,
    /// Validated at decode; "guess" resolves to provisioned config in the service.
    pub door: Option<V2SearchDoor>,
    /// Validated at decode; applied when door is absent.
    pub scoring: Option<V2SearchScoring>,
    /// Validated at decode; "byRelevanceDesc" maps to ByCaptureTimeDesc in the service.
    pub ordering: Option<V2SearchOrdering>,
    pub frontier_k: Option<i64>,
    pub answer: Option<String>,
}

impl V2MemorySearchRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["query", "near", "limit", "filter", "wing", "media_type", "explain", "door", "scoring", "ordering", "frontier_k", "answer", "estate_id"])?;
        let target = match (optional_string(object, "query")?, optional_uuid(object, "near")?) {
            (Some(_), Some(_)) => return Err(V2InvalidArgument::new("$", "query and near are mutually exclusive")
                .correction("provide exactly one of query or near")),
            (None, None) => return Err(V2InvalidArgument::new("$", "requires query or near")
                .correction("provide a text query or an anchor memory UUID")),
            (Some(query), None) => V2SearchTarget::Query(nonempty(query, "$.query")?.to_owned()),
            (None, Some(near)) => V2SearchTarget::Near(near),
        };
        let limit = optional_integer(object, "limit")?.unwrap_or(DEFAULT_SEARCH_LIMIT as i64);
        if !(1..=MAX_SEARCH_LIMIT as i64).contains(&limit) {
            return Err(V2InvalidArgument::new("$.limit", "must be from 1 through 500"));
        }
        // Five validated fields: unknown values produce -32602 INVALID_PARAMS, matching
        // Swift which throws JSONRPCError(code: .invalidParams) for the same inputs.
        // The exact message text is preserved so callers see identical errors across ports.
        let filter = match optional_string(object, "filter")? {
            None                  => None,
            Some("unconfirmed")   => Some(V2SearchFilter::Unconfirmed),
            Some("userConfirmed") => Some(V2SearchFilter::UserConfirmed),
            Some("exportable")    => Some(V2SearchFilter::Exportable),
            Some("contained")     => Some(V2SearchFilter::Contained),
            Some("pinned")        => Some(V2SearchFilter::Pinned),
            Some(unknown) => return Err(V2InvalidArgument::new("$.filter",
                format!("Unknown filter: {unknown}"))),
        };
        let media_type = match optional_string(object, "media_type")? {
            None          => None,
            Some("voice") => Some(V2SearchMediaType::Voice),
            Some("image") => Some(V2SearchMediaType::Image),
            Some(unknown) => return Err(V2InvalidArgument::new("$.media_type",
                format!("Unknown media_type: {unknown}. Valid: voice, image"))),
        };
        // "guess" is valid at decode; the service resolves it against the provisioned
        // DoorManifest because that requires the estate handle.
        let door = match optional_string(object, "door")? {
            None                   => None,
            Some("guess")          => Some(V2SearchDoor::Guess),
            Some("raw")            => Some(V2SearchDoor::Raw),
            Some("rrf")            => Some(V2SearchDoor::Rrf),
            Some("matrixAware")    => Some(V2SearchDoor::MatrixAware),
            Some("discriminative") => Some(V2SearchDoor::Discriminative),
            Some(unknown) => return Err(V2InvalidArgument::new("$.door",
                format!("Unknown door: {unknown}. Valid: guess, raw, rrf, matrixAware, discriminative"))),
        };
        let scoring = match optional_string(object, "scoring")? {
            None                   => None,
            Some("raw")            => Some(V2SearchScoring::Raw),
            Some("rrf")            => Some(V2SearchScoring::Rrf),
            Some("matrixAware")    => Some(V2SearchScoring::MatrixAware),
            Some("discriminative") => Some(V2SearchScoring::Discriminative),
            Some(unknown) => return Err(V2InvalidArgument::new("$.scoring",
                format!("Unknown scoring: {unknown}. Valid: raw, rrf, matrixAware, discriminative"))),
        };
        // "byRelevanceDesc" is a compatibility spelling that decodes to its own
        // variant; the service maps it to ByCaptureTimeDesc as a tie-break.
        let ordering = match optional_string(object, "ordering")? {
            None                      => None,
            Some("byCaptureTimeDesc") => Some(V2SearchOrdering::ByCaptureTimeDesc),
            Some("byCaptureTimeAsc")  => Some(V2SearchOrdering::ByCaptureTimeAsc),
            Some("byRoomAsc")         => Some(V2SearchOrdering::ByRoomAsc),
            Some("byRelevanceDesc")   => Some(V2SearchOrdering::ByRelevanceDesc),
            Some(unknown) => return Err(V2InvalidArgument::new("$.ordering",
                format!("Unknown ordering: {unknown}. Valid: byCaptureTimeDesc, byCaptureTimeAsc, byRoomAsc, byRelevanceDesc"))),
        };
        Ok(Self {
            estate_id: optional_uuid(object, "estate_id")?, target, limit: limit as usize,
            filter, wing: optional_string(object, "wing")?.map(str::to_owned),
            media_type, explain: optional_bool(object, "explain")?,
            door, scoring, ordering,
            frontier_k: optional_integer(object, "frontier_k")?,
            answer: optional_string(object, "answer")?.map(str::to_owned),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum V2MemoryDepth { Subject, Distilled, Full }

impl V2MemoryDepth {
    fn decode(value: Option<&str>) -> V2DecodeResult<Self> {
        match value.unwrap_or("full") {
            "subject" => Ok(Self::Subject),
            "distilled" => Ok(Self::Distilled),
            "full" => Ok(Self::Full),
            _ => Err(V2InvalidArgument::new("$.depth", "must be subject, distilled, or full")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2MemoryGetRequest {
    pub estate_id: Option<Uuid>,
    pub memory_ids: Vec<Uuid>,
    pub depth: V2MemoryDepth,
}

impl V2MemoryGetRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["memory_id", "memory_ids", "depth", "estate_id"])?;
        let single = optional_uuid(object, "memory_id")?;
        let multiple = match object.get("memory_ids") {
            None => Vec::new(),
            Some(JsonValue::Array(values)) => values.iter().enumerate().map(|(index, value)| {
                let raw = value.as_str().ok_or_else(|| V2InvalidArgument::new(format!("$.memory_ids[{index}]"), "must be a UUID string"))?;
                super::codec::decode_uuid(raw, &format!("$.memory_ids[{index}]"))
            }).collect::<V2DecodeResult<Vec<_>>>()?,
            Some(_) => return Err(V2InvalidArgument::new("$.memory_ids", "must be an array of UUID strings")),
        };
        if single.is_some() && !multiple.is_empty() {
            return Err(V2InvalidArgument::new("$", "memory_id and memory_ids are mutually exclusive")
                .correction("provide a single memory_id or a memory_ids batch"));
        }
        let memory_ids = single.into_iter().chain(multiple).collect::<Vec<_>>();
        if memory_ids.is_empty() { return Err(V2InvalidArgument::new("$", "requires memory_id or memory_ids")); }
        if memory_ids.len() > MAX_GET_IDS { return Err(V2InvalidArgument::new("$.memory_ids", "batch exceeds 50 memory IDs")); }
        if memory_ids.iter().collect::<BTreeSet<_>>().len() != memory_ids.len() {
            return Err(V2InvalidArgument::new("$.memory_ids", "must not contain duplicate UUIDs"));
        }
        Ok(Self { estate_id: optional_uuid(object, "estate_id")?, memory_ids, depth: V2MemoryDepth::decode(optional_string(object, "depth")?)? })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct V2FetchReference { pub tool: &'static str, pub arguments: V2FetchArguments }
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct V2FetchArguments { pub memory_id: String }
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct V2Placement { pub wing: String, pub room: String }

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct V2CompactMemory {
    #[serde(serialize_with = "serialize_uuid")]
    pub memory_id: Uuid,
    #[serde(skip_serializing_if = "Option::is_none")] pub subject: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub score: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")] pub provenance: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub context: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub excerpt: Option<String>,
    pub fetch: V2FetchReference,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct V2Memory {
    #[serde(serialize_with = "serialize_uuid")]
    pub memory_id: Uuid,
    #[serde(skip_serializing_if = "Option::is_none")] pub subject: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub distilled: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub placement: Option<V2Placement>,
    #[serde(skip_serializing_if = "Option::is_none")] pub filed_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub event_time: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub trust: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub sensitivity: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub exportability: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub confirmation: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")] pub lineage_id: Option<String>,
    pub fetch: V2FetchReference,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2FiledMemory { pub memory_id: Uuid, pub placement: V2Placement }

#[derive(Serialize)] struct FileData { memory_id: String, placement: V2Placement, fetch: V2FetchReference }
#[derive(Serialize)] struct SearchData { results: Vec<V2CompactMemory> }
#[derive(Serialize)] struct GetData { memories: Vec<V2Memory> }

pub fn run_file_memory(arguments: &JsonValue, dependencies: &V2CoreMemoryDependencies<'_>) -> Result<Value, JSONRPCError> {
    let request = V2FileMemoryRequest::decode(arguments).map_err(V2InvalidArgument::into_jsonrpc_error)?;
    execute_file_memory(request, dependencies)
}

pub fn execute_file_memory(request: V2FileMemoryRequest, dependencies: &V2CoreMemoryDependencies<'_>) -> Result<Value, JSONRPCError> {
    let meta = meta_for(&dependencies.meta, super::operation::V2OperationEffect::Write);
    let context = context_for(request.estate_id, dependencies);
    if let (Some(requested), Some(ceiling)) = (request.sensitivity, context.sensitivity_ceiling) {
        if requested.rank() < ceiling.rank() {
            return Ok(V2MemoryFailure { code: "operation_failed".to_owned(), message: "requested sensitivity is below the live grant ceiling".to_owned(), retryable: false, recovery: None }.render(FILE_MEMORY_TOOL, &meta));
        }
    }
    if let Err(failure) = dependencies.authorization.authorize(V2CoreMemoryOperation::File, &context) {
        return Ok(failure.render(FILE_MEMORY_TOOL, &meta));
    }
    match dependencies.service.file_memory(&context, &request) {
        Ok(filed) => success(FILE_MEMORY_TOOL, &FileData { memory_id: canonical_uuid(filed.memory_id), placement: filed.placement, fetch: fetch(filed.memory_id) }, &meta, "filed memory").map_err(jsonrpc_internal),
        Err(failure) => Ok(failure.render(FILE_MEMORY_TOOL, &meta)),
    }
}

pub fn run_memory_search(arguments: &JsonValue, dependencies: &V2CoreMemoryDependencies<'_>) -> Result<Value, JSONRPCError> {
    let request = V2MemorySearchRequest::decode(arguments).map_err(V2InvalidArgument::into_jsonrpc_error)?;
    execute_memory_search(request, dependencies)
}

pub fn execute_memory_search(request: V2MemorySearchRequest, dependencies: &V2CoreMemoryDependencies<'_>) -> Result<Value, JSONRPCError> {
    let meta = meta_for(&dependencies.meta, super::operation::V2OperationEffect::Read);
    let context = context_for(request.estate_id, dependencies);
    if let Err(failure) = dependencies.authorization.authorize(V2CoreMemoryOperation::Search, &context) {
        return Ok(failure.render(MEMORY_SEARCH_TOOL, &meta));
    }
    match dependencies.service.search_memories(&context, &request) {
        Ok(mut results) => {
            results.truncate(request.limit);
            for row in &mut results {
                row.fetch = fetch(row.memory_id);
                if let Some(context) = &row.context {
                    row.context = Some(context.chars().take(512).collect());
                }
                if let Some(excerpt) = &row.excerpt {
                    row.excerpt = Some(excerpt.chars().take(512).collect());
                }
            }
            dependencies.surfaced_recall_ledger.record_surfaced(&results.iter().map(|row| canonical_uuid(row.memory_id)).collect::<Vec<_>>(), context.now_millis / 1_000);
            success(MEMORY_SEARCH_TOOL, &SearchData { results }, &meta, "memory search").map_err(jsonrpc_internal)
        }
        Err(failure) => Ok(failure.render(MEMORY_SEARCH_TOOL, &meta)),
    }
}

pub fn run_memory_get(arguments: &JsonValue, dependencies: &V2CoreMemoryDependencies<'_>) -> Result<Value, JSONRPCError> {
    let request = V2MemoryGetRequest::decode(arguments).map_err(V2InvalidArgument::into_jsonrpc_error)?;
    execute_memory_get(request, dependencies)
}

pub fn execute_memory_get(request: V2MemoryGetRequest, dependencies: &V2CoreMemoryDependencies<'_>) -> Result<Value, JSONRPCError> {
    let meta = meta_for(&dependencies.meta, super::operation::V2OperationEffect::Read);
    let context = context_for(request.estate_id, dependencies);
    if let Err(failure) = dependencies.authorization.authorize(V2CoreMemoryOperation::Get, &context) {
        return Ok(failure.render(MEMORY_GET_TOOL, &meta));
    }
    match dependencies.service.get_memories(&context, &request) {
        Ok(memories) if memories.is_empty() => Ok(V2MemoryFailure::not_found().render(MEMORY_GET_TOOL, &meta)),
        Ok(mut memories) => {
            for memory in &mut memories { memory.fetch = fetch(memory.memory_id); project_depth(memory, request.depth); }
            success(MEMORY_GET_TOOL, &GetData { memories }, &meta, "memory get").map_err(jsonrpc_internal)
        }
        Err(failure) => Ok(failure.render(MEMORY_GET_TOOL, &meta)),
    }
}

fn context_for(estate_id: Option<Uuid>, dependencies: &V2CoreMemoryDependencies<'_>) -> V2MemoryOperationContext {
    let now_millis = dependencies.clock.now_millis();
    V2MemoryOperationContext { estate_id, caller_identity: dependencies.caller_identity.to_owned(), now_millis, sensitivity_ceiling: dependencies.sensitivity_ledger.ceiling_sensitivity(now_millis).map(|value| match value { locus_kit::adjectives::AdjectiveSensitivity::Normal => V2Sensitivity::Normal, locus_kit::adjectives::AdjectiveSensitivity::Elevated => V2Sensitivity::Elevated, locus_kit::adjectives::AdjectiveSensitivity::Restricted => V2Sensitivity::Restricted, locus_kit::adjectives::AdjectiveSensitivity::Secret => V2Sensitivity::Secret }) }
}

fn fetch(id: Uuid) -> V2FetchReference { fetch_id(&canonical_uuid(id)) }
fn fetch_id(id: &str) -> V2FetchReference { V2FetchReference { tool: MEMORY_GET_TOOL, arguments: V2FetchArguments { memory_id: id.to_owned() } } }
fn nonempty<'a>(value: &'a str, path: &str) -> V2DecodeResult<&'a str> { if value.is_empty() { Err(V2InvalidArgument::new(path, "must not be empty")) } else { Ok(value) } }
fn project_depth(memory: &mut V2Memory, depth: V2MemoryDepth) { match depth { V2MemoryDepth::Subject => { memory.distilled = None; memory.content = None; }, V2MemoryDepth::Distilled => memory.content = None, V2MemoryDepth::Full => {} } }
fn serialize_uuid<S>(value: &Uuid, serializer: S) -> Result<S::Ok, S::Error> where S: serde::Serializer { serializer.serialize_str(&canonical_uuid(*value)) }
fn jsonrpc_internal(error: serde_json::Error) -> JSONRPCError { JSONRPCError::new(crate::jsonrpc::JSONRPCErrorCode::INTERNAL_ERROR, error.to_string()) }
fn meta_for(base: &V2ResultMeta, effect: super::operation::V2OperationEffect) -> V2ResultMeta { V2ResultMeta { build_id: base.build_id.clone(), capability_digest: base.capability_digest.clone(), effect, completeness: base.completeness.clone() } }
