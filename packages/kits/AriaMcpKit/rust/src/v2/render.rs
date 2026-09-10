//! Final typed v2 result projection.
//!
//! This module receives typed result data.  It never interprets legacy runner
//! text or JSON, so a v2 response cannot inherit an accidental v1 shape.

use serde::Serialize;
use serde_json::{json, Value};

use super::operation::V2OperationEffect;

pub const V2_SURFACE_VERSION: &str = "v2";
pub const V2_COMPACT_TEXT_SCALAR_LIMIT: usize = 512;

/// Metadata shared by every typed v2 result envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2ResultMeta {
    pub build_id: String,
    pub capability_digest: String,
    pub effect: V2OperationEffect,
    pub completeness: String,
}

impl V2ResultMeta {
    pub fn incomplete(
        build_id: impl Into<String>,
        capability_digest: impl Into<String>,
        effect: V2OperationEffect,
    ) -> Self {
        Self {
            build_id: build_id.into(),
            capability_digest: capability_digest.into(),
            effect,
            completeness: "incomplete".to_owned(),
        }
    }

    fn as_value(&self) -> Value {
        json!({
            "build_id": self.build_id,
            "capability_digest": self.capability_digest,
            "effect": self.effect,
            "completeness": self.completeness,
        })
    }
}

/// Expected operational failure after a tool has been selected.
#[derive(Debug, Clone, PartialEq)]
pub struct V2OperationalRefusal {
    pub code: String,
    pub message: String,
    pub retryable: bool,
    pub recovery: Option<Value>,
}

impl V2OperationalRefusal {
    fn as_value(&self) -> Value {
        let mut error = json!({
            "code": self.code,
            "message": self.message,
            "retryable": self.retryable,
        });
        if let Some(recovery) = &self.recovery {
            error
                .as_object_mut()
                .expect("fixed object literal")
                .insert("recovery".to_owned(), recovery.clone());
        }
        error
    }
}

/// Clamp user-facing compact text by Unicode scalar values, never bytes.
pub fn compact_text(value: &str) -> String {
    value.chars().take(V2_COMPACT_TEXT_SCALAR_LIMIT).collect()
}

/// Project typed success data to MCP's outer and structured result shapes.
pub fn success<T: Serialize>(
    tool: &str,
    data: &T,
    meta: &V2ResultMeta,
    text: &str,
) -> Result<Value, serde_json::Error> {
    let envelope = json!({
        "surface_version": V2_SURFACE_VERSION,
        "tool": tool,
        "data": serde_json::to_value(data)?,
        "meta": meta.as_value(),
    });
    Ok(json!({
        "content": [{ "type": "text", "text": compact_text(text) }],
        "structuredContent": envelope,
        "isError": false,
    }))
}

/// Project an expected operational refusal to MCP's error result shape.
pub fn refusal(
    tool: &str,
    refusal: &V2OperationalRefusal,
    meta: &V2ResultMeta,
) -> Value {
    let envelope = json!({
        "surface_version": V2_SURFACE_VERSION,
        "tool": tool,
        "error": refusal.as_value(),
        "meta": meta.as_value(),
    });
    json!({
        "content": [{ "type": "text", "text": compact_text(&refusal.message) }],
        "structuredContent": envelope,
        "isError": true,
    })
}

/// Attach a coaching hint to a non-error v2 result (RULING 3, §12.5).
///
/// Two mutations, both guarded by isError check:
/// 1. `structuredContent["hint"]` — top-level string sibling of "data" and "meta".
/// 2. `content[0].text` — `"\nhint: <text>"` appended AFTER the 512 Unicode-scalar
///    body clamp. The hint line itself is not clamped.
///
/// Called at the v2 dispatcher choke point when `coaching_hint` returns `Some`.
/// Never on a refusal (isError:true) — the caller's coach.rs guards this, but
/// this function also re-checks so it is safe regardless of call order.
///
/// Parity: Rust twin of Swift `AriaV2Envelope.applyHint(_:to:)`.
pub fn apply_hint(mut result: Value, hint: &str) -> Value {
    // Re-check: never mutate an error result.
    if result.get("isError").and_then(|v| v.as_bool()) == Some(true) {
        return result;
    }
    // 1. structuredContent["hint"] — present only when a hint fires.
    if let Some(sc) = result.get_mut("structuredContent") {
        if let Some(obj) = sc.as_object_mut() {
            obj.insert("hint".to_owned(), Value::String(hint.to_owned()));
        }
    }
    // 2. content[0].text — append "\nhint: <text>" after the 512-scalar body.
    if let Some(content) = result.get_mut("content") {
        if let Some(arr) = content.as_array_mut() {
            if let Some(first) = arr.get_mut(0) {
                if let Some(obj) = first.as_object_mut() {
                    if let Some(text) = obj.get_mut("text") {
                        if let Some(s) = text.as_str() {
                            *text = Value::String(format!("{}\nhint: {}", s, hint));
                        }
                    }
                }
            }
        }
    }
    result
}

/// Append a periodic coaching block to `content[0].text` of a non-error v2
/// result (§12.5 periodic coaching cadence, FACT E).
///
/// Unlike `apply_hint`, the block has no structuredContent key — it is text
/// only, appended after any hint line already present. Never on a refusal.
///
/// Called at the v2 dispatcher choke point when `mode_session_state.should_coach()`
/// returns true. Gated by the caller, but this function re-checks isError for
/// safety.
///
/// Parity: Rust twin of Swift `AriaV2Envelope.applyCoachingBlock(_:to:)`.
pub fn apply_coaching_block(mut result: Value, block: &str) -> Value {
    // Re-check: never mutate an error result.
    if result.get("isError").and_then(|v| v.as_bool()) == Some(true) {
        return result;
    }
    // Append coaching block to content[0].text after any hint already present.
    if let Some(content) = result.get_mut("content") {
        if let Some(arr) = content.as_array_mut() {
            if let Some(first) = arr.get_mut(0) {
                if let Some(obj) = first.as_object_mut() {
                    if let Some(text) = obj.get_mut("text") {
                        if let Some(s) = text.as_str() {
                            *text = Value::String(format!("{}\n{}", s, block));
                        }
                    }
                }
            }
        }
    }
    result
}
