//! manifest.rs — CapabilityManifest decode + resolve.
//!
//! Ports `CapabilityManifest.swift` exactly. Decode + resolve are pure and
//! deterministic (no `Date::now()`, no randomness) so the output is
//! conformance-vector testable.
//!
//! ## Schema-version gate (SPEC §13.7)
//! Only major version 1 is recognized. An unrecognized major version returns
//! [`ManifestValidationError::UnknownSchemaVersion`] — refuse, do not guess.
//!
//! ## Performance-neutrality (SPEC §13.5)
//! `resolve_dispatch_table` is called ONCE at startup. The returned
//! `ManifestDispatchTable` holds pre-compiled data; no JSON parsing occurs
//! inside any timed window.

use std::collections::{HashMap, HashSet};
use serde::Deserialize;

// ─────────────────────────────────────────────────────────────────────────────
// Validation errors
// ─────────────────────────────────────────────────────────────────────────────

/// Errors raised when a capability manifest fails validation.
/// Mirror Swift `ManifestValidationError` case-for-case.
#[derive(Debug, PartialEq)]
pub enum ManifestValidationError {
    /// A required field is absent or empty.
    RequiredFieldMissing(String),
    /// The provenance value is not one of the three recognized strings.
    UnknownProvenance(String),
    /// A technique token is not in the controlled vocabulary (SPEC §13.4).
    UnknownTechnique(String),
    /// The technique list is empty (SPEC §13.7: technique MUST be non-empty).
    EmptyTechniqueList { call_type: String },
    /// The manifest's major schema_version is not recognized; refuse rather than guess.
    UnknownSchemaVersion(i64),
}

impl std::fmt::Display for ManifestValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RequiredFieldMissing(field) =>
                write!(f, "required field missing: {field}"),
            Self::UnknownProvenance(value) =>
                write!(f, "unknown provenance '{value}'; must be ground-truth-ours | vendor-declared | authored-from-public-docs"),
            Self::UnknownTechnique(token) =>
                write!(f, "unknown technique token '{token}'; see SPEC §13.4 for the controlled vocabulary"),
            Self::EmptyTechniqueList { call_type } =>
                write!(f, "technique list is empty for call type '{call_type}'; MUST be a non-empty list"),
            Self::UnknownSchemaVersion(v) =>
                write!(f, "unrecognized manifest schema_version {v}; refusing (do not guess)"),
        }
    }
}

impl std::error::Error for ManifestValidationError {}

// ─────────────────────────────────────────────────────────────────────────────
// Controlled technique vocabulary (SPEC §13.4)
// ─────────────────────────────────────────────────────────────────────────────

/// The set of technique tokens in the controlled vocabulary.
/// Frozen to match Swift `TechniqueToken` CaseIterable exactly.
fn valid_technique_tokens() -> HashSet<&'static str> {
    [
        "bm25",
        "vector_cosine",
        "vector_hnsw",
        "rrf",
        "mmr",
        "graph_traversal",
        "llm_extraction",
        "embedding",
        "none",
        "unknown",
    ]
    .into_iter()
    .collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// Provenance (SPEC §13.2)
// ─────────────────────────────────────────────────────────────────────────────

/// How a manifest's contents were obtained. Mirrors Swift `ManifestProvenance`.
#[derive(Debug, Clone, PartialEq)]
pub enum ManifestProvenance {
    /// Authored by us for a product whose internals we know.
    GroundTruthOurs,
    /// Supplied by the product's vendor. Authoritative as a claim.
    VendorDeclared,
    /// Reverse-engineered from the product's public docs. Best-effort.
    AuthoredFromPublicDocs,
}

