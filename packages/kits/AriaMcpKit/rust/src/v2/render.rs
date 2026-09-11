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

/// Append a second content text block carrying `{"id_map":{…}}` to a non-error
/// v2 result. Used by `moot_json_import` when `return_id_map=true`.
///
/// The structured data already carries `id_map` on every JSON import; this
/// second block serves text-only callers that cannot read structuredContent.
/// Its shape is wire-identical to the v1 receipt's second block.
///
/// Byte parity with Swift rests on two properties, both load-bearing:
/// the id_map is collected into a `BTreeMap` at surface.rs before being
/// passed to `json!`, so keys serialize in sorted order regardless of
/// serde_json's `preserve_order` feature state (which IS on in this build
/// graph, making serde_json's Map an IndexMap — without the BTreeMap
/// collect the keys would be unsorted); and serde_json never escapes
/// forward slashes, matching Swift's `.withoutEscapingSlashes`.
///
/// Returns the result unchanged when `id_map` is absent from the data or the
/// map cannot be serialized. Both signal a data-contract violation, and the
/// receipt is still worth delivering without the second block.
///
/// Parity: Rust twin of Swift `AriaV2DataMobility.appendIDMapBlock(_:from:)`.
pub fn append_id_map_block(mut result: Value, data: &Value) -> Value {
    // Re-check: never mutate an error result.
    if result.get("isError").and_then(|v| v.as_bool()) == Some(true) {
        return result;
    }
    let Some(id_map) = data.get("id_map") else { return result };
    let Ok(text) = serde_json::to_string(&json!({ "id_map": id_map })) else { return result };
    if let Some(content) = result.get_mut("content") {
        if let Some(arr) = content.as_array_mut() {
            arr.push(json!({ "type": "text", "text": text }));
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Build a minimal success-shaped envelope for testing render functions.
    fn make_success(text: &str) -> Value {
        json!({
            "content": [{"type": "text", "text": text}],
            "structuredContent": {"surface_version": "v2"},
            "isError": false
        })
    }

    // Build a minimal error-shaped envelope for the isError guard tests.
    fn make_error(text: &str) -> Value {
        json!({
            "content": [{"type": "text", "text": text}],
            "structuredContent": {"surface_version": "v2"},
            "isError": true
        })
    }

    // ------------------------------------------------------------------
    // compact_text
    // ------------------------------------------------------------------

    #[test]
    fn compact_text_clamps_to_512_scalars() {
        // A body longer than 512 scalars must be clamped to exactly 512.
        let long = "x".repeat(600);
        let result = compact_text(&long);
        assert_eq!(result.chars().count(), 512, "must clamp 600 scalars to 512");
    }

    #[test]
    fn compact_text_short_string_unchanged() {
        // A body shorter than the limit must pass through unchanged.
        let short = "hello world";
        let result = compact_text(short);
        assert_eq!(result, short, "short string must pass through unchanged");
    }

    #[test]
    fn compact_text_exactly_512_scalars_unchanged() {
        // A body of exactly 512 scalars must not be shortened.
        let exact = "a".repeat(512);
        let result = compact_text(&exact);
        assert_eq!(
            result.chars().count(),
            512,
            "512-scalar string must survive intact"
        );
        assert_eq!(result, exact, "512-scalar string content must be unchanged");
    }

    // ------------------------------------------------------------------
    // apply_hint
    // ------------------------------------------------------------------

    #[test]
    fn apply_hint_sets_structured_content_and_appends_text() {
        // Both mutation sites fire: structuredContent["hint"] is set and
        // content[0].text gains the "\nhint: <text>" suffix.
        let result = apply_hint(make_success("base text"), "do this instead");
        assert_eq!(
            result["structuredContent"]["hint"].as_str(),
            Some("do this instead"),
            "structuredContent[hint] must be set to the hint text"
        );
        let text = result["content"][0]["text"].as_str().unwrap_or("");
        assert!(
            text.contains("\nhint: do this instead"),
            "content[0].text must contain the hint line; got: {text:?}"
        );
    }

    #[test]
    fn apply_hint_ignores_error_result() {
        // isError:true — the function must return the envelope unchanged.
        let err = make_error("error text");
        let after = apply_hint(err.clone(), "some hint");
        assert_eq!(after, err, "apply_hint must leave an error result unchanged");
    }

    // ------------------------------------------------------------------
    // apply_coaching_block
    // ------------------------------------------------------------------

    #[test]
    fn apply_coaching_block_appends_block_to_text() {
        // The coaching block is appended to content[0].text with a leading newline.
        let result = apply_coaching_block(
            make_success("operation result"),
            "coaching block content",
        );
        let text = result["content"][0]["text"].as_str().unwrap_or("");
        assert!(
            text.ends_with("\ncoaching block content"),
            "coaching block must be appended with a leading newline; got: {text:?}"
        );
    }

    #[test]
    fn apply_coaching_block_ignores_error_result() {
        // isError:true — the function must return the envelope unchanged.
        let err = make_error("error text");
        let after = apply_coaching_block(err.clone(), "some block");
        assert_eq!(
            after, err,
            "apply_coaching_block must leave an error result unchanged"
        );
    }

    #[test]
    fn apply_coaching_block_appends_after_hint() {
        // When both fire in order, the hint line precedes the coaching block.
        let base = make_success("body");
        let with_hint = apply_hint(base, "hint text");
        let with_block = apply_coaching_block(with_hint, "--- block ---");
        let text = with_block["content"][0]["text"].as_str().unwrap_or("");
        let hint_pos = text.find("\nhint:").expect("hint must be present");
        let block_pos = text.find("--- block ---").expect("block must be present");
        assert!(
            hint_pos < block_pos,
            "hint must precede coaching block in text; text: {text:?}"
        );
    }
}
