//! JSON-RPC 2.0 wire type tests — Rust version.
//!
//! Mirrors the Swift `JSONRPCTests` cases: decode with string id, decode
//! notification (no id), reject wrong version, response encoding, error
//! response, and a JSON round-trip. The wire shapes these tests pin are
//! the cross-version wire surface; they must pass byte-for-byte against
//! any conforming client.
//!
//! Also covers the JSON value type: all six variants round-trip through
//! serde_json without loss (the same property Swift's `testJSONValueRoundTrip`
//! pins over Foundation/JSONSerialization).

use aria_mcp::jsonrpc::{
    JSONRPCError, JSONRPCErrorCode, JSONRPCRequest, JSONRPCResponse, JsonValue,
};

// --- JSONRPCRequest::decode -------------------------------------------------

#[test]
fn decode_request_with_string_id() {
    let raw = serde_json::json!({
        "jsonrpc": "2.0",
        "id": "req-1",
        "method": "ping"
    });
    let req = JSONRPCRequest::decode(&raw).expect("should decode");
    assert_eq!(req.method, "ping");
    assert_eq!(req.id, Some(JsonValue::String("req-1".into())));
    assert!(!req.is_notification());
}

#[test]
fn decode_notification_has_no_id() {
    let raw = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "notifications/initialized"
    });
    let req = JSONRPCRequest::decode(&raw).expect("should decode");
    assert!(req.is_notification());
    assert!(req.id.is_none());
}

#[test]
fn decode_rejects_wrong_version() {
    let raw = serde_json::json!({
        "jsonrpc": "1.0",
        "id": 1,
        "method": "ping"
    });
    assert!(JSONRPCRequest::decode(&raw).is_none());
}

#[test]
fn decode_rejects_missing_method() {
    let raw = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1
    });
    assert!(JSONRPCRequest::decode(&raw).is_none());
}

// --- JSONRPCResponse --------------------------------------------------------

#[test]
fn response_encoding_preserves_id_shape() {
    let resp = JSONRPCResponse::ok(JsonValue::Integer(42), serde_json::json!({ "ok": true }));
    let encoded = serde_json::to_value(&resp).unwrap();
    let obj = encoded.as_object().unwrap();
    assert_eq!(obj["id"], serde_json::json!(42));
    assert_eq!(obj["jsonrpc"], serde_json::json!("2.0"));
    assert_eq!(obj["result"], serde_json::json!({ "ok": true }));
}

#[test]
fn error_response_carries_code_and_message() {
    let err = JSONRPCError::new(JSONRPCErrorCode::METHOD_NOT_FOUND, "no such method");
    let resp = JSONRPCResponse::failure(JsonValue::Null, err);
    let encoded = serde_json::to_value(&resp).unwrap();
    let obj = encoded.as_object().unwrap();
    assert_eq!(obj["id"], serde_json::json!(null));
    let err_obj = obj["error"].as_object().unwrap();
    assert_eq!(err_obj["code"], serde_json::json!(-32601_i64));
    assert_eq!(err_obj["message"], serde_json::json!("no such method"));
}

// --- JsonValue round-trip ---------------------------------------------------

#[test]
fn json_value_round_trips_all_variants() {
    // Six variants: null, bool, integer, double, string, array, object.
    let value = JsonValue::Object(std::collections::BTreeMap::from([
        ("name".into(), JsonValue::String("aria-mcp".into())),
        ("count".into(), JsonValue::Integer(7)),
        ("ratio".into(), JsonValue::Double(0.5)),
        ("flag".into(), JsonValue::Bool(true)),
        ("absent".into(), JsonValue::Null),
        (
            "items".into(),
            JsonValue::Array(vec![
                JsonValue::String("a".into()),
                JsonValue::String("b".into()),
            ]),
        ),
    ]));
    let encoded = serde_json::to_string(&value).unwrap();
    let decoded: JsonValue = serde_json::from_str(&encoded).unwrap();
    assert_eq!(decoded, value);
}

#[test]
fn json_value_integer_survives_round_trip_without_becoming_float() {
    // JSON-RPC `limit` args must survive as integers, not 1.0.
    let value = JsonValue::Integer(100);
    let encoded = serde_json::to_string(&value).unwrap();
    assert_eq!(encoded, "100");
    let decoded: JsonValue = serde_json::from_str(&encoded).unwrap();
    assert_eq!(decoded, JsonValue::Integer(100));
}
