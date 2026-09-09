//! Strict shared v2 argument decoding.
//!
//! V2 accepts canonical argument spellings only.  These helpers reject
//! unknown fields and malformed scalar values before a typed operation runs.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{json, Value};
use uuid::Uuid;

use crate::jsonrpc::{JSONRPCError, JSONRPCErrorCode, JsonValue};

/// Structured `-32602` data required for malformed v2 arguments.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2InvalidArgument {
    pub path: String,
    pub message: String,
    pub allowed: Option<Vec<String>>,
    pub correction: Option<String>,
}

impl V2InvalidArgument {
    pub fn new(path: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            message: message.into(),
            allowed: None,
            correction: None,
        }
    }

    pub fn allowed(mut self, allowed: impl IntoIterator<Item = String>) -> Self {
        self.allowed = Some(allowed.into_iter().collect());
        self
    }

    pub fn correction(mut self, correction: impl Into<String>) -> Self {
        self.correction = Some(correction.into());
        self
    }

    pub fn data(&self) -> Value {
        let mut value = json!({
            "code": "invalid_argument",
            "path": self.path,
            "message": self.message,
        });
        let object = value.as_object_mut().expect("fixed object literal");
        if let Some(allowed) = &self.allowed {
            object.insert("allowed".to_owned(), json!(allowed));
        }
        if let Some(correction) = &self.correction {
            object.insert("correction".to_owned(), json!(correction));
        }
        value
    }

    pub fn into_jsonrpc_error(self) -> JSONRPCError {
        JSONRPCError {
            code: JSONRPCErrorCode::INVALID_PARAMS,
            message: "Invalid arguments".to_owned(),
            data: Some(self.data()),
        }
    }
}

pub type V2DecodeResult<T> = Result<T, V2InvalidArgument>;

/// Require an object and reject fields outside the operation's declared keys.
pub fn strict_object<'a>(
    value: &'a JsonValue,
    allowed: impl IntoIterator<Item = &'a str>,
) -> V2DecodeResult<&'a BTreeMap<String, JsonValue>> {
    let object = value
        .as_object()
        .ok_or_else(|| V2InvalidArgument::new("$", "must be an object"))?;
    reject_unknown_fields(object, allowed)?;
    Ok(object)
}

/// Reject unknown fields without altering the caller's object.
pub fn reject_unknown_fields<'a>(
    object: &BTreeMap<String, JsonValue>,
    allowed: impl IntoIterator<Item = &'a str>,
) -> V2DecodeResult<()> {
    let allowed: BTreeSet<&str> = allowed.into_iter().collect();
    let accepted: Vec<String> = allowed.iter().map(|key| (*key).to_owned()).collect();
    for key in object.keys() {
        if !allowed.contains(key.as_str()) {
            return Err(V2InvalidArgument::new(
                format!("$.{key}"),
                "is not accepted by this operation",
            )
            .allowed(accepted)
            .correction("remove the unknown argument or use a documented argument name"));
        }
    }
    Ok(())
}

pub fn required_string<'a>(
    object: &'a BTreeMap<String, JsonValue>,
    key: &str,
) -> V2DecodeResult<&'a str> {
    match object.get(key) {
        Some(JsonValue::String(value)) => Ok(value),
        Some(_) => Err(V2InvalidArgument::new(
            format!("$.{key}"),
            "must be a string",
        )),
        None => Err(V2InvalidArgument::new(
            format!("$.{key}"),
            "is required",
        )),
    }
}

pub fn optional_string<'a>(
    object: &'a BTreeMap<String, JsonValue>,
    key: &str,
) -> V2DecodeResult<Option<&'a str>> {
    match object.get(key) {
        None => Ok(None),
        Some(JsonValue::String(value)) => Ok(Some(value)),
        Some(_) => Err(V2InvalidArgument::new(
            format!("$.{key}"),
            "must be a string",
        )),
    }
}

pub fn required_bool(object: &BTreeMap<String, JsonValue>, key: &str) -> V2DecodeResult<bool> {
    match object.get(key) {
        Some(JsonValue::Bool(value)) => Ok(*value),
        Some(_) => Err(V2InvalidArgument::new(
            format!("$.{key}"),
            "must be a boolean",
        )),
        None => Err(V2InvalidArgument::new(
            format!("$.{key}"),
            "is required",
        )),
    }
}

pub fn optional_integer(
    object: &BTreeMap<String, JsonValue>,
    key: &str,
) -> V2DecodeResult<Option<i64>> {
    match object.get(key) {
        None => Ok(None),
        Some(value) => value.as_i64().map(Some).ok_or_else(|| {
            V2InvalidArgument::new(format!("$.{key}"), "must be an integer")
        }),
    }
}

pub fn required_uuid(object: &BTreeMap<String, JsonValue>, key: &str) -> V2DecodeResult<Uuid> {
    let value = required_string(object, key)?;
    decode_uuid(value, &format!("$.{key}"))
}

pub fn optional_uuid(
    object: &BTreeMap<String, JsonValue>,
    key: &str,
) -> V2DecodeResult<Option<Uuid>> {
    optional_string(object, key)?.map(|value| decode_uuid(value, &format!("$.{key}"))).transpose()
}

/// Accept only hyphenated UUID input with valid hexadecimal casing and return
/// its parsed value.  Rendering always uses [`canonical_uuid`].
pub fn decode_uuid(value: &str, path: &str) -> V2DecodeResult<Uuid> {
    let groups: Vec<&str> = value.split('-').collect();
    let valid_shape = matches!(groups.as_slice(), [a, b, c, d, e]
        if a.len() == 8 && b.len() == 4 && c.len() == 4 && d.len() == 4 && e.len() == 12)
        && value.bytes().all(|byte| byte == b'-' || byte.is_ascii_hexdigit());
    if !valid_shape {
        return Err(V2InvalidArgument::new(path, "must be a hyphenated UUID")
            .correction("use a UUID such as 01234567-89ab-cdef-0123-456789abcdef"));
    }
    Uuid::parse_str(value).map_err(|_| {
        V2InvalidArgument::new(path, "must be a valid UUID")
            .correction("use a valid hyphenated UUID")
    })
}

/// Canonical v2 UUID wire spelling: lowercase, hyphenated hexadecimal.
pub fn canonical_uuid(value: Uuid) -> String {
    value.hyphenated().to_string()
}