impl ManifestProvenance {
    fn from_str(s: &str) -> Option<Self> {
        match s {
            "ground-truth-ours"          => Some(Self::GroundTruthOurs),
            "vendor-declared"            => Some(Self::VendorDeclared),
            "authored-from-public-docs"  => Some(Self::AuthoredFromPublicDocs),
            _                            => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::GroundTruthOurs         => "ground-truth-ours",
            Self::VendorDeclared          => "vendor-declared",
            Self::AuthoredFromPublicDocs  => "authored-from-public-docs",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Transport (mirrors EndpointConfig.Transport in Config.swift)
// ─────────────────────────────────────────────────────────────────────────────

/// Transport variant decoded from the manifest's `transport` object.
#[derive(Debug, Clone, PartialEq)]
pub enum Transport {
    Stdio { command: String },
    Sse { url: String },
}

// ─────────────────────────────────────────────────────────────────────────────
// Result format (mirrors ResultFormat in Config.swift)
// ─────────────────────────────────────────────────────────────────────────────

/// How a tool's response is shaped. Mirrors Swift `ResultFormat`.
#[derive(Debug, Clone, PartialEq)]
pub enum ResultFormat {
    /// JSON objects with named id/content fields.
    JsonObjects { id_key: Option<String>, content_key: String },
    /// MOOTx01 plain-text results.
    MootText,
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-call-type entry (SPEC §13.3)
// ─────────────────────────────────────────────────────────────────────────────

/// Decoded, validated per-call-type entry. Mirrors Swift `ManifestCallEntry`.
#[derive(Debug, Clone)]
pub struct ManifestCallEntry {
    pub call_type: String,
    /// The foreign product's own tool name.
    pub tool: String,
    /// Argument role → this tool's argument key mapping.
    pub args: HashMap<String, String>,
    /// Fixed arguments every call sends (may be empty).
    pub constant_args: HashMap<String, String>,
    /// How the tool's response is shaped.
    pub result: ResultFormat,
    /// The mathematical technique(s) this call exercises (controlled vocabulary).
    pub technique: Vec<String>,
    /// True when this call type has no equivalent on the other side.
    pub unmatched: bool,
    /// Optional pagination info (for list-type calls).
    pub pagination: Option<PaginationConfig>,
}

#[derive(Debug, Clone)]
pub struct PaginationConfig {
    pub limit_arg: String,
    pub offset_arg: String,
    pub page_size: u32,
}

// ─────────────────────────────────────────────────────────────────────────────
// Dispatch table entry (startup-resolved; startup-only cost)
// ─────────────────────────────────────────────────────────────────────────────

/// One entry in the startup-resolved dispatch table. Pre-compiled so the timed
/// window pays zero cost (SPEC §13.5). Mirrors Swift `DispatchEntry`.
#[derive(Debug, Clone)]
pub struct DispatchEntry {
    /// The foreign product's tool name.
    pub tool_name: String,
    /// Pre-compiled constant args.
    pub constant_args: HashMap<String, String>,
    /// Argument role → argument key mapping.
    pub arg_mapping: HashMap<String, String>,
    /// The pre-resolved result format.
    pub result_format: ResultFormat,
    /// The pre-resolved technique tag(s).
    pub technique: Vec<String>,
    /// True when this call type has no equivalent on the other side.
    pub unmatched: bool,
    /// The manifest provenance, surfaced next to technique-attributed numbers.
    pub provenance: ManifestProvenance,
}

/// The in-memory dispatch table resolved once at startup.
/// Keys are call-type names (e.g. "write", "query", "think").
pub type ManifestDispatchTable = HashMap<String, DispatchEntry>;

// ─────────────────────────────────────────────────────────────────────────────
// Product identity (SPEC §13)
// ─────────────────────────────────────────────────────────────────────────────

/// Decoded product identity. Mirrors Swift `ManifestProduct`.
#[derive(Debug, Clone)]
pub struct ManifestProduct {
    pub id: String,
    pub display_name: Option<String>,
    pub version: Option<String>,
    pub homepage: Option<String>,
    pub provenance: ManifestProvenance,
    pub provenance_note: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// CapabilityManifest — top-level decoded + validated type
// ─────────────────────────────────────────────────────────────────────────────

/// A decoded and validated capability manifest. Mirrors Swift `CapabilityManifest`.
#[derive(Debug)]
pub struct CapabilityManifest {
    pub schema_version: i64,
    pub product: ManifestProduct,
    pub transport: Transport,
    pub role: String,
    /// Per-call-type entries. Keyed by call type (e.g. "write", "query").
    pub calls: HashMap<String, ManifestCallEntry>,
}

/// The current recognized schema major version set.
/// Mirrors Swift `CapabilityManifest.recognizedMajorVersions`.
const RECOGNIZED_MAJOR_VERSIONS: &[i64] = &[1];

impl CapabilityManifest {
    /// Decodes and validates a manifest from raw JSON bytes.
    /// Returns `ManifestValidationError` on any validation failure.
    /// Mirrors Swift `CapabilityManifest.decode(from:)`.
    pub fn decode(data: &[u8]) -> Result<Self, ManifestValidationError> {
        let raw: RawManifest = serde_json::from_slice(data)
            .map_err(|_| ManifestValidationError::RequiredFieldMissing(
                "(JSON decode failed — malformed manifest)".to_string()
            ))?;

        // Schema-version gate (SPEC §13.7): refuse on unknown major version.
        if !RECOGNIZED_MAJOR_VERSIONS.contains(&raw.schema_version) {
            return Err(ManifestValidationError::UnknownSchemaVersion(raw.schema_version));
        }

        // Required product fields.
        if raw.product.id.is_empty() {
            return Err(ManifestValidationError::RequiredFieldMissing("product.id".to_string()));
        }

        // Provenance validation (SPEC §13.2).
        let provenance = ManifestProvenance::from_str(&raw.product.provenance)
            .ok_or_else(|| ManifestValidationError::UnknownProvenance(raw.product.provenance.clone()))?;

        // Transport.
        let transport = raw.transport.to_transport()?;

        // Role.
        let role = raw.role.unwrap_or_else(|| "both".to_string());

        // Calls: must have at least write + query (SPEC §13.7).
        let raw_calls = raw.calls.as_ref()
            .ok_or_else(|| ManifestValidationError::RequiredFieldMissing("calls.write".to_string()))?;

        // Check write exists (the write entry's tool may be None → skip, so
        // we check the key presence only, matching Swift's nil-tool skip).
        if !raw_calls.contains_key("write") {
            return Err(ManifestValidationError::RequiredFieldMissing("calls.write".to_string()));
        }
        if !raw_calls.contains_key("query") {
            return Err(ManifestValidationError::RequiredFieldMissing("calls.query".to_string()));
        }

        // Decode + validate each call entry.
        let valid_tokens = valid_technique_tokens();
        let mut calls: HashMap<String, ManifestCallEntry> = HashMap::new();
        for (call_type, raw_entry) in raw_calls {
            // Skip empty/placeholder entries (tool is None).
            if raw_entry.tool.is_none() {
                continue;
            }
            let entry = validate_call_entry(raw_entry, call_type, &valid_tokens)?;
            calls.insert(call_type.clone(), entry);
        }

        let product = ManifestProduct {
            id: raw.product.id,
            display_name: raw.product.display_name,
            version: raw.product.version,
            homepage: raw.product.homepage,
            provenance,
            provenance_note: raw.product.provenance_note,
        };

        Ok(CapabilityManifest {
            schema_version: raw.schema_version,
            product,
            transport,
            role,
            calls,
        })
    }

    /// Resolves the manifest into an in-memory dispatch table. Called once at
    /// startup. Mirrors Swift `CapabilityManifest.resolveDispatchTable()`.
    pub fn resolve_dispatch_table(&self) -> ManifestDispatchTable {
        let mut table = ManifestDispatchTable::new();
        for (call_type, entry) in &self.calls {
            let dispatch_entry = DispatchEntry {
                tool_name: entry.tool.clone(),
                constant_args: entry.constant_args.clone(),
                arg_mapping: entry.args.clone(),
                result_format: entry.result.clone(),
                technique: entry.technique.clone(),
                unmatched: entry.unmatched,
                provenance: self.product.provenance.clone(),
            };
            table.insert(call_type.clone(), dispatch_entry);
        }
        table
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private validation helper
// ─────────────────────────────────────────────────────────────────────────────

fn validate_call_entry(
    raw: &RawCallEntry,
    call_type: &str,
    valid_tokens: &HashSet<&'static str>,
) -> Result<ManifestCallEntry, ManifestValidationError> {
    // technique MUST be a non-empty list (SPEC §13.7).
    let techniques = raw.technique.as_ref()
        .filter(|t| !t.is_empty())
        .ok_or_else(|| ManifestValidationError::EmptyTechniqueList {
            call_type: call_type.to_string(),
        })?;

    // Each technique token must be in the controlled vocabulary (SPEC §13.4).
    for token in techniques {
        if !valid_tokens.contains(token.as_str()) {
            return Err(ManifestValidationError::UnknownTechnique(token.clone()));
        }
    }

    // Result format.
    let result_format = raw.result.to_result_format()?;

    // Pagination (optional).
    let pagination = raw.pagination.as_ref().map(|p| PaginationConfig {
        limit_arg: p.limit_arg.clone().unwrap_or_else(|| "limit".to_string()),
        offset_arg: p.offset_arg.clone().unwrap_or_else(|| "offset".to_string()),
        page_size: p.page_size.unwrap_or(100),
    });

    Ok(ManifestCallEntry {
        call_type: call_type.to_string(),
        tool: raw.tool.clone().unwrap_or_else(|| call_type.to_string()),
        args: raw.args.clone().unwrap_or_default(),
        constant_args: raw.constant_args.clone().unwrap_or_default(),
        result: result_format,
        technique: techniques.clone(),
        unmatched: raw.unmatched.unwrap_or(false),
        pagination,
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Raw JSON shapes (decode-only; startup cost)
// ─────────────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct RawManifest {
    schema_version: i64,
    product: RawProduct,
    transport: RawTransport,
    role: Option<String>,
    calls: Option<HashMap<String, RawCallEntry>>,
}

#[derive(Deserialize)]
struct RawProduct {
    id: String,
    #[serde(rename = "displayName")]
    display_name: Option<String>,
    version: Option<String>,
    homepage: Option<String>,
    provenance: String,
    #[serde(rename = "provenanceNote")]
    provenance_note: Option<String>,
}

#[derive(Deserialize)]
struct RawTransport {
    stdio: Option<RawStdio>,
    sse: Option<RawSse>,
}

#[derive(Deserialize)]
struct RawStdio {
    command: String,
}

#[derive(Deserialize)]
struct RawSse {
    url: String,
}

impl RawTransport {
    fn to_transport(&self) -> Result<Transport, ManifestValidationError> {
        if let Some(s) = &self.stdio {
            return Ok(Transport::Stdio { command: s.command.clone() });
        }
        if let Some(s) = &self.sse {
            return Ok(Transport::Sse { url: s.url.clone() });
        }
        Err(ManifestValidationError::RequiredFieldMissing("transport".to_string()))
    }
}

#[derive(Deserialize)]
struct RawCallEntry {
    tool: Option<String>,
    args: Option<HashMap<String, String>>,
    #[serde(rename = "constantArgs")]
    constant_args: Option<HashMap<String, String>>,
    result: RawResult,
    technique: Option<Vec<String>>,
    unmatched: Option<bool>,
    pagination: Option<RawPagination>,
}

#[derive(Deserialize)]
struct RawResult {
    kind: String,
    #[serde(rename = "idKey")]
    id_key: Option<String>,
    #[serde(rename = "contentKey")]
    content_key: Option<String>,
}

impl RawResult {
    fn to_result_format(&self) -> Result<ResultFormat, ManifestValidationError> {
        match self.kind.as_str() {
            "jsonObjects" => {
                let content_key = self.content_key.clone()
                    .ok_or_else(|| ManifestValidationError::RequiredFieldMissing(
                        "result.contentKey".to_string()
                    ))?;
                Ok(ResultFormat::JsonObjects {
                    id_key: self.id_key.clone(),
                    content_key,
                })
            }
            "mootText" => Ok(ResultFormat::MootText),
            other => Err(ManifestValidationError::RequiredFieldMissing(
                format!("result.kind={other}")
            )),
        }
    }
}

#[derive(Deserialize)]
struct RawPagination {
    #[serde(rename = "limitArg")]
    limit_arg: Option<String>,
    #[serde(rename = "offsetArg")]
    offset_arg: Option<String>,
    #[serde(rename = "pageSize")]
    page_size: Option<u32>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit tests (inline — structural smoke tests only; conformance tested in
// tests/conformance.rs via shared JSON vectors)
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal_manifest_json() -> &'static str {
        r#"{
            "schema_version": 1,
            "product": {
                "id": "test-product",
                "displayName": "Test Product",
                "provenance": "ground-truth-ours"
            },
            "transport": { "stdio": { "command": "test-server" } },
            "role": "both",
            "calls": {
                "write": {
                    "tool": "store_memory",
                    "args": { "content": "text" },
                    "constantArgs": {},
                    "result": { "kind": "jsonObjects", "idKey": "id", "contentKey": "text" },
                    "technique": ["embedding"]
                },
                "query": {
                    "tool": "search_memory",
                    "args": { "query": "q" },
                    "constantArgs": {},
                    "result": { "kind": "jsonObjects", "idKey": "id", "contentKey": "text" },
                    "technique": ["bm25", "vector_cosine", "rrf"]
                }
            }
        }"#
    }

    #[test]
    fn valid_minimal_manifest_decodes() {
        let m = CapabilityManifest::decode(minimal_manifest_json().as_bytes()).unwrap();
        assert_eq!(m.schema_version, 1);
        assert_eq!(m.product.id, "test-product");
        assert_eq!(m.product.provenance, ManifestProvenance::GroundTruthOurs);
        assert!(m.calls.contains_key("write"));
        assert!(m.calls.contains_key("query"));
    }

    #[test]
    fn unknown_schema_version_refused() {
        let json = minimal_manifest_json().replace(
            r#""schema_version": 1"#,
            r#""schema_version": 99"#,
        );
        let err = CapabilityManifest::decode(json.as_bytes()).unwrap_err();
        assert!(matches!(err, ManifestValidationError::UnknownSchemaVersion(99)));
    }

    #[test]
    fn unknown_provenance_refused() {
        let json = minimal_manifest_json().replace(
            r#""provenance": "ground-truth-ours""#,
            r#""provenance": "made-up-value""#,
        );
        let err = CapabilityManifest::decode(json.as_bytes()).unwrap_err();
        assert!(matches!(err, ManifestValidationError::UnknownProvenance(_)));
    }

    #[test]
    fn unknown_technique_refused() {
        let json = minimal_manifest_json().replace(
            r#""technique": ["bm25", "vector_cosine", "rrf"]"#,
            r#""technique": ["not-a-technique"]"#,
        );
        let err = CapabilityManifest::decode(json.as_bytes()).unwrap_err();
        assert!(matches!(err, ManifestValidationError::UnknownTechnique(_)));
    }

    #[test]
    fn empty_technique_refused() {
        let json = minimal_manifest_json().replace(
            r#""technique": ["bm25", "vector_cosine", "rrf"]"#,
            r#""technique": []"#,
        );
        let err = CapabilityManifest::decode(json.as_bytes()).unwrap_err();
        assert!(matches!(err, ManifestValidationError::EmptyTechniqueList { .. }));
    }

    #[test]
    fn dispatch_table_carries_pre_resolved_fields() {
        let m = CapabilityManifest::decode(minimal_manifest_json().as_bytes()).unwrap();
        let table = m.resolve_dispatch_table();
        let write_entry = table.get("write").unwrap();
        assert_eq!(write_entry.tool_name, "store_memory");
        assert_eq!(write_entry.technique, vec!["embedding"]);
        assert!(!write_entry.unmatched);
        assert_eq!(write_entry.provenance, ManifestProvenance::GroundTruthOurs);
    }

    #[test]
    fn query_entry_multi_technique() {
        let m = CapabilityManifest::decode(minimal_manifest_json().as_bytes()).unwrap();
        let table = m.resolve_dispatch_table();
        let q = table.get("query").unwrap();
        assert_eq!(q.technique, vec!["bm25", "vector_cosine", "rrf"]);
    }
}
