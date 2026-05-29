// src/harness/vector_file.rs
//
// In-memory model of a vector file plus canonical JSON
// (de)serialization. Mirrors the Swift harness's
// VectorFile.swift.
//
// We use `serde_json::Value` with the `preserve_order` feature so
// the JSON object key order matches what we write. Canonical JSON
// requires keys lex-sorted; we sort the keys ourselves on write.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub const FORMAT_VERSION: &str = "1";
pub const HARNESS_VERSION: &str = "1.0.0";

#[derive(Debug, Clone)]
pub struct VectorFile {
    pub primitive: String,
    pub cookbook_section: String,
    pub generator: Generator,
    pub seed: u64,
    pub generated_at: String,
    pub output_crc32: u32,
    pub cases: Vec<VectorCase>,
}

#[derive(Debug, Clone)]
pub struct Generator {
    pub language: String,
    pub harness_version: String,
    pub reference_file: String,
}

#[derive(Debug, Clone)]
pub struct VectorCase {
    pub id: String,
    pub description: String,
    pub inputs: JsonObject,
    pub expected_output: JsonObject,
}

/// JSON object with stable key ordering (lex-sorted on write).
pub type JsonObject = BTreeMap<String, JsonValue>;

#[derive(Debug, Clone, PartialEq)]
pub enum JsonValue {
    String(String),
    Integer(i64),
    Bool(bool),
    Null,
    Array(Vec<JsonValue>),
    Object(JsonObject),
}

// ============================================================
// Writer — canonical JSON output per spec
// ============================================================

pub struct JsonWriter;

impl JsonWriter {
    pub fn write(file: &VectorFile) -> String {
        let mut root: JsonObject = BTreeMap::new();
        root.insert("format_version".into(), JsonValue::String(FORMAT_VERSION.into()));
        root.insert("primitive".into(), JsonValue::String(file.primitive.clone()));
        root.insert(
            "cookbook_section".into(),
            JsonValue::String(file.cookbook_section.clone()),
        );

        let mut gen_obj: JsonObject = BTreeMap::new();
        gen_obj.insert(
            "language".into(),
            JsonValue::String(file.generator.language.clone()),
        );
        gen_obj.insert(
            "harness_version".into(),
            JsonValue::String(file.generator.harness_version.clone()),
        );
        gen_obj.insert(
            "reference_file".into(),
            JsonValue::String(file.generator.reference_file.clone()),
        );
        root.insert("generator".into(), JsonValue::Object(gen_obj));

        root.insert(
            "seed".into(),
            JsonValue::String(super::hex::u64_hex(file.seed)),
        );
        root.insert(
            "generated_at".into(),
            JsonValue::String(file.generated_at.clone()),
        );
        root.insert(
            "case_count".into(),
            JsonValue::Integer(file.cases.len() as i64),
        );
        root.insert(
            "output_crc32".into(),
            JsonValue::String(super::hex::u32_hex(file.output_crc32)),
        );

        let cases_arr: Vec<JsonValue> = file
            .cases
            .iter()
            .map(|c| {
                let mut o: JsonObject = BTreeMap::new();
                o.insert("id".into(), JsonValue::String(c.id.clone()));
                o.insert("description".into(), JsonValue::String(c.description.clone()));
                o.insert("inputs".into(), JsonValue::Object(c.inputs.clone()));
                o.insert(
                    "expected_output".into(),
                    JsonValue::Object(c.expected_output.clone()),
                );
                JsonValue::Object(o)
            })
            .collect();
        root.insert("cases".into(), JsonValue::Array(cases_arr));

        let mut out = String::new();
        write_value(&JsonValue::Object(root), 0, &mut out);
        out.push('\n');
        out
    }
}

