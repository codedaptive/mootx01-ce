//! V2 coaching engine — section 12.5 trigger detection.
//!
//! Implements the six coaching triggers from ARIA_MCP_INTERFACE.md §12.5 for
//! the v2 surface. Wire-aligned with Swift `AriaV2Coach.swift`. Both ports
//! must agree on trigger order, trigger conditions, and hint text.
//!
//! ## Trigger table (§12.5)
//!
//! | Tool                   | Trigger                                         |
//! |------------------------|-------------------------------------------------|
//! | moot_memory_search     | no query, query over 200 chars, or zero results |
//! | moot_file_memory       | content over 4,000 chars or duplicate result    |
//! | moot_erase_memory      | confirmation absent or false                    |
//! | moot_migration_confirm | disqualified branch result                      |
//! | moot_link_memories     | unresolved IDs                                  |
//! | any lens               | zero results                                    |
//!
//! Hints never attach to error results (isError:true). First match wins.
//!
//! ## Implementation note on confirmation/erase
//!
//! The v2 decoder rejects `moot_erase_memory` when `confirmation` is absent
//! or false (returns invalidParams before reaching the coaching path). In
//! practice the confirmation trigger cannot fire on v2 as long as the decoder
//! enforces strict validation. The check is present for spec completeness and
//! will activate if the decoder is ever relaxed.
//!
//! Parity: Rust twin of Swift `AriaV2Coach.swift`.

use serde_json::Value;
use crate::surface::{SurfaceRequest, MemoryMutationRequest};
use crate::v2::core_memory::V2SearchTarget;

// MARK: - Public entry point

/// Return a coaching hint for the given v2 tool call and result, or `None`
/// when no trigger fires.
///
/// Called at the v2 dispatcher choke point AFTER `record_call` and the
/// operation result is available. The first matching trigger wins.
///
/// `pub(crate)` because `SurfaceRequest` is `pub(crate)` — this function is
/// an internal entry point called only from `dispatcher.rs`.
pub(crate) fn coaching_hint(request: &SurfaceRequest, result: &Value) -> Option<String> {
    // Hints never attach to error results. isError:true signals a refusal.
    if result.get("isError").and_then(|v| v.as_bool()) == Some(true) {
        return None;
    }

    match request {
        SurfaceRequest::MemorySearch(req) => hint_for_memory_search(&req.target, result),
        SurfaceRequest::FileMemory(req) => hint_for_file_memory(&req.content, result),
        SurfaceRequest::MemoryMutation(MemoryMutationRequest::Erase(req)) => {
            hint_for_erase(req.confirmation)
        }
        SurfaceRequest::MigrationConfirm(_) => hint_for_migration_confirm(result),
        SurfaceRequest::MemoryMutation(MemoryMutationRequest::Link(_)) => {
            hint_for_link_memories(result)
        }
        // Any lens: moot_recall_precise, moot_recall_temporal, moot_recall_connected,
        // moot_recall_shaped.
        SurfaceRequest::Recall(_) => hint_for_lens_zero_results(result),
        _ => None,
    }
}

// MARK: - Trigger implementations

/// moot_memory_search: no query, query over 200 characters, or zero results.
fn hint_for_memory_search(target: &V2SearchTarget, result: &Value) -> Option<String> {
    // Trigger: query over 200 characters (pre-flight check on decoded request).
    // The decoder requires either query or near, so "no query" is a decode error
    // and cannot reach this path. The long-query trigger is the active pre-flight
    // check for moot_memory_search on v2.
    if let V2SearchTarget::Query(q) = target {
        if q.chars().count() > 200 {
            return Some(
                "Queries over 200 characters reduce recall precision. \
                 Try a shorter, focused term — the estate ranks by relevance, \
                 so fewer, sharper words usually beat a long description."
                .to_owned(),
            );
        }
    }
    // Trigger: zero results (post-flight check on the operation result).
    if result_has_empty_results(result) {
        return Some(
            "No memories matched. File content with moot_file_memory first, \
             then search with a focused term."
            .to_owned(),
        );
    }
    None
}

/// moot_file_memory: content over 4,000 characters or duplicate result.
fn hint_for_file_memory(content: &str, result: &Value) -> Option<String> {
    // Trigger: content over 4,000 characters (pre-flight on decoded request).
    if content.chars().count() > 4_000 {
        return Some(
            "Content over 4,000 characters is harder to recall precisely. \
             Consider splitting into smaller, focused memories so each one \
             surfaces on the right query."
            .to_owned(),
        );
    }
    // Trigger: duplicate result (post-flight on the operation result).
    if result_text_contains(result, "duplicate") || result_text_contains(result, "already filed") {
        return Some(
            "This content may duplicate an existing memory. \
             Use moot_memory_search to find and review existing entries \
             before filing again."
            .to_owned(),
        );
    }
    None
}

/// moot_erase_memory: confirmation absent or false.
///
/// In v2 the decoder rejects confirmation:false with invalidParams, so this
/// trigger cannot fire in practice. The check is present for spec completeness.
fn hint_for_erase(confirmation: bool) -> Option<String> {
    if !confirmation {
        return Some(
            "Erase requires confirmation:true. \
             Set confirmation to the boolean true to confirm permanent deletion."
            .to_owned(),
        );
    }
    None
}

/// moot_migration_confirm: disqualified branch result.
fn hint_for_migration_confirm(result: &Value) -> Option<String> {
    // A disqualified branch result has a non-empty "disqualified" array in
    // the structuredContent data.
    let has_disqualified = result
        .get("structuredContent")
        .and_then(|sc| sc.get("data"))
        .and_then(|d| d.get("disqualified"))
        .and_then(|v| v.as_array())
        .map(|a| !a.is_empty())
        .unwrap_or(false);
    // Also catch text-level indicators.
    let text_disqualified = result_text_contains(result, "disqualified");
    if has_disqualified || text_disqualified {
        return Some(
            "One or more migration branches were disqualified. \
             Review the estate state with moot_estate_status before retrying \
             the migration confirmation."
            .to_owned(),
        );
    }
    None
}

/// moot_link_memories: unresolved IDs.
fn hint_for_link_memories(result: &Value) -> Option<String> {
    if result_text_contains(result, "unresolved") || result_text_contains(result, "not found") {
        return Some(
            "One or more memory IDs could not be resolved. \
             Use moot_memory_search to verify the IDs before linking."
            .to_owned(),
        );
    }
    None
}

/// Any lens (moot_recall_*): zero results.
fn hint_for_lens_zero_results(result: &Value) -> Option<String> {
    if result_has_empty_results(result) {
        return Some(
            "This lens returned zero results. \
             Try adjusting your query, or check moot_list_lenses for \
             available lens options and their required arguments."
            .to_owned(),
        );
    }
    None
}

// MARK: - Result inspection helpers

/// Returns true when the result's structuredContent data contains an empty
/// "results" array. Used for moot_memory_search and any-lens triggers.
fn result_has_empty_results(result: &Value) -> bool {
    result
        .get("structuredContent")
        .and_then(|sc| sc.get("data"))
        .and_then(|d| d.get("results"))
        .and_then(|r| r.as_array())
        .map(|a| a.is_empty())
        .unwrap_or(false)
}

/// Returns true when content[0].text contains the given substring.
fn result_text_contains(result: &Value, substring: &str) -> bool {
    result
        .get("content")
        .and_then(|c| c.as_array())
        .and_then(|a| a.first())
        .and_then(|e| e.get("text"))
        .and_then(|t| t.as_str())
        .map(|text| text.contains(substring))
        .unwrap_or(false)
}
