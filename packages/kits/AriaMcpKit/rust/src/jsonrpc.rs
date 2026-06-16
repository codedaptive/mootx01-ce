//! JSON-RPC 2.0 wire types — Rust version.
//!
//! Mirrors the Swift `JSONRPC.swift` + `JSONValue.swift` wire model.
//! The shapes these types produce on the wire must be byte-identical to
//! the Swift server's for the cases both handle (initialize, ping,
//! tools/list, tools/call, error codes).
//!
//! # JSON value model
//!
//! JSON-RPC `params` and `result` fields are dynamic. Rather than fighting
//! serde's type system with `serde_json::Value` throughout, we carry a
//! thin typed enum that round-trips through serde_json without loss. The
//! six variants mirror the Swift `JSONValue` enum: null, bool, integer
//! (i64 — preserves integer tool args like `limit` without converting to
//! 1.0), double, string, array, object. BTreeMap keys so serialized objects
//! have deterministic ordering (Swift uses the Foundation default which is
//! unordered; BTreeMap is strictly nicer for test assertions).
//!
//! # Error codes
//!
//! Standard JSON-RPC 2.0 codes plus the implementation-defined
//! `TOOL_DISPATCH_FAILURE` in the reserved band (-32099..-32000), matching
//! the Swift `JSONRPCErrorCode` constants exactly.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// JSON value model
// ---------------------------------------------------------------------------

/// A tagged-union representation of an arbitrary JSON value.
///
/// Mirrors the Swift `JSONValue` enum. The `Integer` variant preserves
/// whole-number values that arrive as integers (e.g. tool `limit` args)
/// so they round-trip as `42` not `42.0`. `Double` covers fractional and
/// IEEE-special values.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonValue {
    /// JSON null.
    Null,
    /// JSON boolean.
    Bool(bool),
    /// Whole-number JSON number — preserves the integer-ness of args like
    /// `limit` across a serde round-trip.
    Integer(i64),
    /// Fractional JSON number.
    Double(f64),
    /// JSON string.
    String(String),
    /// JSON array.
    Array(Vec<JsonValue>),
    /// JSON object with BTreeMap ordering (deterministic for tests).
    Object(BTreeMap<String, JsonValue>),
}

impl JsonValue {
    /// Convenience: extract a string reference.
    pub fn as_str(&self) -> Option<&str> {
        if let JsonValue::String(s) = self {
            Some(s)
        } else {
            None
        }
    }

    /// Convenience: extract an integer (also accepts Double that is
    /// whole-valued, matching the Swift `integerValue` accessor).
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            JsonValue::Integer(i) => Some(*i),
            JsonValue::Double(d) if d.fract() == 0.0 => Some(*d as i64),
            _ => None,
        }
    }

    /// Convenience: extract a float (also accepts Integer).
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            JsonValue::Double(d) => Some(*d),
            JsonValue::Integer(i) => Some(*i as f64),
            _ => None,
        }
    }

    /// Convenience: extract an object map reference.
    pub fn as_object(&self) -> Option<&BTreeMap<String, JsonValue>> {
        if let JsonValue::Object(m) = self {
            Some(m)
        } else {
            None
        }
    }

    /// Convenience: extract an array reference.
    pub fn as_array(&self) -> Option<&[JsonValue]> {
        if let JsonValue::Array(a) = self {
            Some(a)
        } else {
            None
        }
    }

    /// Convenience: extract a bool.
    pub fn as_bool(&self) -> Option<bool> {
        if let JsonValue::Bool(b) = self {
            Some(*b)
        } else {
            None
        }
    }
}

// Allow constructing JsonValue from serde_json::Value for test convenience.
impl From<serde_json::Value> for JsonValue {
    fn from(v: serde_json::Value) -> Self {
        match v {
            serde_json::Value::Null => JsonValue::Null,
            serde_json::Value::Bool(b) => JsonValue::Bool(b),
            serde_json::Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    JsonValue::Integer(i)
                } else {
                    JsonValue::Double(n.as_f64().unwrap_or(f64::NAN))
                }
            }
            serde_json::Value::String(s) => JsonValue::String(s),
            serde_json::Value::Array(a) => {
                JsonValue::Array(a.into_iter().map(JsonValue::from).collect())
            }
            serde_json::Value::Object(m) => JsonValue::Object(
                m.into_iter()
                    .map(|(k, v)| (k, JsonValue::from(v)))
                    .collect(),
            ),
        }
    }
}

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 standard error codes
// ---------------------------------------------------------------------------

/// JSON-RPC 2.0 standard error codes. Field names and values match the Swift
/// `JSONRPCErrorCode` constants for cross-version wire compatibility.
pub struct JSONRPCErrorCode;

impl JSONRPCErrorCode {
    /// -32700: parse error (malformed JSON on the wire).
    pub const PARSE_ERROR: i64 = -32700;
    /// -32600: invalid request (well-formed JSON, bad RPC envelope).
    pub const INVALID_REQUEST: i64 = -32600;
    /// -32601: method not found.
    pub const METHOD_NOT_FOUND: i64 = -32601;
    /// -32602: invalid params (missing / malformed tool argument).
    pub const INVALID_PARAMS: i64 = -32602;
    /// -32603: internal error.
    pub const INTERNAL_ERROR: i64 = -32603;
    /// -32010: implementation-defined — the substrate refused the verb.
    /// Mapped to a JSON-RPC error rather than `tools/call` result isError
    /// so clients without a tool-error code path still see a machine-readable
    /// failure. Tool-level expected refusals stay on the isError=true path.
    pub const TOOL_DISPATCH_FAILURE: i64 = -32010;
}

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 request
// ---------------------------------------------------------------------------