fn write_value(v: &JsonValue, indent: usize, out: &mut String) {
    let pad = "  ".repeat(indent);
    let next_pad = "  ".repeat(indent + 1);
    match v {
        JsonValue::String(s) => {
            out.push('"');
            for c in s.chars() {
                match c {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    '\r' => out.push_str("\\r"),
                    '\t' => out.push_str("\\t"),
                    c if (c as u32) < 0x20 => {
                        out.push_str(&format!("\\u{:04x}", c as u32));
                    }
                    c => out.push(c),
                }
            }
            out.push('"');
        }
        JsonValue::Integer(i) => out.push_str(&i.to_string()),
        JsonValue::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        JsonValue::Null => out.push_str("null"),
        JsonValue::Array(arr) => {
            if arr.is_empty() {
                out.push_str("[]");
            } else {
                out.push_str("[\n");
                for (i, item) in arr.iter().enumerate() {
                    out.push_str(&next_pad);
                    write_value(item, indent + 1, out);
                    if i < arr.len() - 1 {
                        out.push(',');
                    }
                    out.push('\n');
                }
                out.push_str(&pad);
                out.push(']');
            }
        }
        JsonValue::Object(obj) => {
            if obj.is_empty() {
                out.push_str("{}");
            } else {
                out.push_str("{\n");
                let count = obj.len();
                for (i, (k, val)) in obj.iter().enumerate() {
                    out.push_str(&next_pad);
                    out.push('"');
                    out.push_str(k);
                    out.push_str("\": ");
                    write_value(val, indent + 1, out);
                    if i < count - 1 {
                        out.push(',');
                    }
                    out.push('\n');
                }
                out.push_str(&pad);
                out.push('}');
            }
        }
    }
}

// ============================================================
// Reader — parse a canonical JSON file into VectorFile
// ============================================================

pub struct JsonReader;

impl JsonReader {
    pub fn parse_vector_file(s: &str) -> Result<VectorFile, JsonReaderError> {
        let raw: serde_json::Value = serde_json::from_str(s)
            .map_err(|e| JsonReaderError::Malformed(format!("serde_json: {e}")))?;
        let root = raw
            .as_object()
            .ok_or_else(|| JsonReaderError::Malformed("root is not an object".into()))?;

        let format_version = root
            .get("format_version")
            .and_then(|v| v.as_str())
            .ok_or(JsonReaderError::MissingField("format_version"))?;
        if format_version != FORMAT_VERSION {
            return Err(JsonReaderError::VersionMismatch(format_version.to_owned()));
        }

        let primitive = root
            .get("primitive")
            .and_then(|v| v.as_str())
            .ok_or(JsonReaderError::MissingField("primitive"))?
            .to_owned();
        let cookbook_section = root
            .get("cookbook_section")
            .and_then(|v| v.as_str())
            .ok_or(JsonReaderError::MissingField("cookbook_section"))?
            .to_owned();
        let generated_at = root
            .get("generated_at")
            .and_then(|v| v.as_str())
            .ok_or(JsonReaderError::MissingField("generated_at"))?
            .to_owned();

        let seed_hex = root
            .get("seed")
            .and_then(|v| v.as_str())
            .ok_or(JsonReaderError::MissingField("seed"))?;
        let seed_bytes = super::hex::decode_hex(seed_hex)
            .map_err(|e| JsonReaderError::Malformed(format!("seed: {e}")))?;
        if seed_bytes.len() != 8 {
            return Err(JsonReaderError::Malformed("seed must be 8 bytes".into()));
        }
        let mut seed: u64 = 0;
        for (i, b) in seed_bytes.iter().enumerate() {
            seed |= (*b as u64) << (i * 8);
        }

        let crc_hex = root
            .get("output_crc32")
            .and_then(|v| v.as_str())
            .ok_or(JsonReaderError::MissingField("output_crc32"))?;
        let crc_bytes = super::hex::decode_hex(crc_hex)
            .map_err(|e| JsonReaderError::Malformed(format!("output_crc32: {e}")))?;
        if crc_bytes.len() != 4 {
            return Err(JsonReaderError::Malformed("output_crc32 must be 4 bytes".into()));
        }
        let mut crc: u32 = 0;
        for (i, b) in crc_bytes.iter().enumerate() {
            crc |= (*b as u32) << (i * 8);
        }

        let gen_obj = root
            .get("generator")
            .and_then(|v| v.as_object())
            .ok_or(JsonReaderError::MissingField("generator"))?;
        let generator = Generator {
            language: gen_obj
                .get("language")
                .and_then(|v| v.as_str())
                .ok_or(JsonReaderError::MissingField("generator.language"))?
                .to_owned(),
            harness_version: gen_obj
                .get("harness_version")
                .and_then(|v| v.as_str())
                .ok_or(JsonReaderError::MissingField("generator.harness_version"))?
                .to_owned(),
            reference_file: gen_obj
                .get("reference_file")
                .and_then(|v| v.as_str())
                .ok_or(JsonReaderError::MissingField("generator.reference_file"))?
                .to_owned(),
        };

        let cases_arr = root
            .get("cases")
            .and_then(|v| v.as_array())
            .ok_or(JsonReaderError::MissingField("cases"))?;

        let mut cases = Vec::with_capacity(cases_arr.len());
        for v in cases_arr {
            let co = v
                .as_object()
                .ok_or_else(|| JsonReaderError::Malformed("case is not an object".into()))?;
            let id = co
                .get("id")
                .and_then(|v| v.as_str())
                .ok_or(JsonReaderError::MissingField("case.id"))?
                .to_owned();
            let description = co
                .get("description")
                .and_then(|v| v.as_str())
                .ok_or(JsonReaderError::MissingField("case.description"))?
                .to_owned();
            let inputs = to_json_object(
                co.get("inputs")
                    .ok_or(JsonReaderError::MissingField("case.inputs"))?,
            )?;
            let expected_output = to_json_object(
                co.get("expected_output")
                    .ok_or(JsonReaderError::MissingField("case.expected_output"))?,
            )?;
            cases.push(VectorCase {
                id,
                description,
                inputs,
                expected_output,
            });
        }

        Ok(VectorFile {
            primitive,
            cookbook_section,
            generator,
            seed,
            generated_at,
            output_crc32: crc,
            cases,
        })
    }
}

