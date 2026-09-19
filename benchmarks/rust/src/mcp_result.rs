//! mcp_result.rs — MCP tool-result parsing.
//!
//! Ports the result-parsing half of `MCPClient.swift` plus
//! `BenchmarkEngine.normalizedContentOrder`. These are the pure, deterministic
//! functions that turn an MCP tool result (a `content` array of typed blocks
//! and/or a `structuredContent` channel) into ordered items, according to the
//! endpoint's `ResultFormat`.
//!
//! Two shapes, exactly as the Swift leg:
//!   - `JsonObjects { id_key, content_key }`: items are JSON objects found in
//!     `structuredContent` first, else in the first `text` block parsed as
//!     JSON. Used by external servers (`list` → id/content; `search` → no id / `text`).
//!   - `MootText`: MOOTx01 plain text (ARIA_MCP_SPEC 2.0.0). A search result is
//!     `found N candidate memories, one per line` (singular: `found 1 candidate
//!     memory, one per line`) followed by one dense 6-column row per ranked
//!     hit; a write result is `filed memory <UUID>` (the assigned id).

use crate::config::ResultFormat;
use crate::json_value::JsonValue;

/// One parsed result item: its id (when the server returns one) and its content
/// (the searchable text). Both optional so a server that returns content
/// without a stable id (e.g. a search-only endpoint) and one that returns an id
/// without inline content both parse into the same shape. Mirrors Swift `MCPResultItem`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MCPResultItem {
    pub id: Option<String>,
    pub content: Option<String>,
}

/// A decoded refusal payload from an ARIA v2 tool-level error or a JSON-RPC
/// -32602 `invalid_argument` error. Mirrors Swift `MCPRefusalInfo`.
///
/// Catalog class codes (from `aria_v2_mission02_vectors.json`):
///   - `"memory_not_found"` — valid-format UUID that does not exist in the estate
///   - `"invalid_argument"` — malformed argument (-32602 carries this in error.data.code)
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MCPRefusalInfo {
    /// Catalog class code string, e.g. "memory_not_found" or "invalid_argument".
    pub code: String,
    /// Human-readable refusal reason from the server.
    pub message: String,
    /// Optional recovery hint (absent for memory_not_found).
    pub recovery: Option<String>,
    /// Whether the caller may retry with a different argument.
    pub retryable: Option<bool>,
    /// Argument path that failed (from -32602 error.data.path), when available.
    pub path: Option<String>,
    /// Allowed values (from -32602 error.data.allowed), when available. The server
    /// returns this as a JSON array of strings; mirrors Swift `MCPRefusalInfo.allowed: [String]?`.
    pub allowed: Option<Vec<String>>,
    /// Correction hint (from -32602 error.data.correction), when available.
    pub correction: Option<String>,
}

/// Decodes the typed refusal payload from a JSON-RPC `error` object.
///
/// Takes the full `error` object (with `code`, `message`, and `data` fields at the
/// JSON-RPC layer) and returns a typed `MCPRefusalInfo` when:
///   - `error.code` equals `-32602` (invalid_argument), and
///   - `error.data` carries the ARIA v2 invalid_argument shape: `{ code, message, path, allowed, correction }`.
///
/// Returns `None` for non-32602 errors or when `error.data` is absent.
///
/// This is the machine-readable decoder path. The `MCPError.description` string names the
/// error in prose for human readability; this function provides the typed path for callers
/// that need to inspect `path`, `allowed`, or `correction` programmatically.
///
/// Used by `MCPClient::call_tool_with_refusal` to surface the full error contract.
pub fn decode_jsonrpc_refusal(error_obj: &JsonValue) -> Option<MCPRefusalInfo> {
    // Only decode -32602 (invalid_argument) errors.
    let code = match error_obj.get("code") {
        Some(JsonValue::Number(n)) => *n as i64,
        _ => return None,
    };
    if code != -32602 {
        return None;
    }
    let data = error_obj.get("data")?;
    let refusal_code = data
        .get("code")
        .and_then(JsonValue::string_value)
        .unwrap_or("invalid_argument");
    let message = data
        .get("message")
        .and_then(JsonValue::string_value)
        .or_else(|| error_obj.get("message").and_then(JsonValue::string_value))
        .unwrap_or("invalid argument");
    let path = data
        .get("path")
        .and_then(JsonValue::string_value)
        .map(str::to_string);
    // The server returns `allowed` as a JSON array of strings; collect them in order.
    let allowed: Option<Vec<String>> = match data.get("allowed") {
        Some(JsonValue::Array(arr)) => {
            Some(arr.iter().filter_map(JsonValue::string_value).map(str::to_string).collect())
        }
        _ => None,
    };
    let correction = data
        .get("correction")
        .and_then(JsonValue::string_value)
        .map(str::to_string);
    Some(MCPRefusalInfo {
        code: refusal_code.to_string(),
        message: message.to_string(),
        recovery: None,
        retryable: None,
        path,
        allowed,
        correction,
    })
}

