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
//!     JSON. Used by contender (`list_drawers` → `drawer_id`/`content_preview`;
//!     `search` → no id / `text`).
//!   - `MootText`: MOOTx01 plain text. A search result is `found N` followed by
//!     `<UUID>  [location]  <content>` per ranked line; a write result is
//!     `filed memory <UUID>` (the target-assigned id).

use crate::config::ResultFormat;
use crate::json_value::JsonValue;

/// One parsed result item: its id (when the server returns one) and its content
/// (the searchable text). Both optional so a server that returns content
/// without a stable id (contender search) and one that returns an id without
/// inline content both parse into the same shape. Mirrors Swift `MCPResultItem`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MCPResultItem {
    pub id: Option<String>,
    pub content: Option<String>,
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

    match format {
        ResultFormat::JsonObjects { id_key, content_key } => {
            parse_json_objects(result, text_blocks, id_key.as_deref(), content_key)
        }
        ResultFormat::MootText => parse_moot_text(text_blocks),
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
                };
            }
        }
    }
    MCPToolResult {
        ordered_ids: vec![],
        items: vec![],
        write_assigned_id: None,
        text_blocks,
    }
}

/// Pulls the array of result objects out of a value that is either an array of
/// objects or an object holding such an array under a single array-valued key
/// (e.g. contender `results` / `drawers`). An object is kept when it carries
/// the id key (if one is named) or the content key. Returns None when no
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
            // (`get_drawer` returns one bare object with full content.)
            let single = std::slice::from_ref(value);
            qualifying(single)
        }
        _ => None,
    }
}

/// Parses MOOTx01's plain-text results. Each line beginning with a UUID token
/// is one item: `<UUID>  [location]  <content>` for a search hit, or
/// `filed memory <UUID>` for a write. Mirrors Swift `parseMootText`.
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
            let after_uuid = line[uuid.len()..].trim();
            let content = if let Some(close) = after_uuid.find(']') {
                after_uuid[close + 1..].trim().to_string()
            } else {
                after_uuid.to_string()
            };
            items.push(MCPResultItem {
                id: Some(uuid),
                content: Some(content),
            });
        }
    }

    let ordered_ids = items.iter().filter_map(|i| i.id.clone()).collect();
    MCPToolResult {
        ordered_ids,
        items,
        write_assigned_id,
        text_blocks,
    }
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
            // (contender `content_preview`) still matches the same item from a
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
    fn contender_list_drawers() {
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
    fn contender_search_no_id() {
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
        let payload = "found 2 memory(s)\n7CF35028-84BE-40D0-A8CB-7FCFE8EB6018  [import/test]  The benchmarker proves mootx01 outperforms the contender.\n84B0178B-A133-4F43-91D0-2854E7AC45FB  [import/test]  Apple Silicon Metal kernel dispatch.";
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
            Some("The benchmarker proves mootx01 outperforms the contender.".to_string())
        );
        assert_eq!(result.items.len(), 2);
        assert!(result.write_assigned_id.is_none());
    }

    #[test]
    fn moot_search_no_bracket() {
        let payload =
            "found 1 memory(s)\n7CF35028-84BE-40D0-A8CB-7FCFE8EB6018  bare content with no bracket";
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
        let moot = parse_tool_result(&text_result("found 0 memory(s)"), &ResultFormat::MootText);
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
        // get_drawer returns one bare object with full content.
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
}