fn to_json_object(v: &serde_json::Value) -> Result<JsonObject, JsonReaderError> {
    let obj = v
        .as_object()
        .ok_or_else(|| JsonReaderError::Malformed("expected object".into()))?;
    let mut out: JsonObject = BTreeMap::new();
    for (k, val) in obj {
        out.insert(k.clone(), to_json_value(val)?);
    }
    Ok(out)
}

fn to_json_value(v: &serde_json::Value) -> Result<JsonValue, JsonReaderError> {
    use serde_json::Value;
    match v {
        Value::String(s) => Ok(JsonValue::String(s.clone())),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Ok(JsonValue::Integer(i))
            } else {
                Err(JsonReaderError::Malformed(
                    "non-integer number; f64 must be hex-encoded as string".into(),
                ))
            }
        }
        Value::Bool(b) => Ok(JsonValue::Bool(*b)),
        Value::Null => Ok(JsonValue::Null),
        Value::Array(arr) => {
            let mut out = Vec::with_capacity(arr.len());
            for x in arr {
                out.push(to_json_value(x)?);
            }
            Ok(JsonValue::Array(out))
        }
        Value::Object(_) => Ok(JsonValue::Object(to_json_object(v)?)),
    }
}

#[derive(Debug, Clone)]
pub enum JsonReaderError {
    MissingField(&'static str),
    Malformed(String),
    VersionMismatch(String),
}

impl std::fmt::Display for JsonReaderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            JsonReaderError::MissingField(s) => write!(f, "missing field: {s}"),
            JsonReaderError::Malformed(s) => write!(f, "malformed: {s}"),
            JsonReaderError::VersionMismatch(v) => write!(f, "unsupported format_version: {v}"),
        }
    }
}

impl std::error::Error for JsonReaderError {}

// serde derives left out since we serialize manually for canonical form.
// Suppress unused-import warnings via stub use:
#[allow(dead_code)]
fn _unused_serde() -> impl Serialize + for<'de> Deserialize<'de> {
    0u32
}