/// One entry from the v2 `moot_drain_status` structured response.
/// Decoded from `structuredContent.data.drains[]`. Mirrors Swift `V2DrainEntry`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct V2DrainEntry {
    /// Lane identifier, e.g. "corpus_encode", "dreaming", "subject_backfill".
    pub name: String,
    /// State word from the server: "idle" or "draining".
    pub state: String,
    /// Jobs waiting to start. > 0 means the lane has outstanding work.
    pub pending: i64,
}

/// The parsed result of one tool call. Mirrors Swift `MCPToolResult`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MCPToolResult {
    /// Result item IDs in the order the server returned them.
    pub ordered_ids: Vec<String>,
    /// The parsed result items, in order.
    pub items: Vec<MCPResultItem>,
    /// The id the target assigned to a just-written entry (MOOTx01
    /// `filed memory <UUID>`). None for query/list results.
    pub write_assigned_id: Option<String>,
    /// Raw text content blocks, concatenated in order.
    pub text_blocks: Vec<String>,
    /// True when the server flagged this result as a TOOL-LEVEL error
    /// (`isError: true` in the tools/call result). Central defect fix:
    /// the prior struct lacked this field, causing refused retrievals to
    /// decode as empty successes with exit 0.
    pub is_error: bool,
    /// Decoded refusal payload when `is_error` is true and
    /// `structuredContent.error` carried a recognised v2 refusal shape.
    pub refusal: Option<MCPRefusalInfo>,
    /// The `structuredContent.meta.withheldBySensitivity` count. Emitted
    /// only when the `report_withheld` global modifier was passed; absent
    /// meta or absent key decode gracefully as None.
    pub withheld_by_sensitivity: Option<i64>,
    /// Drawer count confirmed by `moot_json_import`, decoded from
    /// `structuredContent.data.drawers_written`. None for all other operations.
    /// Use this instead of parsing the text block — the v2 surface embeds
    /// the count in structured data only.
    pub drawers_written: Option<i64>,
    /// Drain lane entries from `moot_drain_status`, decoded from
    /// `structuredContent.data.drains[]`. None for all other operations.
    pub drain_entries: Option<Vec<V2DrainEntry>>,
    /// Operation completion status from `structuredContent.meta.status`.
    /// "completed" means the dreaming cycle (or other write op) finished.
    pub meta_status: Option<String>,
}

impl Default for MCPToolResult {
    fn default() -> Self {
        MCPToolResult {
            ordered_ids: vec![],
            items: vec![],
            write_assigned_id: None,
            text_blocks: vec![],
            is_error: false,
            refusal: None,
            withheld_by_sensitivity: None,
            drawers_written: None,
            drain_entries: None,
            meta_status: None,
        }
    }
}

/// Parses an MCP tool result into ordered items according to `format`.
/// Mirrors Swift `MCPClient.parseToolResult`.
///
/// MCP tool results carry a `content` array of typed blocks. The shape of the
/// payload inside is server-specific, so the endpoint's verbMap names it
/// (`ResultFormat`) rather than the parser guessing.
pub fn parse_tool_result(result: &JsonValue, format: &ResultFormat) -> MCPToolResult {
    let mut text_blocks: Vec<String> = Vec::new();
    if let Some(JsonValue::Array(blocks)) = result.get("content") {
        for block in blocks {
            if block.get("type").and_then(JsonValue::string_value) == Some("text") {
                if let Some(text) = block.get("text").and_then(JsonValue::string_value) {
                    text_blocks.push(text.to_string());
                }
            }
        }
    }

    // Tool-level error flag (MCP tools/call `isError`). Central defect: prior
    // struct lacked is_error so a refused retrieval was decoded as a normal
    // empty-result success. Now read and propagate on every path.
    let is_error = matches!(result.get("isError"), Some(JsonValue::Bool(true)));

    // Decode structuredContent.error when is_error — ARIA v2 tool-level refusals
    // carry { code, message, recovery (opt), retryable (opt) }.
    let refusal: Option<MCPRefusalInfo> = if is_error {
        result
            .get("structuredContent")
            .and_then(|sc| sc.get("error"))
            .and_then(|err| err.get("code").and_then(JsonValue::string_value))
            .map(|code| {
                let err = result
                    .get("structuredContent")
                    .and_then(|sc| sc.get("error"))
                    .unwrap(); // safe: code was Some
                MCPRefusalInfo {
                    code: code.to_string(),
                    message: err
                        .get("message")
                        .and_then(JsonValue::string_value)
                        .unwrap_or(code)
                        .to_string(),
                    recovery: err
                        .get("recovery")
                        .and_then(JsonValue::string_value)
                        .map(str::to_string),
                    retryable: match err.get("retryable") {
                        Some(JsonValue::Bool(b)) => Some(*b),
                        _ => None,
                    },
                    path: None,
                    allowed: None,
                    correction: None,
                }
            })
    } else {
        None
    };

    let mut parsed = match format {
        ResultFormat::JsonObjects { id_key, content_key } => {
            parse_json_objects(result, text_blocks, id_key.as_deref(), content_key)
        }
        ResultFormat::MootText => parse_moot_text(text_blocks),
        ResultFormat::MootV2 => parse_moot_v2(result, text_blocks),
    };
    parsed.is_error = is_error;
    parsed.refusal = refusal;
    parsed
}

