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
