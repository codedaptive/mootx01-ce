//! config.rs — the bridge's JSON config schema and loader (Rust twin).
//!
//! Wire-identical to the Swift `Config.swift`: two NAMED backends (`backendA`,
//! `backendB`) plus `primary` naming which starts as primary; each backend has a
//! `verbMap` naming its write/query tools, the argument keys, the constant
//! write-context, and the result format. The bridge is engine-agnostic — the
//! verbMap is the decoupling layer so the bridge is never hardcoded to MemPalace's
//! or mootx01's tool names.
//!
//! Zero external deps beyond serde/serde_json (the MOOTx01 standard). Defaults on
//! the optional fields match the mootx01 write case so a terse config still runs.

use serde::Deserialize;
use std::collections::BTreeMap;
use std::fmt;

/// Errors surfaced while loading or validating a bridge config.
#[derive(Debug, PartialEq, Eq)]
pub enum ConfigError {
    /// A required field was absent. Carries the dotted path (e.g. `verbMap.write`).
    MissingField(String),
    /// `primary` named no configured backend.
    UnknownPrimary(String),
    /// The config file could not be read or parsed.
    Parse(String),
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConfigError::MissingField(p) => write!(f, "config: missing required field {p}"),
            ConfigError::UnknownPrimary(n) => {
                write!(f, "config: primary=\"{n}\" names no configured backend")
            }
            ConfigError::Parse(e) => write!(f, "config: parse error: {e}"),
        }
    }
}

impl std::error::Error for ConfigError {}

/// How a server encodes the result of a tool call. Mirrors the Swift
/// `ResultFormat`. `jsonObjects` carries an optional `idKey` (nil when the server
/// returns no stable id, e.g. MemPalace search) and a `contentKey`; `mootText` is
/// mootx01's plain-text result shape.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Default)]
#[serde(tag = "kind")]
pub enum ResultFormat {
    #[serde(rename = "jsonObjects")]
    JsonObjects {
        #[serde(rename = "idKey", default)]
        id_key: Option<String>,
        #[serde(rename = "contentKey")]
        content_key: String,
    },
    // Default mirrors the Swift VerbMap default (mootText is the mootx01 case).
    #[default]
    #[serde(rename = "mootText")]
    MootText,
}

/// Maps the bridge's two verbs (write, query) onto one backend's MCP tool names,
/// argument keys, and the constant write-context that backend requires.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct VerbMap {
    /// This server's "store an entry" tool (write-classified).
    pub write: String,
    /// This server's "search/recall" tool (query-classified).
    pub query: String,
    /// The argument key under which `write` receives the entry content.
    #[serde(rename = "contentArg", default = "default_content_arg")]
    pub content_arg: String,
    /// The argument key under which `query` receives the search text.
    #[serde(rename = "queryArg", default = "default_query_arg")]
    pub query_arg: String,
    /// Constant arguments every write call sends in addition to the content
    /// (mootx01 `location`; MemPalace `wing`+`room`). A map covers both without a
    /// per-server special case.
    #[serde(rename = "constantArgs", default = "default_constant_args")]
    pub constant_args: BTreeMap<String, String>,
    /// How this server encodes the result of `query` / `write`.
    #[serde(rename = "resultFormat", default)]
    pub result_format: ResultFormat,
}

fn default_content_arg() -> String {
    "content".to_string()
}
fn default_query_arg() -> String {
    "query".to_string()
}
fn default_constant_args() -> BTreeMap<String, String> {
    let mut m = BTreeMap::new();
    m.insert("location".to_string(), "bridge/mirror".to_string());
    m
}

/// One MCP backend the bridge fans out to. `command` is the full stdio launch
/// command (an env-var prefix is honored, e.g.
/// `MOOTX01_DATA_DIR=/tmp/x mootx01 serve`). Treated at CLI-argument trust level.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct BackendConfig {
    pub name: String,
    pub command: String,
    #[serde(rename = "verbMap")]
    pub verb_map: VerbMap,
}

/// Top-level bridge config: two named backends and which starts as primary.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct BridgeConfig {
    #[serde(rename = "backendA")]
    pub backend_a: BackendConfig,
    #[serde(rename = "backendB")]
    pub backend_b: BackendConfig,
    /// The `name` of the backend that starts as primary. Must equal one of the
    /// backend names, else `ConfigError::UnknownPrimary`.
    pub primary: String,
}

impl BridgeConfig {
    /// Decodes config.json from a string, then validates that `primary` names a
    /// real backend and both required verbs are present (serde enforces the
    /// latter via the non-`Option` `write`/`query` fields; a missing one yields a
    /// parse error that we map to `MissingField`).
    pub fn parse_str(s: &str) -> Result<BridgeConfig, ConfigError> {
        let config: BridgeConfig = serde_json::from_str(s).map_err(|e| {
            let msg = e.to_string();
            // Map serde's "missing field `write`" into our MissingField variant so
            // the error matches the Swift loader's diagnostic shape.
            if let Some(field) = missing_field_name(&msg) {
                ConfigError::MissingField(field)
            } else {
                ConfigError::Parse(msg)
            }
        })?;
        if config.primary != config.backend_a.name && config.primary != config.backend_b.name {
            return Err(ConfigError::UnknownPrimary(config.primary));
        }
        Ok(config)
    }

    /// Loads + validates config.json from a path.
    pub fn load(path: &str) -> Result<BridgeConfig, ConfigError> {
        let data = std::fs::read_to_string(path)
            .map_err(|e| ConfigError::Parse(format!("read {path}: {e}")))?;
        BridgeConfig::parse_str(&data)
    }
}

/// Extracts the field name from a serde "missing field `x`" message, prefixing
/// `verbMap.` for the two required verbs so the path matches the Swift loader.
fn missing_field_name(msg: &str) -> Option<String> {
    let marker = "missing field `";
    let start = msg.find(marker)? + marker.len();
    let rest = &msg[start..];
    let end = rest.find('`')?;
    let field = &rest[..end];
    if field == "write" || field == "query" {
        Some(format!("verbMap.{field}"))
    } else {
        Some(field.to_string())
    }
}