/// Parses ARIA v2 structured results from the `structuredContent.data` envelope.
/// Mirrors Swift `MCPClient.parseMootV2`.
///
/// Three shapes, all behind the same envelope:
///   - Write receipt: `data.memory_id` (bare string) → write_assigned_id
///   - Search / list: `data.results[].{memory_id, excerpt}` or `data.memories[].{memory_id, content}`
///   - Recall lenses: `data.results[].{id, bestSpan}` (uses `id` not `memory_id`)
///
/// Always preserves text_blocks so `discrimination: low` detection continues to work.
fn parse_moot_v2(result: &JsonValue, text_blocks: Vec<String>) -> MCPToolResult {
    let mut items: Vec<MCPResultItem> = Vec::new();
    let mut write_assigned_id: Option<String> = None;

    // Reach into structuredContent; return early with just text blocks if absent.
    let structured = match result.get("structuredContent") {
        Some(sc) => sc,
        None => {
            return MCPToolResult {
                text_blocks,
                ..MCPToolResult::default()
            }
        }
    };

    // structuredContent.meta fields — decoded before the data guard so they
    // are available on the data-absent early return path.
    //
    // withheldBySensitivity: emitted only when report_withheld is passed.
    let withheld_by_sensitivity: Option<i64> = structured
        .get("meta")
        .and_then(|meta| meta.get("withheldBySensitivity"))
        .and_then(|v| if let JsonValue::Number(n) = v { Some(*n as i64) } else { None });

    // meta.status: operation completion signal ("completed" when the op finished).
    // moot_dream sets this; other write ops may set it too.
    let meta_status: Option<String> = structured
        .get("meta")
        .and_then(|meta| meta.get("status"))
        .and_then(JsonValue::string_value)
        .map(str::to_string);

    // Reach into structuredContent.data
    let data = match structured.get("data") {
        Some(d) => d,
        None => {
            return MCPToolResult {
                text_blocks,
                withheld_by_sensitivity,
                meta_status,
                ..MCPToolResult::default()
            }
        }
    };

    // moot_json_import write receipt: data.drawers_written is the confirmed count.
    // The v2 surface puts the count in structured data only — not in text.
    let drawers_written: Option<i64> = data
        .get("drawers_written")
        .and_then(|v| if let JsonValue::Number(n) = v { Some(*n as i64) } else { None });

    // moot_drain_status: data.drains[] carries per-lane drain state.
    // Each entry: { name: String, state: "idle"|"draining", pending: Number }.
    let drain_entries: Option<Vec<V2DrainEntry>> = data.get("drains").and_then(|v| {
        if let JsonValue::Array(arr) = v {
            let entries: Vec<V2DrainEntry> = arr
                .iter()
                .filter_map(|entry| {
                    let name = entry.get("name").and_then(JsonValue::string_value)?.to_string();
                    let state = entry.get("state").and_then(JsonValue::string_value)?.to_string();
                    let pending: i64 = entry
                        .get("pending")
                        .and_then(|p| if let JsonValue::Number(n) = p { Some(*n as i64) } else { None })
                        .unwrap_or(0);
                    Some(V2DrainEntry { name, state, pending })
                })
                .collect();
            Some(entries)
        } else {
            None
        }
    });

    // Write receipt: data.memory_id (bare string)
    if let Some(JsonValue::String(mid)) = data.get("memory_id") {
        write_assigned_id = Some(mid.clone());
    }

    // Search results: data.results[] with memory_id + excerpt
    // Recall lens results: data.results[] with id + bestSpan
    if let Some(JsonValue::Array(results)) = data.get("results") {
        for item in results {
            // memory_id takes precedence; recall lenses use `id`
            let id = item
                .get("memory_id")
                .and_then(JsonValue::string_value)
                .or_else(|| item.get("id").and_then(JsonValue::string_value))
                .map(str::to_string);
            // excerpt for search, bestSpan for recall lenses, subject as fallback
            let content = item
                .get("excerpt")
                .and_then(JsonValue::string_value)
                .or_else(|| item.get("bestSpan").and_then(JsonValue::string_value))
                .or_else(|| item.get("subject").and_then(JsonValue::string_value))
                .map(str::to_string);
            items.push(MCPResultItem { id, content });
        }
    }

    // Memory-get / memory-list: data.memories[]
    if let Some(JsonValue::Array(memories)) = data.get("memories") {
        for item in memories {
            let id = item
                .get("memory_id")
                .and_then(JsonValue::string_value)
                .map(str::to_string);
            let content = item
                .get("content")
                .and_then(JsonValue::string_value)
                .map(str::to_string);
            items.push(MCPResultItem { id, content });
        }
    }

    let ordered_ids: Vec<String> = items.iter().filter_map(|i| i.id.clone()).collect();
    MCPToolResult {
        ordered_ids,
        items,
        write_assigned_id,
        text_blocks,  // preserved for discrimination: low detection
        is_error: false,  // set by parse_tool_result caller
        refusal: None,    // set by parse_tool_result caller
        withheld_by_sensitivity,
        drawers_written,
        drain_entries,
        meta_status,
    }
}


