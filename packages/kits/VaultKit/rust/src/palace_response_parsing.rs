//! palace_response_parsing — parses MemPalace tool responses the pump depends
//! on. Rust parallel of the Swift `PalaceResponseParsing`. Fixes the
//! benchmarker's GAP B (write-id) and GAP C (verify by get_drawer, not
//! search).
//!
//! Verified live (v3.3.3):
//!   add_drawer  → text block JSON `{ "success", "drawer_id", ... }`, and on a
//!                 duplicate `{ "success", "reason":"already_exists",
//!                 "drawer_id" }`. Either way `drawer_id` is present.
//!   get_drawer  → text block JSON `{ "drawer_id", "content", "wing", "room",
//!                 "metadata": {...} }`.
//!
//! These parsers take the already-extracted text block(s) (the MCP client
//! unwraps the `content: [{type:"text", text}]` envelope) and parse the inner
//! JSON. Pure and deterministic.

/// The parsed result of a `get_drawer` fetch: the drawer id and full verbatim
/// content. Mirrors Swift `PalaceFetchedDrawer`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PalaceFetchedDrawer {
    /// The drawer id (echoed by `get_drawer`).
    pub drawer_id: String,
    /// The full verbatim content as stored.
    pub content: String,
}

/// Errors raised while parsing MemPalace tool responses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PalaceResponseError {
    /// No text block carried parseable JSON with the expected key.
    MissingField(String),
}

impl std::fmt::Display for PalaceResponseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PalaceResponseError::MissingField(k) => {
                write!(f, "MemPalace response missing field: {k}")
            }
        }
    }
}

impl std::error::Error for PalaceResponseError {}

/// Parse the `drawer_id` MemPalace assigned (or echoed) from an `add_drawer`
/// response's text blocks. Handles both the fresh-write and `already_exists`
/// shapes — both carry `drawer_id`. GAP-B fix.
pub fn parse_add_drawer_id(text_blocks: &[String]) -> Result<String, PalaceResponseError> {
    for block in text_blocks {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(block) {
            if let Some(id) = value.get("drawer_id").and_then(|v| v.as_str()) {
                if !id.is_empty() {
                    return Ok(id.to_owned());
                }
            }
        }
    }
    Err(PalaceResponseError::MissingField("drawer_id".to_owned()))
}

/// Parse the assigned id from a write response's text blocks, given the id key
/// that tool returns. The four-noun generalization of [`parse_add_drawer_id`]:
/// `add_drawer` → `drawer_id`, `create_tunnel` → `id` (bare key),
/// `kg_add` → `triple_id`, `diary_write` → `entry_id` (verified live,
/// v3.3.3). The
/// `already_exists` shape carries the same key. Returns `None` when no block
/// carries a non-empty value for `id_key`. Mirrors Swift `parseAssignedID`.
pub fn parse_assigned_id(text_blocks: &[String], id_key: &str) -> Option<String> {
    for block in text_blocks {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(block) {
            if let Some(id) = value.get(id_key).and_then(|v| v.as_str()) {
                if !id.is_empty() {
                    return Some(id.to_owned());
                }
            }
        }
    }
    None
}

/// The response key that carries the assigned row id for one noun's write tool.
/// Mirrors Swift `assignedIDKey(for:)`.
pub fn assigned_id_key(noun: crate::palace_item::PalaceNoun) -> &'static str {
    use crate::palace_item::PalaceNoun;
    match noun {
        PalaceNoun::Drawer => "drawer_id",
        // create_tunnel returns the symmetric tunnel id under the bare `id`
        // key (not `tunnel_id`) — empirically determined against the live
        // server (v3.3.3).
        PalaceNoun::Tunnel => "id",
        PalaceNoun::KgFact => "triple_id",
        PalaceNoun::DiaryEntry => "entry_id",
    }
}

/// Parse the id + full content from a `get_drawer` response's text blocks.
/// Used to verify a write round-tripped (GAP-C fix) and to reconstruct a
/// `NoteIR` from a re-import.
pub fn parse_get_drawer(text_blocks: &[String]) -> Result<PalaceFetchedDrawer, PalaceResponseError> {
    for block in text_blocks {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(block) {
            let id = value.get("drawer_id").and_then(|v| v.as_str());
            // `content` may be empty-string; require the key present, not the
            // value non-empty, so an intentionally empty drawer still parses.
            let content = value.get("content").and_then(|v| v.as_str());
            if let (Some(id), Some(content)) = (id, content) {
                if !id.is_empty() {
                    return Ok(PalaceFetchedDrawer {
                        drawer_id: id.to_owned(),
                        content: content.to_owned(),
                    });
                }
            }
        }
    }
    Err(PalaceResponseError::MissingField(
        "drawer_id+content".to_owned(),
    ))
}
