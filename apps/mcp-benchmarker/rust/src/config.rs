//! config.rs — JSON config schema and loader.
//!
//! Ports `Config.swift` exactly. The benchmarker is engine-agnostic: it talks
//! to two MCP servers whose tool names it does not know in advance. The
//! `verb_map` on each endpoint is the decoupling layer — it names which of
//! THIS server's MCP tools mean write / query / list, so the tool is never
//! hardcoded to MemPalace's or MOOTx01's specific tool names.
//!
//! Config is JSON. The custom decode below reproduces the Swift `VerbMap`
//! decoder bit for bit:
//!   - an absent required verb (`write`/`query`) surfaces as
//!     [`ConfigError::MissingField`] with a dotted path, at load time, not at
//!     first use;
//!   - the argument-key and result-format fields default when absent, so a
//!     terse config still decodes and runs against the MOOTx01/MemPalace
//!     defaults.

use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

/// Errors surfaced while loading or validating a benchmarker config.
/// Mirrors Swift `ConfigError`. `MissingField` carries the dotted path of the
/// absent required field (e.g. `verbMap.write`) so failures are diagnosable at
/// load time.
#[derive(Debug, PartialEq, Eq)]
pub enum ConfigError {
    MissingField(String),
    InvalidTransport,
    /// JSON that does not parse at all (malformed file). Distinct from a
    /// missing field; the Swift leg propagates the underlying decode error,
    /// but for parity all callers only ever match on the variant.
    Malformed(String),
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingField(field) => write!(f, "missing field: {field}"),
            Self::InvalidTransport => write!(f, "invalid transport"),
            Self::Malformed(msg) => write!(f, "malformed config: {msg}"),
        }
    }
}

impl std::error::Error for ConfigError {}

// ─────────────────────────────────────────────────────────────────────────────
// AuthConfig
// ─────────────────────────────────────────────────────────────────────────────

/// Optional authentication for a remote endpoint. Mirrors Swift `AuthConfig`.
///
/// `header` has a dual role: when absent the token is sent as
/// `Authorization: Bearer <token>`; when present the token is sent verbatim
/// (no `Bearer` prefix) under the named header.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct AuthConfig {
    pub token: Option<String>,
    pub header: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// ResultFormat
// ─────────────────────────────────────────────────────────────────────────────

/// How a server encodes the result of a tool call. Mirrors Swift `ResultFormat`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResultFormat {
    /// JSON objects; `id_key` names the id field (None when the server returns
    /// no stable id, e.g. MemPalace search), `content_key` names the content.
    JsonObjects {
        id_key: Option<String>,
        content_key: String,
    },
    /// MOOTx01 plain-text results (`found N` lines for search,
    /// `filed memory <UUID>` for write).
    MootText,
}

impl ResultFormat {
    /// The default result format: `jsonObjects` with `id`/`content` keys —
    /// the conventional shape assumed before live shapes were known. Mirrors
    /// the Swift `VerbMap` default.
    pub fn default_format() -> ResultFormat {
        ResultFormat::JsonObjects {
            id_key: Some("id".to_string()),
            content_key: "content".to_string(),
        }
    }