/// Parses the `JsonObjects` shape. Looks for the item array in
/// `structuredContent` first (the structured channel), then in the first
/// `text` block parsed as JSON. Mirrors Swift `parseJSONObjects`.
fn parse_json_objects(
    result: &JsonValue,
    text_blocks: Vec<String>,
    id_key: Option<&str>,
    content_key: &str,
) -> MCPToolResult {
    let build = |objects: Vec<&JsonValue>, text_blocks: Vec<String>| -> MCPToolResult {
        let items: Vec<MCPResultItem> = objects
            .iter()
            .map(|obj| MCPResultItem {
                id: id_key.and_then(|k| obj.get(k).and_then(JsonValue::string_value).map(str::to_string)),
                content: obj
                    .get(content_key)
                    .and_then(JsonValue::string_value)
                    .map(str::to_string),
            })
            .collect();
        let ordered_ids = items.iter().filter_map(|i| i.id.clone()).collect();
        MCPToolResult {
            ordered_ids,
            items,
            write_assigned_id: None,
            text_blocks,
            is_error: false,
            refusal: None,
            withheld_by_sensitivity: None,
            drawers_written: None,
            drain_entries: None,
            meta_status: None,
        }
    };

    if let Some(structured) = result.get("structuredContent") {
        if let Some(objects) = object_array(structured, id_key, content_key) {
            return build(objects, text_blocks);
        }
    }
    for text in &text_blocks {
        if let Ok(parsed) = JsonValue::from_slice(text.as_bytes()) {
            if let Some(objects) = object_array(&parsed, id_key, content_key) {
                // `objects` borrows from `parsed`, which is local; build owned
                // items before `parsed` drops by collecting here.
                let items: Vec<MCPResultItem> = objects
                    .iter()
                    .map(|obj| MCPResultItem {
                        id: id_key
                            .and_then(|k| obj.get(k).and_then(JsonValue::string_value).map(str::to_string)),
                        content: obj
                            .get(content_key)
                            .and_then(JsonValue::string_value)
                            .map(str::to_string),
                    })
                    .collect();
                let ordered_ids = items.iter().filter_map(|i| i.id.clone()).collect();
                return MCPToolResult {
                    ordered_ids,
                    items,
                    write_assigned_id: None,
                    text_blocks,
                    is_error: false,
                    refusal: None,
                    withheld_by_sensitivity: None,
                    drawers_written: None,
                    drain_entries: None,
                    meta_status: None,
                };
            }
        }
    }
    MCPToolResult {
        ordered_ids: vec![],
        items: vec![],
        write_assigned_id: None,
        text_blocks,
        is_error: false,
        refusal: None,
        withheld_by_sensitivity: None,
        drawers_written: None,
        drain_entries: None,
        meta_status: None,
    }
}

