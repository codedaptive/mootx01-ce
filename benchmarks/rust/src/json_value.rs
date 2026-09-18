//! json_value.rs — a loosely-typed JSON value.
//!
//! Ports Swift `JSONValue` (in MCPClient.swift). Used both to build
//! tool-call arguments and to parse tool results from servers whose result
//! shapes are not known at compile time (the benchmarker is engine-agnostic).
//!
//! Encoding/decoding rides on `serde_json::Value` so the wire bytes match the
//! Swift `JSONEncoder`/`JSONDecoder` output for the same logical value: an
//! object is a JSON object, a number is a JSON number, etc. The one wrinkle
//! the Swift leg has — encoding request ids as whole numbers (`100`, not
//! `100.0`) — is preserved here because integral `f64`s serialize through
//! serde_json as integers.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// A loosely-typed JSON value. Mirrors Swift `JSONValue`.
///
/// Object members are stored in a `BTreeMap` so iteration order is
/// deterministic (lexicographic by key) — the Swift leg sorts object keys at
/// the points where order matters (`objectArray`), and a stable order here
/// makes encode output reproducible across runs and matches that discipline.
#[derive(Debug, Clone, PartialEq)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<JsonValue>),
    Object(BTreeMap<String, JsonValue>),
}

impl JsonValue {
    /// The value at an object key, or `None` if not an object / key absent.
    /// Mirrors Swift `JSONValue.subscript(key:)`.
    pub fn get(&self, key: &str) -> Option<&JsonValue> {
        match self {
            JsonValue::Object(map) => map.get(key),
            _ => None,
        }
    }

    /// The string payload, if this value is a string. Mirrors Swift
    /// `JSONValue.stringValue`.
    pub fn string_value(&self) -> Option<&str> {
        match self {
            JsonValue::String(s) => Some(s.as_str()),
            _ => None,
        }
    }

    /// Convenience constructor for an object from key/value pairs.
    pub fn object<I>(pairs: I) -> JsonValue
    where
        I: IntoIterator<Item = (String, JsonValue)>,
    {
        JsonValue::Object(pairs.into_iter().collect())
    }

    /// Parses raw JSON bytes into a `JsonValue`. Mirrors decoding a
    /// `JSONValue` via `JSONDecoder` on the Swift leg.
    pub fn from_slice(data: &[u8]) -> Result<JsonValue, serde_json::Error> {
        let v: Value = serde_json::from_slice(data)?;
        Ok(JsonValue::from(v))
    }

    /// Serializes this value to JSON bytes. Mirrors encoding a `JSONValue`
    /// via `JSONEncoder` on the Swift leg.
    pub fn to_vec(&self) -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(&Value::from(self.clone()))
    }
}

// ── Bridge to/from serde_json::Value ─────────────────────────────────────────
// We round-trip through serde_json::Value so the wire format is byte-compatible
// with the Swift Foundation encoder for the same logical value.

impl From<Value> for JsonValue {
    fn from(v: Value) -> Self {
        match v {
            Value::Null => JsonValue::Null,
            Value::Bool(b) => JsonValue::Bool(b),
            Value::Number(n) => JsonValue::Number(n.as_f64().unwrap_or(0.0)),
            Value::String(s) => JsonValue::String(s),
            Value::Array(a) => JsonValue::Array(a.into_iter().map(JsonValue::from).collect()),
            Value::Object(o) => {
                JsonValue::Object(o.into_iter().map(|(k, v)| (k, JsonValue::from(v))).collect())
            }
        }
    }
}

impl From<JsonValue> for Value {
    fn from(v: JsonValue) -> Self {
        match v {
            JsonValue::Null => Value::Null,
            JsonValue::Bool(b) => Value::Bool(b),
            JsonValue::Number(n) => {
                // Encode an integral f64 as a JSON integer (100, not 100.0) so
                // the wire matches Swift's encoder for whole-number request ids
                // and pagination args — the servers accept integers, not floats.
                if n.fract() == 0.0 && n.is_finite() && n.abs() < 9.007_199_254_740_992e15 {
                    Value::Number((n as i64).into())
                } else {
                    serde_json::Number::from_f64(n)
                        .map(Value::Number)
                        .unwrap_or(Value::Null)
                }
            }
            JsonValue::String(s) => Value::String(s),
            JsonValue::Array(a) => Value::Array(a.into_iter().map(Value::from).collect()),
            JsonValue::Object(o) => {
                Value::Object(o.into_iter().map(|(k, v)| (k, Value::from(v))).collect())
            }
        }
    }
}

// Serde impls delegate to the serde_json::Value bridge so callers can embed a
// JsonValue inside other serde structures if needed.
impl Serialize for JsonValue {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        Value::from(self.clone()).serialize(s)
    }
}

impl<'de> Deserialize<'de> for JsonValue {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Value::deserialize(d).map(JsonValue::from)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_on_object_returns_member() {
        let v = JsonValue::object([("k".to_string(), JsonValue::String("v".to_string()))]);
        assert_eq!(v.get("k").and_then(|x| x.string_value()), Some("v"));
        assert!(v.get("missing").is_none());
    }

    #[test]
    fn get_on_non_object_is_none() {
        assert!(JsonValue::Bool(true).get("k").is_none());
    }

    #[test]
    fn integral_number_encodes_without_decimal() {
        let v = JsonValue::Number(100.0);
        let bytes = v.to_vec().unwrap();
        assert_eq!(String::from_utf8(bytes).unwrap(), "100");
    }

    #[test]
    fn round_trip_object() {
        let bytes = br#"{"a":1,"b":"x","c":[true,null]}"#;
        let v = JsonValue::from_slice(bytes).unwrap();
        assert_eq!(v.get("b").and_then(|x| x.string_value()), Some("x"));
        match v.get("c") {
            Some(JsonValue::Array(a)) => assert_eq!(a.len(), 2),
            other => panic!("expected array, got {other:?}"),
        }
    }
}
