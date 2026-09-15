//! Typed v2 similar recall boundary: the paraphrase door.  It calls
//! CognitionKit's similar-recall recipe directly and never passes through a
//! tool runner or reparses a rendered result.  Twin of Swift
//! `AriaV2SimilarRecall.swift`.

use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

use crate::{estate_registry::{EstateRegistry, OpenEstate}, jsonrpc::{JSONRPCError, JsonValue}};

use super::{
    codec::{canonical_uuid, optional_integer, optional_uuid, required_string, strict_object, V2DecodeResult, V2InvalidArgument},
    core_memory::{V2FetchArguments, V2FetchReference, MEMORY_GET_TOOL},
    operation::V2OperationEffect,
    render::{compact_text, refusal, success, V2OperationalRefusal, V2ResultMeta},
};

pub const SIMILAR_RECALL_TOOL: &str = "moot_recall_similar";

/// Smallest and largest accepted `limit`; the default applies when the caller
/// omits it.  Mirrored in the catalog schema and the Swift twin.
pub const SIMILAR_RECALL_MIN_LIMIT: i64 = 1;
pub const SIMILAR_RECALL_MAX_LIMIT: i64 = 50;
pub const SIMILAR_RECALL_DEFAULT_LIMIT: i64 = 10;

/// Decoded `moot_recall_similar` arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2SimilarRecallRequest {
    pub query: String,
    pub limit: usize,
    pub estate_id: Option<Uuid>,
}

impl V2SimilarRecallRequest {
    /// Strict decode: `query` required and non-blank, `limit` within
    /// `1..=50` (default 10), `estate_id` an optional UUID, nothing else.
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["query", "limit", "estate_id"])?;
        let query = required_string(object, "query")?;
        if query.trim().is_empty() {
            return Err(V2InvalidArgument::new("$.query", "must not be empty"));
        }
        let limit = optional_integer(object, "limit")?.unwrap_or(SIMILAR_RECALL_DEFAULT_LIMIT);
        if !(SIMILAR_RECALL_MIN_LIMIT..=SIMILAR_RECALL_MAX_LIMIT).contains(&limit) {
            return Err(V2InvalidArgument::new(
                "$.limit",
                format!("must be between {SIMILAR_RECALL_MIN_LIMIT} and {SIMILAR_RECALL_MAX_LIMIT}"),
            ));
        }
        Ok(Self {
            query: query.to_owned(),
            limit: limit as usize,
            estate_id: optional_uuid(object, "estate_id")?,
        })
    }
}

#[derive(Serialize)]
struct SimilarMatch {
    memory_id: String,
    room: String,
    excerpt: String,
    score: f64,
    fetch: V2FetchReference,
}

#[derive(Serialize)]
struct SimilarData {
    matches: Vec<SimilarMatch>,
}

/// Run the typed recipe after selected-surface admission.  The recipe owns
/// lane selection and ordering; this boundary owns estate selection and the
/// public projection only.
pub fn execute(
    request: V2SimilarRecallRequest,
    registry: &EstateRegistry,
    meta: &V2ResultMeta,
    now_millis: i64,
    maximum_sensitivity: locus_kit::adjectives::AdjectiveSensitivity,
) -> Result<Value, JSONRPCError> {
    let meta = V2ResultMeta::incomplete(
        meta.build_id.clone(), meta.capability_digest.clone(), V2OperationEffect::Read,
    );
    let estate = match estate_for(registry, request.estate_id) {
        Ok(estate) => estate,
        Err(refusal_value) => return Ok(refusal(SIMILAR_RECALL_TOOL, &refusal_value, &meta)),
    };
    let coordinator = match estate.coord.lock() {
        Ok(coordinator) => coordinator,
        Err(_) => return Ok(unavailable("estate_unavailable", "The estate coordinator is unavailable.", &meta)),
    };
    // Match Swift's explicit caller ceiling; the recipe and the withheld
    // count companion share this exact filter.
    let filter = locus_kit::filter::Filter::SensitivityAtMost(maximum_sensitivity);
    let output = match cognition_kit::run_similar_recall(
        &coordinator,
        &estate.handle,
        &request.query,
        request.limit,
        filter.clone(),
        now_millis,
        &HashMap::new(),
    ) {
        Ok(output) => output,
        Err(_) => {
            return Ok(unavailable(
                "lane_unavailable",
                "The whole-record similarity lane is unavailable for this request.",
                &meta,
            ));
        }
    };

    let mut frame = locus_kit::filter::RecallFrame::new(vec![filter]);
    frame.hydration_level = locus_kit::filter::HydrationLevel::Full;
    frame.limit = Some(50);
    frame.ordering = locus_kit::filter::Ordering::ByCaptureTimeDesc;
    if super::report_withheld::recall(&coordinator, &estate.handle, frame, now_millis).is_err() {
        return Ok(unavailable("estate_unavailable", "The estate recall is unavailable.", &meta));
    }

    project_success(output.matches, &meta)
}

/// Project a completed typed recipe outcome.  The public response only
/// includes references constructed from drawer UUIDs returned by the recipe.
pub fn project_success(
    rows: Vec<cognition_kit::PreciseMatch>,
    meta: &V2ResultMeta,
) -> Result<Value, JSONRPCError> {
    let mut matches = Vec::with_capacity(rows.len());
    for row in rows {
        let memory_id = Uuid::parse_str(&row.id).map_err(|_| {
            JSONRPCError::new(
                crate::jsonrpc::JSONRPCErrorCode::INTERNAL_ERROR,
                "Similar recall returned a non-UUID drawer identifier.",
            )
        })?;
        matches.push(SimilarMatch {
            memory_id: canonical_uuid(memory_id),
            room: row.room,
            excerpt: compact_text(&row.content),
            score: row.score,
            fetch: fetch(memory_id),
        });
    }
    success(
        SIMILAR_RECALL_TOOL,
        &SimilarData { matches },
        meta,
        "similar recall completed",
    )
    .map_err(|error| {
        JSONRPCError::new(
            crate::jsonrpc::JSONRPCErrorCode::INTERNAL_ERROR,
            error.to_string(),
        )
    })
}

fn estate_for<'a>(registry: &'a EstateRegistry, requested: Option<Uuid>) -> Result<&'a OpenEstate, V2OperationalRefusal> {
    match requested {
        None => Ok(&registry.default),
        Some(id) if id == registry.default.estate_id => Ok(&registry.default),
        Some(_) => Err(V2OperationalRefusal {
            code: "estate_unavailable".to_owned(),
            message: "The requested estate is not available to this caller.".to_owned(),
            retryable: false,
            recovery: None,
        }),
    }
}

fn unavailable(code: &str, message: &str, meta: &V2ResultMeta) -> Value {
    refusal(SIMILAR_RECALL_TOOL, &V2OperationalRefusal {
        code: code.to_owned(), message: message.to_owned(), retryable: true, recovery: None,
    }, meta)
}

fn fetch(memory_id: Uuid) -> V2FetchReference {
    V2FetchReference {
        tool: MEMORY_GET_TOOL,
        arguments: V2FetchArguments { memory_id: canonical_uuid(memory_id) },
    }
}