/// Pulls the array of result objects out of a value that is either an array of
/// objects or an object holding such an array under a single array-valued key
/// (e.g. a `results` / `drawers` / `items` wrapper). An object is kept when it
/// carries the id key (if one is named) or the content key. Returns None when no
/// qualifying array is found. Mirrors Swift `objectArray`.
fn object_array<'a>(
    value: &'a JsonValue,
    id_key: Option<&str>,
    content_key: &str,
) -> Option<Vec<&'a JsonValue>> {
    let qualifying = |array: &'a [JsonValue]| -> Option<Vec<&'a JsonValue>> {
        let kept: Vec<&JsonValue> = array
            .iter()
            .filter(|obj| {
                let has_id = id_key
                    .map(|k| obj.get(k).and_then(JsonValue::string_value).is_some())
                    .unwrap_or(false);
                let has_content = obj.get(content_key).and_then(JsonValue::string_value).is_some();
                has_id || has_content
            })
            .collect();
        if kept.is_empty() {
            None
        } else {
            Some(kept)
        }
    };

    match value {
        JsonValue::Array(array) => qualifying(array),
        JsonValue::Object(obj) => {
            // Deterministic order so the first qualifying array is stable.
            // BTreeMap already iterates in sorted-key order, matching Swift's
            // `obj.keys.sorted()`.
            for (_key, member) in obj.iter() {
                if let JsonValue::Array(array) = member {
                    if let Some(kept) = qualifying(array) {
                        return Some(kept);
                    }
                }
            }
            // No qualifying nested array — is the object itself one record?
            // (A per-id fetch endpoint returns one bare object with full content.)
            let single = std::slice::from_ref(value);
            qualifying(single)
        }
        _ => None,
    }
}

/// Parses MOOTx01's plain-text results. Each line beginning with a UUID token
/// is one item: a canonical S1 candidate row (ARIA_MCP_SPEC 2.0.0 §11.2 —
/// `<UUID> · <subject> · <bestSpan> · <sscFacts> ·
/// <event_time> · <score>`, six fixed columns, `-` absence) or the
/// single-record shape (`<UUID>  [location]  <content>`) for a search hit,
/// and `filed memory <UUID>` for a write. Mirrors Swift `parseMootText`.
fn parse_moot_text(text_blocks: Vec<String>) -> MCPToolResult {
    let mut items: Vec<MCPResultItem> = Vec::new();
    let mut write_assigned_id: Option<String> = None;

    for block in &text_blocks {
        for raw_line in block.split('\n') {
            let line = raw_line.trim();
            if line.is_empty() {
                continue;
            }
            // Write response: `filed memory <UUID>`. Capture the first.
            if line.to_lowercase().starts_with("filed memory ") {
                // Drop the prefix using char-count, matching Swift's
                // dropFirst("filed memory ".count) on the original-case line.
                let token = &line["filed memory ".len()..];
                let token = token.trim();
                if let Some(uuid) = leading_uuid(token) {
                    if write_assigned_id.is_none() {
                        write_assigned_id = Some(uuid);
                    }
                }
                continue;
            }
            // Search hit: a line that starts with a UUID token.
            let uuid = match leading_uuid(line) {
                Some(u) => u,
                None => continue,
            };
            let content = moot_text_content(line, &uuid);
            items.push(MCPResultItem {
                id: Some(uuid),
                content,
            });
        }
    }

    let ordered_ids = items.iter().filter_map(|i| i.id.clone()).collect();
    MCPToolResult {
        ordered_ids,
        items,
        write_assigned_id,
        text_blocks,
        is_error: false,
        refusal: None,
        withheld_by_sensitivity: None,
        drawers_written: None,
        drain_entries: None,
        meta_status: None,
    }
}

/// The content of one MOOTx01 search-hit line.
///
/// A search reply arrives in the 2.0.0 dense-row shape
/// `<UUID> · <subject> · <bestSpan> · <sscFacts> · <eventTime> · <score>`,
/// where the SUBJECT (col 2) carries the record's text and the fields after it
/// are metadata. Only the subject is content for scoring purposes. Returning
/// the whole remainder made every gauntlet figure read zero on 2026-08-17: the
/// product returned the needle at rank 1, and the scorer — which identifies a
/// hit by comparing content — was handed the full metadata tail as well.
///
/// A line with no dense-row separator is the single-record shape, whose
/// content follows the `[location]` bracket when one is present. Mirrors Swift
/// `mootTextContent`.
fn moot_text_content(line: &str, uuid: &str) -> Option<String> {
    // space · space (U+00B7 MIDDLE DOT), the dense-row field separator.
    const SEPARATOR: &str = " \u{00B7} ";
    let parts: Vec<&str> = line.split(SEPARATOR).collect();
    if parts.len() > 1 {
        let subject = parts[1].trim();
        // The sentinels are read exactly as the dense-row parser reads them,
        // so the two agree on what counts as text.
        if subject == "(no subject)" || subject == "-" || subject.is_empty() {
            return None;
        }
        return Some(subject.to_string());
    }
    let after_uuid = line[uuid.len()..].trim();
    if let Some(close) = after_uuid.find(']') {
        return Some(after_uuid[close + 1..].trim().to_string());
    }
    Some(after_uuid.to_string())
}

