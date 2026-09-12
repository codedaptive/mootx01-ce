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
    // Trigger: query over 200 characters (checked on the decoded request).
    // The decoder requires either query or near, so "no query" is a decode error
    // and cannot reach this path. The long-query trigger is the active
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
    // Trigger: zero results (checked on the operation result).
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
    // Trigger: content over 4,000 characters (checked on the decoded request).
    if content.chars().count() > 4_000 {
        return Some(
            "Content over 4,000 characters is harder to recall precisely. \
             Consider splitting into smaller, focused memories so each one \
             surfaces on the right query."
            .to_owned(),
        );
    }
    // Trigger: duplicate result (checked on the operation result).
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

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------
//
// These tests call `coaching_hint` directly with synthetic request and result
// values, covering triggers that cannot fire through the v2 dispatcher because
// the decoder rejects the arguments before they reach the coaching path:
//
//   * moot_erase_memory: decoder rejects confirmation:false with invalidParams.
//   * moot_link_memories: a partial-success result with "unresolved" text cannot
//     be produced by the in-memory lower adapter (failure → refusal, not hint).
//   * moot_migration_confirm: "disqualified" text in a success envelope requires
//     live migration state not available in the in-memory estate.
//
// Integration tests in rust/tests/v2_coach_tests.rs cover the full dispatcher
// path for the triggers that ARE reachable there.

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use crate::surface::MemoryMutationRequest;
    use crate::v2::core_memory::{V2MemorySearchRequest, V2SearchTarget, V2FileMemoryRequest};
    use crate::v2::memory_mutations::{V2EraseMemoryRequest, V2LinkMemoriesRequest};
    use crate::v2::orchestration::V2ConfirmMigrationRequest;
    use crate::v2::recall_lens::{V2RecallLensRequest, V2RecallLensOperation};
    use uuid::Uuid;
    use std::collections::BTreeMap;

    // -----------------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------------

    /// Construct a minimal non-error v2 success result envelope.
    fn success_result(text: &str) -> Value {
        json!({
            "content": [{ "type": "text", "text": text }],
            "structuredContent": { "data": {}, "meta": {} },
            "isError": false
        })
    }

    /// Construct a v2 success result envelope with an empty "results" array.
    fn empty_results_result() -> Value {
        json!({
            "content": [{ "type": "text", "text": "no results" }],
            "structuredContent": { "data": { "results": [] }, "meta": {} },
            "isError": false
        })
    }

    /// Construct a v2 error result envelope (isError:true).
    fn error_result(msg: &str) -> Value {
        json!({
            "content": [{ "type": "text", "text": msg }],
            "structuredContent": { "error": { "code": "test", "message": msg } },
            "isError": true
        })
    }

    /// Build a minimal V2MemorySearchRequest with the given target and limit.
    fn search_request(target: V2SearchTarget) -> V2MemorySearchRequest {
        V2MemorySearchRequest {
            estate_id: None,
            target,
            limit: 10,
            filter: None,
            wing: None,
            media_type: None,
            explain: None,
            door: None,
            scoring: None,
            ordering: None,
            frontier_k: None,
            answer: None,
        }
    }

    /// Build a minimal V2FileMemoryRequest with the given content.
    fn file_request(content: &str) -> V2FileMemoryRequest {
        V2FileMemoryRequest {
            estate_id: None,
            content: content.to_owned(),
            subject: "Test subject.".to_owned(),
            location: "default".to_owned(),
            wing: None,
            sensitivity: Some(crate::v2::core_memory::V2Sensitivity::Normal),
            exportability: Some(crate::v2::core_memory::V2Exportability::Private),
            kind: Some(crate::v2::core_memory::V2ContentKind::Prose),
            event_time: None,
            impatient: false,
        }
    }

    // -----------------------------------------------------------------------
    // isError guard
    // -----------------------------------------------------------------------

    /// A coaching hint must never attach to an isError:true result.
    /// The guard fires before any trigger check so the request type is irrelevant.
    #[test]
    fn is_error_guard_returns_none_regardless_of_trigger() {
        // Long-query request would trigger a hint on a success result.
        let long_query: String = "a".repeat(201);
        let request = SurfaceRequest::MemorySearch(search_request(
            V2SearchTarget::Query(long_query),
        ));
        let result = error_result("deliberate test error");
        assert!(
            coaching_hint(&request, &result).is_none(),
            "coaching_hint must return None for isError:true regardless of the trigger"
        );
    }

    // -----------------------------------------------------------------------
    // moot_memory_search — long-query trigger
    // -----------------------------------------------------------------------

    #[test]
    fn memory_search_long_query_hint_fires() {
        let long_query: String = "x".repeat(201);
        let request = SurfaceRequest::MemorySearch(search_request(
            V2SearchTarget::Query(long_query),
        ));
        let result = success_result("memory search");
        let hint = coaching_hint(&request, &result)
            .expect("long-query must produce a hint");
        assert!(
            hint.contains("200 characters") || hint.contains("shorter"),
            "long-query hint must mention the 200-character threshold; got: {hint:?}"
        );
    }

    #[test]
    fn memory_search_short_query_no_results_no_long_query_hint() {
        // Short query — zero results are what trigger the hint, not the query length.
        let request = SurfaceRequest::MemorySearch(search_request(
            V2SearchTarget::Query("short".to_owned()),
        ));
        let result = empty_results_result();
        let hint = coaching_hint(&request, &result)
            .expect("zero-results must produce a hint");
        assert!(
            hint.contains("No memories matched") || hint.contains("moot_file_memory"),
            "zero-results hint must guide toward filing content; got: {hint:?}"
        );
    }

    // -----------------------------------------------------------------------
    // moot_file_memory — large-content trigger
    // -----------------------------------------------------------------------

    #[test]
    fn file_memory_large_content_hint_fires() {
        let large: String = "y".repeat(4001);
        let request = SurfaceRequest::FileMemory(file_request(&large));
        let result = success_result("filed memory");
        let hint = coaching_hint(&request, &result)
            .expect("large-content must produce a hint");
        assert!(
            hint.contains("4,000") || hint.contains("splitting"),
            "large-content hint must mention 4,000 characters or splitting; got: {hint:?}"
        );
    }

    // -----------------------------------------------------------------------
    // moot_erase_memory — confirmation:false trigger
    //
    // In the v2 dispatcher the decoder rejects confirmation:false before reaching
    // this path. The check is present for spec completeness; this unit test
    // exercises it directly.
    // -----------------------------------------------------------------------

    #[test]
    fn erase_memory_confirmation_false_triggers_hint() {
        let request = SurfaceRequest::MemoryMutation(MemoryMutationRequest::Erase(
            V2EraseMemoryRequest {
                memory_id: Uuid::nil(),
                confirmation: false, // decoder blocks this in practice; spec-completeness path
                reason: None,
                estate_id: None,
            },
        ));
        let result = success_result("hypothetical success");
        let hint = coaching_hint(&request, &result)
            .expect("confirmation:false must produce a hint");
        assert!(
            hint.contains("confirmation") && hint.contains("true"),
            "erase hint must explain the confirmation requirement; got: {hint:?}"
        );
    }

    #[test]
    fn erase_memory_confirmation_true_no_hint() {
        let request = SurfaceRequest::MemoryMutation(MemoryMutationRequest::Erase(
            V2EraseMemoryRequest {
                memory_id: Uuid::nil(),
                confirmation: true,
                reason: None,
                estate_id: None,
            },
        ));
        let result = success_result("erased");
        assert!(
            coaching_hint(&request, &result).is_none(),
            "confirmation:true must NOT produce a hint"
        );
    }

    // -----------------------------------------------------------------------
    // moot_migration_confirm — disqualified trigger
    // -----------------------------------------------------------------------

    #[test]
    fn migration_confirm_disqualified_text_triggers_hint() {
        let id = Uuid::nil();
        let request = SurfaceRequest::MigrationConfirm(V2ConfirmMigrationRequest {
            winner_branch_id: id,
            discard_branch_ids: vec![],
            estate_id: None,
        });
        // Synthetic result containing "disqualified" in the text.
        let result = json!({
            "content": [{ "type": "text", "text": "one branch was disqualified during the migration" }],
            "structuredContent": { "data": {}, "meta": {} },
            "isError": false
        });
        let hint = coaching_hint(&request, &result)
            .expect("disqualified text must trigger a hint");
        assert!(
            hint.contains("disqualified") || hint.contains("moot_estate_status"),
            "migration hint must mention disqualified branches or estate status; got: {hint:?}"
        );
    }

    #[test]
    fn migration_confirm_disqualified_structured_content_triggers_hint() {
        let id = Uuid::nil();
        let request = SurfaceRequest::MigrationConfirm(V2ConfirmMigrationRequest {
            winner_branch_id: id,
            discard_branch_ids: vec![],
            estate_id: None,
        });
        // Synthetic result with non-empty disqualified array in structuredContent.
        let result = json!({
            "content": [{ "type": "text", "text": "migration result" }],
            "structuredContent": { "data": { "disqualified": [{ "id": "some-branch" }] }, "meta": {} },
            "isError": false
        });
        let hint = coaching_hint(&request, &result)
            .expect("disqualified array in structuredContent must trigger a hint");
        assert!(
            hint.contains("disqualified") || hint.contains("moot_estate_status"),
            "migration hint must mention disqualified branches or estate status; got: {hint:?}"
        );
    }

    // -----------------------------------------------------------------------
    // moot_link_memories — unresolved-IDs trigger
    //
    // The v2 dispatcher returns a refusal (isError:true) when memory IDs cannot
    // be resolved via the lower adapter. The hint checks text content; this unit
    // test exercises that path directly with a synthetic success result.
    // -----------------------------------------------------------------------

    #[test]
    fn link_memories_unresolved_text_triggers_hint() {
        let from_id = Uuid::new_v4();
        let to_id = Uuid::new_v4();
        let request = SurfaceRequest::MemoryMutation(MemoryMutationRequest::Link(
            V2LinkMemoriesRequest {
                from_id,
                to_id,
                relationship: "relates".to_owned(),
                confidence: None,
                evidence: None,
                estate_id: None,
            },
        ));
        let result = json!({
            "content": [{ "type": "text", "text": "unresolved: one or more memory IDs could not be found" }],
            "structuredContent": { "data": {}, "meta": {} },
            "isError": false
        });
        let hint = coaching_hint(&request, &result)
            .expect("unresolved text must trigger a hint for moot_link_memories");
        assert!(
            hint.contains("IDs") || hint.contains("moot_memory_search"),
            "link hint must mention IDs or searching; got: {hint:?}"
        );
    }

    // -----------------------------------------------------------------------
    // Any lens — zero-results trigger
    // -----------------------------------------------------------------------

    #[test]
    fn recall_lens_zero_results_triggers_hint() {
        let request = SurfaceRequest::Recall(V2RecallLensRequest {
            operation: V2RecallLensOperation::RecallPrecise,
            estate_id: None,
            values: BTreeMap::new(),
        });
        let result = empty_results_result();
        let hint = coaching_hint(&request, &result)
            .expect("lens zero-results must produce a hint");
        assert!(
            hint.contains("zero results") || hint.contains("moot_list_lenses"),
            "lens hint must mention zero results or moot_list_lenses; got: {hint:?}"
        );
    }

    // -----------------------------------------------------------------------
    // First-match-wins
    // -----------------------------------------------------------------------

    /// Long query with zero results: the long-query trigger is listed first in
    /// the match and must fire. The zero-results trigger must not fire.
    #[test]
    fn first_match_wins_long_query_over_zero_results() {
        let long_query: String = "z".repeat(201);
        let request = SurfaceRequest::MemorySearch(search_request(
            V2SearchTarget::Query(long_query),
        ));
        // Empty results — would trigger zero-results if long-query didn't fire first.
        let result = empty_results_result();
        let hint = coaching_hint(&request, &result)
            .expect("a hint must fire (long-query trigger first)");
        // Must be the long-query hint, not zero-results.
        assert!(
            hint.contains("200 characters") || hint.contains("shorter"),
            "first-match must be the long-query hint; got: {hint:?}"
        );
        assert!(
            !hint.contains("No memories matched"),
            "zero-results hint must NOT fire when long-query fires first; got: {hint:?}"
        );
    }
}