    /// Decodes a `ResultFormat` from a JSON object `{ "kind": ..., ... }`.
    /// Mirrors Swift `ResultFormat.init(from:)`.
    fn from_value(v: &Value) -> Result<ResultFormat, ConfigError> {
        let kind = v
            .get("kind")
            .and_then(Value::as_str)
            .ok_or_else(|| ConfigError::MissingField("resultFormat.kind".to_string()))?;
        match kind {
            "jsonObjects" => {
                let id_key = v
                    .get("idKey")
                    .and_then(Value::as_str)
                    .map(str::to_string);
                // contentKey is required for jsonObjects — without it the
                // transfer engine cannot read an item's content.
                let content_key = v
                    .get("contentKey")
                    .and_then(Value::as_str)
                    .ok_or_else(|| ConfigError::MissingField("resultFormat.contentKey".to_string()))?
                    .to_string();
                Ok(ResultFormat::JsonObjects { id_key, content_key })
            }
            "mootText" => Ok(ResultFormat::MootText),
            other => Err(ConfigError::MissingField(format!("resultFormat.kind={other}"))),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Transport
// ─────────────────────────────────────────────────────────────────────────────

/// How the tool reaches a server. Mirrors Swift `EndpointConfig.Transport`.
/// Encoded as a single-key object — `{ "stdio": { "command": ... } }` or
/// `{ "sse": { "url": ... } }`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Transport {
    Stdio { command: String },
    Sse { url: String },
}

impl Transport {
    fn from_value(v: &Value) -> Result<Transport, ConfigError> {
        if let Some(s) = v.get("stdio") {
            let command = s
                .get("command")
                .and_then(Value::as_str)
                .ok_or(ConfigError::InvalidTransport)?
                .to_string();
            return Ok(Transport::Stdio { command });
        }
        if let Some(s) = v.get("sse") {
            let url = s
                .get("url")
                .and_then(Value::as_str)
                .ok_or(ConfigError::InvalidTransport)?
                .to_string();
            return Ok(Transport::Sse { url });
        }
        Err(ConfigError::InvalidTransport)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// EndpointRole
// ─────────────────────────────────────────────────────────────────────────────

/// The role an endpoint plays. Mirrors Swift `EndpointConfig.EndpointRole`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndpointRole {
    Source,
    Target,
    Both,
}

impl EndpointRole {
    fn from_str(s: &str) -> Option<EndpointRole> {
        match s {
            "source" => Some(EndpointRole::Source),
            "target" => Some(EndpointRole::Target),
            "both" => Some(EndpointRole::Both),
            _ => None,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VerbMap
// ─────────────────────────────────────────────────────────────────────────────

/// Maps the three benchmarker verbs onto this server's MCP tool names AND onto
/// the argument key names + result shape each verb uses. Mirrors Swift
/// `EndpointConfig.VerbMap`. `write` and `query` are required; `list` and
/// `fetch` are optional.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerbMap {
    pub write: String,
    pub query: String,
    pub list: Option<String>,
    pub fetch: Option<String>,

    pub content_arg: String,
    pub query_arg: String,
    pub fetch_id_arg: String,
    pub fetch_content_key: String,
    pub list_limit_arg: String,
    pub list_offset_arg: String,
    pub list_page_size: i64,
    /// Constant args every write call sends in addition to the content.
    /// Stored in a `BTreeMap` for deterministic iteration order.
    pub constant_args: BTreeMap<String, String>,
    pub result_format: ResultFormat,
}

impl VerbMap {
    /// Constructs a VerbMap with the Swift default argument keys / format,
    /// overriding only what is supplied. Mirrors the Swift memberwise init
    /// with defaults — used by proxy/transfer tests.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        write: impl Into<String>,
        query: impl Into<String>,
        list: Option<String>,
        fetch: Option<String>,
        content_arg: Option<String>,
        query_arg: Option<String>,
        constant_args: Option<BTreeMap<String, String>>,
        result_format: Option<ResultFormat>,
    ) -> VerbMap {
        VerbMap {
            write: write.into(),
            query: query.into(),
            list,
            fetch,
            content_arg: content_arg.unwrap_or_else(|| "content".to_string()),
            query_arg: query_arg.unwrap_or_else(|| "query".to_string()),
            fetch_id_arg: "drawer_id".to_string(),
            fetch_content_key: "content".to_string(),
            list_limit_arg: "limit".to_string(),
            list_offset_arg: "offset".to_string(),
            list_page_size: 100,
            constant_args: constant_args.unwrap_or_else(default_constant_args),
            result_format: result_format.unwrap_or_else(ResultFormat::default_format),
        }
    }

    /// Decodes a VerbMap from its JSON object. Reproduces the Swift custom
    /// decoder: required `write`/`query` (else `MissingField`), everything else
    /// defaulted when absent.
    fn from_value(v: &Value) -> Result<VerbMap, ConfigError> {
        let obj = v
            .as_object()
            .ok_or_else(|| ConfigError::MissingField("verbMap.write".to_string()))?;

        let write = obj
            .get("write")
            .and_then(Value::as_str)
            .ok_or_else(|| ConfigError::MissingField("verbMap.write".to_string()))?
            .to_string();
        let query = obj
            .get("query")
            .and_then(Value::as_str)
            .ok_or_else(|| ConfigError::MissingField("verbMap.query".to_string()))?
            .to_string();

        // `list`/`fetch`: present-and-string → Some; present-and-null or absent
        // → None. Matches Swift `decodeIfPresent`.
        let opt_str = |key: &str| obj.get(key).and_then(Value::as_str).map(str::to_string);

        let str_or = |key: &str, default: &str| {
            obj.get(key)
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_else(|| default.to_string())
        };

        let list_page_size = obj
            .get("listPageSize")
            .and_then(Value::as_i64)
            .unwrap_or(100);

        // constantArgs defaults to the MOOTx01 import case when absent; an
        // explicit `{}` sends no constant write args; an explicit map is
        // taken verbatim.
        let constant_args = match obj.get("constantArgs") {
            Some(Value::Object(map)) => map
                .iter()
                .filter_map(|(k, val)| val.as_str().map(|s| (k.clone(), s.to_string())))
                .collect(),
            _ => default_constant_args(),
        };

        let result_format = match obj.get("resultFormat") {
            Some(rf) => ResultFormat::from_value(rf)?,
            None => ResultFormat::default_format(),
        };

        Ok(VerbMap {
            write,
            query,
            list: opt_str("list"),
            fetch: opt_str("fetch"),
            content_arg: str_or("contentArg", "content"),
            query_arg: str_or("queryArg", "query"),
            fetch_id_arg: str_or("fetchIDArg", "drawer_id"),
            fetch_content_key: str_or("fetchContentKey", "content"),
            list_limit_arg: str_or("listLimitArg", "limit"),
            list_offset_arg: str_or("listOffsetArg", "offset"),
            list_page_size,
            constant_args,
            result_format,
        })
    }
}

/// The default constant-args map: the MOOTx01 import case. Mirrors the Swift
/// `["location": "import/mempalace"]` default.
fn default_constant_args() -> BTreeMap<String, String> {
    let mut m = BTreeMap::new();
    m.insert("location".to_string(), "import/mempalace".to_string());
    m
}

// ─────────────────────────────────────────────────────────────────────────────
// EndpointConfig
// ─────────────────────────────────────────────────────────────────────────────

/// One MCP endpoint the benchmarker talks to. Mirrors Swift `EndpointConfig`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EndpointConfig {
    pub name: String,
    pub transport: Transport,
    pub auth: Option<AuthConfig>,
    pub verb_map: VerbMap,
    pub role: EndpointRole,
}

impl EndpointConfig {
    fn from_value(v: &Value) -> Result<EndpointConfig, ConfigError> {
        let name = v
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| ConfigError::MissingField("name".to_string()))?
            .to_string();
        let transport = Transport::from_value(
            v.get("transport").ok_or(ConfigError::InvalidTransport)?,
        )?;
        let auth = match v.get("auth") {
            Some(a) if !a.is_null() => Some(
                serde_json::from_value::<AuthConfig>(a.clone())
                    .map_err(|e| ConfigError::Malformed(e.to_string()))?,
            ),
            _ => None,
        };
        let verb_map = VerbMap::from_value(
            v.get("verbMap")
                .ok_or_else(|| ConfigError::MissingField("verbMap.write".to_string()))?,
        )?;
        let role = v
            .get("role")
            .and_then(Value::as_str)
            .and_then(EndpointRole::from_str)
            .ok_or_else(|| ConfigError::MissingField("role".to_string()))?;
        Ok(EndpointConfig {
            name,
            transport,
            auth,
            verb_map,
            role,
        })
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// BenchmarkerConfig
// ─────────────────────────────────────────────────────────────────────────────

/// Top-level config: the source and target endpoints. Mirrors Swift
/// `BenchmarkerConfig`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BenchmarkerConfig {
    pub source: EndpointConfig,
    pub target: EndpointConfig,
}

impl BenchmarkerConfig {
    /// Decodes config JSON bytes. Returns `ConfigError::MissingField` when a
    /// required verbMap entry is absent — caught at load, not at first use.
    /// Mirrors Swift `BenchmarkerConfig.load(from:)`.
    pub fn from_slice(data: &[u8]) -> Result<BenchmarkerConfig, ConfigError> {
        let v: Value = serde_json::from_slice(data)
            .map_err(|e| ConfigError::Malformed(e.to_string()))?;
        let source = EndpointConfig::from_value(
            v.get("source")
                .ok_or_else(|| ConfigError::MissingField("source".to_string()))?,
        )?;
        let target = EndpointConfig::from_value(
            v.get("target")
                .ok_or_else(|| ConfigError::MissingField("target".to_string()))?,
        )?;
        Ok(BenchmarkerConfig { source, target })
    }

    /// Loads + decodes config from a file path. Mirrors the file-loading half
    /// of Swift `BenchmarkerConfig.load(from:)`.
    pub fn load(path: &std::path::Path) -> Result<BenchmarkerConfig, ConfigError> {
        let data = std::fs::read(path).map_err(|e| ConfigError::Malformed(e.to_string()))?;
        Self::from_slice(&data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID: &str = r#"
    {
      "source": {
        "name": "mempalace",
        "transport": { "stdio": { "command": "mempalace-mcp" } },
        "verbMap": { "write": "store", "query": "search", "list": "list_all" },
        "role": "source"
      },
      "target": {
        "name": "mootx01",
        "transport": { "stdio": { "command": "aria-mcp" } },
        "verbMap": { "write": "capture", "query": "recall", "list": null },
        "role": "target"
      }
    }
    "#;

    #[test]
    fn valid_config_loads() {
        let cfg = BenchmarkerConfig::from_slice(VALID.as_bytes()).unwrap();
        assert_eq!(cfg.source.name, "mempalace");
        assert_eq!(cfg.target.name, "mootx01");
        assert_eq!(cfg.source.verb_map.write, "store");
        assert_eq!(cfg.target.verb_map.query, "recall");
        assert!(cfg.target.verb_map.list.is_none());
    }

    #[test]
    fn missing_write_verb_throws() {
        let bad = r#"
        {
          "source": {
            "name": "s", "transport": { "stdio": { "command": "x" } },
            "verbMap": { "query": "search", "list": "list_all" }, "role": "source"
          },
          "target": {
            "name": "t", "transport": { "stdio": { "command": "y" } },
            "verbMap": { "write": "capture", "query": "recall", "list": null }, "role": "target"
          }
        }
        "#;
        let err = BenchmarkerConfig::from_slice(bad.as_bytes()).unwrap_err();
        assert_eq!(err, ConfigError::MissingField("verbMap.write".to_string()));
    }

    #[test]
    fn source_and_target_distinct() {
        let cfg = BenchmarkerConfig::from_slice(VALID.as_bytes()).unwrap();
        assert_ne!(cfg.source.name, cfg.target.name);
        assert_ne!(cfg.source.role, cfg.target.role);
    }

    fn load_verb_map(verb_map_json: &str) -> VerbMap {
        let json = format!(
            r#"{{
              "source": {{
                "name": "s", "transport": {{ "stdio": {{ "command": "x" }} }},
                "verbMap": {verb_map_json}, "role": "source"
              }},
              "target": {{
                "name": "t", "transport": {{ "stdio": {{ "command": "y" }} }},
                "verbMap": {{ "write": "w", "query": "q", "list": null }}, "role": "target"
              }}
            }}"#
        );
        BenchmarkerConfig::from_slice(json.as_bytes())
            .unwrap()
            .source
            .verb_map
    }

    #[test]
    fn terse_verb_map_defaults_apply() {
        let vm = load_verb_map(r#"{ "write": "w", "query": "q", "list": "l" }"#);
        assert_eq!(vm.content_arg, "content");
        assert_eq!(vm.query_arg, "query");
        assert_eq!(
            vm.constant_args.get("location").map(|s| s.as_str()),
            Some("import/mempalace")
        );
        assert_eq!(vm.result_format, ResultFormat::default_format());
    }

    #[test]
    fn mempalace_format_decodes() {
        let vm = load_verb_map(
            r#"{
              "write": "mempalace_add_drawer",
              "query": "mempalace_search",
              "list": "mempalace_list_drawers",
              "resultFormat": { "kind": "jsonObjects", "idKey": "drawer_id", "contentKey": "content_preview" }
            }"#,
        );
        assert_eq!(vm.list.as_deref(), Some("mempalace_list_drawers"));
        assert_eq!(
            vm.result_format,
            ResultFormat::JsonObjects {
                id_key: Some("drawer_id".to_string()),
                content_key: "content_preview".to_string()
            }
        );
    }

    #[test]
    fn moot_text_format_decodes() {
        let vm = load_verb_map(
            r#"{
              "write": "moot_file_memory",
              "query": "moot_memory_search",
              "list": null,
              "constantArgs": { "location": "import/mempalace" },
              "resultFormat": { "kind": "mootText" }
            }"#,
        );
        assert_eq!(vm.write, "moot_file_memory");
        assert_eq!(vm.result_format, ResultFormat::MootText);
        assert_eq!(
            vm.constant_args.get("location").map(|s| s.as_str()),
            Some("import/mempalace")
        );
    }

    #[test]
    fn mempalace_two_constant_args() {
        let vm = load_verb_map(
            r#"{
              "write": "mempalace_add_drawer",
              "query": "mempalace_search",
              "list": "mempalace_list_drawers",
              "constantArgs": { "wing": "wing_import", "room": "general" }
            }"#,
        );
        assert_eq!(vm.constant_args.get("wing").map(|s| s.as_str()), Some("wing_import"));
        assert_eq!(vm.constant_args.get("room").map(|s| s.as_str()), Some("general"));
        assert_eq!(vm.constant_args.len(), 2);
    }

    #[test]
    fn explicit_empty_constant_args() {
        let vm = load_verb_map(r#"{ "write": "w", "query": "q", "list": "l", "constantArgs": {} }"#);
        assert!(vm.constant_args.is_empty());
    }
}