/// A parsed JSON-RPC 2.0 request or notification.
///
/// Notifications are requests without an `id` field. We keep one struct
/// for both; absent `id` (None) signals a notification, which the
/// dispatcher must not reply to.
#[derive(Debug, Clone, PartialEq)]
pub struct JSONRPCRequest {
    pub jsonrpc: String,
    /// None for notifications (no reply expected per JSON-RPC 2.0).
    pub id: Option<JsonValue>,
    pub method: String,
    pub params: Option<JsonValue>,
}

impl JSONRPCRequest {
    /// True for notifications (no `id`). The dispatcher must not reply.
    pub fn is_notification(&self) -> bool {
        self.id.is_none()
    }

    /// Parse a JSON-RPC request from a `serde_json::Value` object.
    /// Returns None for shapes that do not match the JSON-RPC 2.0 request
    /// schema; the caller (the dispatcher) emits an `invalidRequest` response.
    pub fn decode(value: &serde_json::Value) -> Option<JSONRPCRequest> {
        let obj = value.as_object()?;
        let jsonrpc = obj.get("jsonrpc")?.as_str()?;
        if jsonrpc != "2.0" {
            return None;
        }
        let method = obj.get("method")?.as_str()?.to_owned();
        // The spec permits `id` to be a string, number, or null. We pass it
        // through verbatim; absence means notification.
        let id = obj.get("id").map(|v| JsonValue::from(v.clone()));
        let params = obj.get("params").map(|v| JsonValue::from(v.clone()));
        Some(JSONRPCRequest {
            jsonrpc: jsonrpc.to_owned(),
            id,
            method,
            params,
        })
    }
}

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 error
// ---------------------------------------------------------------------------

/// A JSON-RPC 2.0 error object. Serializes to `{"code": N, "message": "..."}`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct JSONRPCError {
    pub code: i64,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

impl JSONRPCError {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        JSONRPCError {
            code,
            message: message.into(),
            data: None,
        }
    }
}

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 response
// ---------------------------------------------------------------------------

/// A JSON-RPC 2.0 response — either a result or an error. Uses a custom
/// Serialize to write exactly `{"jsonrpc": "2.0", "id": ..., "result": ...}`
/// or `{"jsonrpc": "2.0", "id": ..., "error": {...}}`, matching the Swift
/// `JSONRPCResponse.asJSONValue` encoding.
#[derive(Debug, Clone, PartialEq)]
pub struct JSONRPCResponse {
    pub id: JsonValue,
    pub payload: ResponsePayload,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ResponsePayload {
    Result(serde_json::Value),
    Error(JSONRPCError),
}

impl JSONRPCResponse {
    pub fn ok(id: JsonValue, result: serde_json::Value) -> Self {
        JSONRPCResponse {
            id,
            payload: ResponsePayload::Result(result),
        }
    }

    pub fn failure(id: JsonValue, error: JSONRPCError) -> Self {
        JSONRPCResponse {
            id,
            payload: ResponsePayload::Error(error),
        }
    }
}

impl Serialize for JSONRPCResponse {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut map = serializer.serialize_map(Some(3))?;
        map.serialize_entry("jsonrpc", "2.0")?;
        // Serialize id through serde_json Value for consistent number encoding.
        let id_value = serde_json::to_value(&self.id).map_err(serde::ser::Error::custom)?;
        map.serialize_entry("id", &id_value)?;
        match &self.payload {
            ResponsePayload::Result(r) => map.serialize_entry("result", r)?,
            ResponsePayload::Error(e) => map.serialize_entry("error", e)?,
        }
        map.end()
    }
}

// ---------------------------------------------------------------------------
// Helper: encode a result JsonValue (converting our typed enum → serde_json)
// ---------------------------------------------------------------------------

/// Convert an aria-mcp `JsonValue` to `serde_json::Value` for serialization.
/// The round-trip is lossless for all six variants.
pub fn to_sj(v: JsonValue) -> serde_json::Value {
    match v {
        JsonValue::Null => serde_json::Value::Null,
        JsonValue::Bool(b) => serde_json::Value::Bool(b),
        JsonValue::Integer(i) => serde_json::Value::Number(i.into()),
        JsonValue::Double(d) => serde_json::Number::from_f64(d)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::Null),
        JsonValue::String(s) => serde_json::Value::String(s),
        JsonValue::Array(a) => serde_json::Value::Array(a.into_iter().map(to_sj).collect()),
        JsonValue::Object(m) => {
            serde_json::Value::Object(m.into_iter().map(|(k, v)| (k, to_sj(v))).collect())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integer_variant_does_not_become_float() {
        let v = JsonValue::Integer(100);
        let s = serde_json::to_string(&v).unwrap();
        assert_eq!(s, "100");
    }

    #[test]
    fn decode_accepts_integer_id() {
        let raw = serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "ping"});
        let req = JSONRPCRequest::decode(&raw).unwrap();
        assert_eq!(req.id, Some(JsonValue::Integer(1)));
    }

    #[test]
    fn response_error_fields_match_wire_contract() {
        let err = JSONRPCError::new(JSONRPCErrorCode::PARSE_ERROR, "Parse error");
        let resp = JSONRPCResponse::failure(JsonValue::Null, err);
        let v = serde_json::to_value(&resp).unwrap();
        let e = v["error"].as_object().unwrap();
        assert_eq!(e["code"], serde_json::json!(-32700_i64));
    }
}