/// Returns the leading whitespace-delimited token of `s` if it is a canonical
/// UUID (8-4-4-4-12 hex), else None. The check is case-insensitive so MOOTx01's
/// upper-case UUIDs parse. Mirrors Swift `leadingUUID`.
fn leading_uuid(s: &str) -> Option<String> {
    let token = s.split(' ').next()?;
    if is_uuid(token) {
        Some(token.to_string())
    } else {
        None
    }
}

/// Validates a canonical 8-4-4-4-12 hex UUID, case-insensitive. Reproduces the
/// acceptance criteria of Swift's `UUID(uuidString:)` for the format MOOTx01
/// emits (it accepts only the hyphenated 36-char form).
fn is_uuid(s: &str) -> bool {
    let groups = [8usize, 4, 4, 4, 12];
    let parts: Vec<&str> = s.split('-').collect();
    if parts.len() != groups.len() {
        return false;
    }
    for (part, &len) in parts.iter().zip(groups.iter()) {
        if part.len() != len || !part.bytes().all(|b| b.is_ascii_hexdigit()) {
            return false;
        }
    }
    true
}

/// Maps result items to a normalized content order for cross-server rank
/// comparison: trim + lowercase + collapse internal whitespace, bounded to a
/// 64-char prefix. Mirrors Swift `BenchmarkEngine.normalizedContentOrder`.
pub fn normalized_content_order(items: &[MCPResultItem]) -> Vec<String> {
    items
        .iter()
        .filter_map(|item| {
            let content = item.content.as_ref()?;
            let collapsed = content
                .to_lowercase()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            // Bound on a 64-char prefix so a server that truncates content
            // (e.g. a `content_preview` field) still matches the same item from a
            // server that returns it in full. Use char-boundary-safe truncation.
            Some(collapsed.chars().take(64).collect::<String>())
        })
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;

    /// Wraps a server's text payload in the MCP `content` text-block envelope.
    fn text_result(text: &str) -> JsonValue {
        JsonValue::object([(
            "content".to_string(),
            JsonValue::Array(vec![JsonValue::object([
                ("type".to_string(), JsonValue::String("text".to_string())),
                ("text".to_string(), JsonValue::String(text.to_string())),
            ])]),
        )])
    }

    #[test]
    fn external_list_drawers() {
        let payload = r#"
        {
          "drawers": [
            { "drawer_id": "d1", "wing": "w", "room": "r", "content_preview": "alpha content" },
            { "drawer_id": "d2", "wing": "w", "room": "r", "content_preview": "beta content" }
          ],
          "count": 2
        }
        "#;
        let result = parse_tool_result(
            &text_result(payload),
            &ResultFormat::JsonObjects {
                id_key: Some("drawer_id".to_string()),
                content_key: "content_preview".to_string(),
            },
        );
        assert_eq!(result.ordered_ids, vec!["d1", "d2"]);
        assert_eq!(
            result.items.iter().map(|i| i.content.clone()).collect::<Vec<_>>(),
            vec![Some("alpha content".to_string()), Some("beta content".to_string())]
        );
        assert!(result.write_assigned_id.is_none());
    }

    #[test]
    fn external_search_no_id() {
        let payload = r#"
        {
          "query": "q",
          "results": [
            { "text": "first hit", "wing": "w", "similarity": 0.9 },
            { "text": "second hit", "wing": "w", "similarity": 0.7 }
          ]
        }
        "#;
        let result = parse_tool_result(
            &text_result(payload),
            &ResultFormat::JsonObjects {
                id_key: None,
                content_key: "text".to_string(),
            },
        );
        assert!(result.ordered_ids.is_empty());
        assert_eq!(
            result.items.iter().map(|i| i.content.clone()).collect::<Vec<_>>(),
            vec![Some("first hit".to_string()), Some("second hit".to_string())]
        );
    }

    #[test]
    fn moot_write_assigned_id() {
        let payload = "filed memory 7CF35028-84BE-40D0-A8CB-7FCFE8EB6018\nroom: import/test\nlineage: 8D976526-1598-42CF-8257-E3233F414BA8";
        let result = parse_tool_result(&text_result(payload), &ResultFormat::MootText);
        // The assigned id is the filed-memory UUID, NOT the lineage UUID.
        assert_eq!(
            result.write_assigned_id.as_deref(),
            Some("7CF35028-84BE-40D0-A8CB-7FCFE8EB6018")
        );
    }

    #[test]
    fn moot_search_ranked() {
        let payload = "found 2 candidate memories, one per line\n7CF35028-84BE-40D0-A8CB-7FCFE8EB6018  [import/test]  The benchmarker measures mootx01 recall quality end to end.\n84B0178B-A133-4F43-91D0-2854E7AC45FB  [import/test]  Apple Silicon Metal kernel dispatch.";
        let result = parse_tool_result(&text_result(payload), &ResultFormat::MootText);
        assert_eq!(
            result.ordered_ids,
            vec![
                "7CF35028-84BE-40D0-A8CB-7FCFE8EB6018",
                "84B0178B-A133-4F43-91D0-2854E7AC45FB"
            ]
        );
        assert_eq!(
            result.items.first().and_then(|i| i.content.clone()),
            Some("The benchmarker measures mootx01 recall quality end to end.".to_string())
        );
        assert_eq!(result.items.len(), 2);
        assert!(result.write_assigned_id.is_none());
    }

    #[test]
    fn moot_search_no_bracket() {
        let payload =
            "found 1 candidate memory, one per line\n7CF35028-84BE-40D0-A8CB-7FCFE8EB6018  bare content with no bracket";
        let result = parse_tool_result(&text_result(payload), &ResultFormat::MootText);
        assert_eq!(
            result.items.first().and_then(|i| i.content.clone()),
            Some("bare content with no bracket".to_string())
        );
    }

    #[test]
    fn empty_results() {
        let json = parse_tool_result(
            &text_result("{}"),
            &ResultFormat::JsonObjects {
                id_key: Some("id".to_string()),
                content_key: "content".to_string(),
            },
        );
        assert!(json.items.is_empty());
        let moot = parse_tool_result(&text_result("found 0 candidate memories, one per line"), &ResultFormat::MootText);
        assert!(moot.items.is_empty());
        assert!(moot.write_assigned_id.is_none());
    }

    #[test]
    fn structured_content_preferred() {
        let result = JsonValue::object([
            (
                "structuredContent".to_string(),
                JsonValue::object([(
                    "results".to_string(),
                    JsonValue::Array(vec![JsonValue::object([
                        ("id".to_string(), JsonValue::String("s1".to_string())),
                        ("content".to_string(), JsonValue::String("c1".to_string())),
                    ])]),
                )]),
            ),
            (
                "content".to_string(),
                JsonValue::Array(vec![JsonValue::object([
                    ("type".to_string(), JsonValue::String("text".to_string())),
                    ("text".to_string(), JsonValue::String("ignored text block".to_string())),
                ])]),
            ),
        ]);
        let parsed = parse_tool_result(
            &result,
            &ResultFormat::JsonObjects {
                id_key: Some("id".to_string()),
                content_key: "content".to_string(),
            },
        );
        assert_eq!(parsed.ordered_ids, vec!["s1"]);
        assert_eq!(parsed.items.first().and_then(|i| i.content.clone()), Some("c1".to_string()));
    }

    #[test]
    fn single_record_fetch_object() {
        // A per-id fetch endpoint returns one bare object with full content.
        let payload = r#"{ "drawer_id": "d9", "content": "full content here", "wing": "w" }"#;
        let result = parse_tool_result(
            &text_result(payload),
            &ResultFormat::JsonObjects {
                id_key: Some("drawer_id".to_string()),
                content_key: "content".to_string(),
            },
        );
        assert_eq!(result.items.len(), 1);
        assert_eq!(result.items[0].content.as_deref(), Some("full content here"));
        assert_eq!(result.ordered_ids, vec!["d9"]);
    }

    #[test]
    fn normalization_collapses_and_bounds() {
        let items = vec![
            MCPResultItem { id: None, content: Some("  Alpha   BETA\n\tGamma  ".to_string()) },
            MCPResultItem { id: None, content: None }, // dropped
            MCPResultItem { id: None, content: Some("second".to_string()) },
        ];
        let order = normalized_content_order(&items);
        assert_eq!(order, vec!["alpha beta gamma", "second"]);
    }

    #[test]
    fn truncated_preview_matches_full_on_prefix() {
        let full = "x".repeat(100) + "TAIL";
        let preview = "x".repeat(80);
        let a = normalized_content_order(&[MCPResultItem { id: None, content: Some(full) }]);
        let b = normalized_content_order(&[MCPResultItem { id: None, content: Some(preview) }]);
        assert_eq!(a, b);
    }

    #[test]
    fn uuid_validation() {
        assert!(is_uuid("7CF35028-84BE-40D0-A8CB-7FCFE8EB6018"));
        assert!(is_uuid("7cf35028-84be-40d0-a8cb-7fcfe8eb6018"));
        assert!(!is_uuid("not-a-uuid"));
        assert!(!is_uuid("7CF35028-84BE-40D0-A8CB")); // too few groups
        assert!(!is_uuid("ZCF35028-84BE-40D0-A8CB-7FCFE8EB6018")); // non-hex
    }


    // ── Class A: drawers_written from structuredContent.data.drawers_written ──

    /// Helper: builds an MCP result with structuredContent.
    fn structured_result(sc: JsonValue) -> JsonValue {
        JsonValue::object([
            ("content".to_string(), JsonValue::Array(vec![
                JsonValue::object([
                    ("type".to_string(), JsonValue::String("text".to_string())),
                    ("text".to_string(), JsonValue::String("JSON seed import complete.".to_string())),
                ])
            ])),
            ("structuredContent".to_string(), sc),
        ])
    }

    #[test]
    fn v2_drawers_written_happy_path() {
        // structuredContent.data.drawers_written == 42; runner accepts.
        let sc = JsonValue::object([
            ("data".to_string(), JsonValue::object([
                ("drawers_written".to_string(), JsonValue::Number(42.0)),
                ("seed_name".to_string(), JsonValue::String("test_seed".to_string())),
            ])),
            ("meta".to_string(), JsonValue::object([
                ("status".to_string(), JsonValue::String("completed".to_string())),
            ])),
        ]);
        let result = parse_tool_result(&structured_result(sc), &ResultFormat::MootV2);
        assert_eq!(result.drawers_written, Some(42));
        assert_eq!(result.meta_status.as_deref(), Some("completed"));
    }

    #[test]
    fn v2_drawers_written_absent_structuredcontent_yields_none() {
        // No structuredContent → drawers_written is None; runner will reject.
        let result = parse_tool_result(
            &text_result("JSON seed import complete."),
            &ResultFormat::MootV2,
        );
        assert_eq!(result.drawers_written, None);
    }

    #[test]
    fn v2_drawers_written_count_mismatch_decoded_faithfully() {
        // Runner receives actual count (7), compares to expected (42), rejects.
        let sc = JsonValue::object([
            ("data".to_string(), JsonValue::object([
                ("drawers_written".to_string(), JsonValue::Number(7.0)),
            ])),
            ("meta".to_string(), JsonValue::object([
                ("status".to_string(), JsonValue::String("completed".to_string())),
            ])),
        ]);
        let result = parse_tool_result(&structured_result(sc), &ResultFormat::MootV2);
        assert_eq!(result.drawers_written, Some(7));
    }

    #[test]
    fn v2_meta_status_decoded_when_data_absent() {
        // data key missing but meta present — meta_status still decoded.
        let sc = JsonValue::object([
            ("meta".to_string(), JsonValue::object([
                ("status".to_string(), JsonValue::String("completed".to_string())),
            ])),
        ]);
        let result = parse_tool_result(&structured_result(sc), &ResultFormat::MootV2);
        assert_eq!(result.drawers_written, None);
        assert_eq!(result.meta_status.as_deref(), Some("completed"));
    }

    // ── Class A: drain_entries from structuredContent.data.drains ──

    #[test]
    fn v2_drain_entries_decoded_from_structured() {
        let sc = JsonValue::object([
            ("data".to_string(), JsonValue::object([
                ("drains".to_string(), JsonValue::Array(vec![
                    JsonValue::object([
                        ("name".to_string(), JsonValue::String("corpus_encode".to_string())),
                        ("state".to_string(), JsonValue::String("idle".to_string())),
                        ("pending".to_string(), JsonValue::Number(0.0)),
                    ]),
                    JsonValue::object([
                        ("name".to_string(), JsonValue::String("dreaming".to_string())),
                        ("state".to_string(), JsonValue::String("draining".to_string())),
                        ("pending".to_string(), JsonValue::Number(5.0)),
                    ]),
                ])),
            ])),
            ("meta".to_string(), JsonValue::object([
                ("status".to_string(), JsonValue::String("completed".to_string())),
            ])),
        ]);
        let result = parse_tool_result(&structured_result(sc), &ResultFormat::MootV2);
        let entries = result.drain_entries.expect("drain_entries should be Some");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].name, "corpus_encode");
        assert_eq!(entries[0].state, "idle");
        assert_eq!(entries[0].pending, 0);
        assert_eq!(entries[1].name, "dreaming");
        assert_eq!(entries[1].state, "draining");
        assert_eq!(entries[1].pending, 5);
    }
}
