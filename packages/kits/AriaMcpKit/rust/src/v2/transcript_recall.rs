//! Typed v2 transcript recall boundary.  It calls CognitionKit's specialised
//! recipe directly and never passes through a v1 tool runner or reparses a
//! rendered result.

use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;
use uuid::Uuid;

use crate::{estate_registry::{EstateRegistry, OpenEstate}, jsonrpc::{JSONRPCError, JsonValue}};

use super::{
    codec::{canonical_uuid, optional_uuid, required_string, strict_object, V2DecodeResult, V2InvalidArgument},
    core_memory::{V2FetchArguments, V2FetchReference, MEMORY_GET_TOOL},
    operation::V2OperationEffect,
    render::{compact_text, refusal, success, V2OperationalRefusal, V2ResultMeta},
};

pub const TRANSCRIPT_RECALL_TOOL: &str = "moot_memory_recall_transcript";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2TranscriptRecallRequest {
    pub query: String,
    pub estate_id: Option<Uuid>,
}

impl V2TranscriptRecallRequest {
    pub fn decode(value: &JsonValue) -> V2DecodeResult<Self> {
        let object = strict_object(value, ["query", "estate_id"])?;
        let query = required_string(object, "query")?;
        if query.trim().is_empty() {
            return Err(V2InvalidArgument::new("$.query", "must not be empty"));
        }
        Ok(Self { query: query.to_owned(), estate_id: optional_uuid(object, "estate_id")? })
    }
}

#[derive(Serialize)]
struct TranscriptMatch {
    memory_id: String,
    room: String,
    excerpt: String,
    score: f64,
    fetch: V2FetchReference,
}

#[derive(Serialize)]
struct StrictEvidence {
    status: &'static str,
    policy_version: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    encoder_model_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    encoder_model_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    query_dimension: Option<usize>,
    fresh_head_candidates: usize,
    scored_head_candidates: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    classifier_profile: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    classifier_model_revision: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pool: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    head: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    spans: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rrf_k: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    serving_generation: Option<i64>,
    freshness_verified: bool,
}

#[derive(Serialize)]
struct TranscriptData {
    matches: Vec<TranscriptMatch>,
    strict_rerank: StrictEvidence,
}

/// Run the typed recipe after selected-surface admission.  The recipe owns the
/// fixed lower-stage construction; this boundary owns estate selection and the
/// public projection only.
pub fn execute(
    request: V2TranscriptRecallRequest,
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
        Err(refusal_value) => return Ok(refusal(TRANSCRIPT_RECALL_TOOL, &refusal_value, &meta)),
    };
    let coordinator = match estate.coord.lock() {
        Ok(coordinator) => coordinator,
        Err(_) => return Ok(unavailable("estate_unavailable", "The estate coordinator is unavailable.", &meta)),
    };
    // Match Swift's explicit caller ceiling. CurrentlyBelieve remains a
    // default predicate; the recipe and count companion share this exact filter.
    let filter = locus_kit::filter::Filter::SensitivityAtMost(maximum_sensitivity);
    let output = match cognition_kit::run_transcript_recall(
        &coordinator,
        &estate.handle,
        &request.query,
        filter.clone(),
        now_millis,
        &HashMap::new(),
    ) {
        Ok(output) => output,
        Err(_) => {
            return Ok(unavailable(
                "rerank_unavailable",
                "The required transcript reranker is unavailable.",
                &meta,
            ));
        }
    };

    if !output.strict.available {
        return Ok(unavailable_with_evidence(&output.strict, &meta));
    }

    let mut frame = locus_kit::filter::RecallFrame::new(vec![filter]);
    frame.hydration_level = locus_kit::filter::HydrationLevel::Full;
    frame.limit = Some(50);
    frame.ordering = locus_kit::filter::Ordering::ByCaptureTimeDesc;
    if super::report_withheld::recall(&coordinator, &estate.handle, frame, now_millis).is_err() {
        return Ok(unavailable("estate_unavailable", "The estate recall is unavailable.", &meta));
    }

    project_success(output.matches, output.strict, &meta)
}

/// Project a completed typed recipe outcome without interpreting a legacy
/// runner payload.  The public response only includes references constructed
/// from drawer UUIDs returned by the recipe.
pub fn project_success(
    rows: Vec<cognition_kit::PreciseMatch>,
    evidence: genius_locus_kit::cross_encoder_stage::StrictTranscriptEvidence,
    meta: &V2ResultMeta,
) -> Result<Value, JSONRPCError> {
    let mut matches = Vec::with_capacity(rows.len());
    for row in rows {
        let memory_id = Uuid::parse_str(&row.id).map_err(|_| {
            JSONRPCError::new(
                crate::jsonrpc::JSONRPCErrorCode::INTERNAL_ERROR,
                "Transcript recall returned a non-UUID drawer identifier.",
            )
        })?;
        matches.push(TranscriptMatch {
            memory_id: canonical_uuid(memory_id),
            room: row.room,
            excerpt: compact_text(&row.content),
            score: row.score,
            fetch: fetch(memory_id),
        });
    }
    let strict = StrictEvidence {
        status: if evidence.available { "applied" } else { "unavailable" },
        policy_version: "transcript_strict_v1",
        reason: evidence.reason,
        encoder_model_id: evidence.active_model_id,
        encoder_model_version: evidence.active_model_version,
        query_dimension: evidence.query_dimension,
        fresh_head_candidates: evidence.fresh_head_candidates,
        scored_head_candidates: evidence.scored_head_candidates,
        classifier_profile: evidence.classifier_profile_id,
        classifier_model_revision: evidence.classifier_model_revision,
        pool: evidence.validated_pool_limit,
        head: evidence.validated_head_limit,
        spans: evidence.validated_spans_limit,
        rrf_k: evidence.validated_rrf_k,
        serving_generation: evidence.serving_generation,
        freshness_verified: evidence.freshness_verified,
    };
    success(
        TRANSCRIPT_RECALL_TOOL,
        &TranscriptData { matches, strict_rerank: strict },
        meta,
        "transcript recall completed",
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
    refusal(TRANSCRIPT_RECALL_TOOL, &V2OperationalRefusal {
        code: code.to_owned(), message: message.to_owned(), retryable: true, recovery: None,
    }, meta)
}

fn unavailable_with_evidence(
    evidence: &genius_locus_kit::cross_encoder_stage::StrictTranscriptEvidence,
    meta: &V2ResultMeta,
) -> Value {
    let recovery = serde_json::json!({
        "required_operation": TRANSCRIPT_RECALL_TOOL,
        "strict_rerank": {
            "status": "unavailable",
            "policy_version": "transcript_strict_v1",
            "reason": evidence.reason,
            "encoder_model_id": evidence.active_model_id,
            "encoder_model_version": evidence.active_model_version,
            "query_dimension": evidence.query_dimension,
            "fresh_head_candidates": evidence.fresh_head_candidates,
            "scored_head_candidates": evidence.scored_head_candidates,
            "classifier_profile": evidence.classifier_profile_id,
            "classifier_model_revision": evidence.classifier_model_revision,
            "pool": evidence.validated_pool_limit,
            "head": evidence.validated_head_limit,
            "spans": evidence.validated_spans_limit,
            "rrf_k": evidence.validated_rrf_k,
            "serving_generation": evidence.serving_generation,
            "freshness_verified": evidence.freshness_verified,
        }
    });
    refusal(TRANSCRIPT_RECALL_TOOL, &V2OperationalRefusal {
        code: "rerank_unavailable".to_owned(),
        message: "Strict transcript reranking is unavailable for this request.".to_owned(),
        retryable: true,
        recovery: Some(recovery),
    }, meta)
}

fn fetch(memory_id: Uuid) -> V2FetchReference {
    V2FetchReference {
        tool: MEMORY_GET_TOOL,
        arguments: V2FetchArguments { memory_id: canonical_uuid(memory_id) },
    }
}
