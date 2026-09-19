//! journey_driver.rs — argument builders for the new PR-03 verb surfaces.
//!
//! Ports `JourneyDriver.swift`. These functions build the tool-call argument
//! maps for the three new harness exerciser patterns added in PR-03. They are
//! PURE BUILDERS: they take typed parameters and return
//! `BTreeMap<String, JsonValue>` argument maps ready to pass to
//! `MCPClient.call_tool`. No network I/O, no process state.
//!
//! Why this layer exists:
//!
//!   PR-03 added three new verb shapes that no existing runner exercises:
//!   near pivots (recall pivoting from a known anchor item outward, via the
//!   `near` argument — never a query string), batch hydrate (fetch multiple
//!   items at a configurable depth tier), and missing_subject enumerate (list
//!   id-only rows that lack a filed subject, scoped to a required wing).
//!
//!   JourneyDriver provides the harness side of these shapes so they can be
//!   exercised in unit tests against canned fixture replies (no live product
//!   run required) and composed into scripted journeys.

use crate::json_value::JsonValue;
use std::collections::BTreeMap;

// ─────────────────────────────────────────────────────────────────────────────
// Hydration depth
// ─────────────────────────────────────────────────────────────────────────────

/// The three depth tiers accepted by `moot_memory_get` (PR-03).
/// Mirrors Swift `HydrationDepth`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HydrationDepth {
    /// Returns the id and subject line only.
    Subject,
    /// Returns the id, subject, and FDC-distilled summary.
    Distilled,
    /// Returns the id, subject, and full body content.
    Full,
}

impl HydrationDepth {
    /// The wire string value sent in the `depth` argument to `moot_memory_get`.
    pub fn as_wire_str(self) -> &'static str {
        match self {
            HydrationDepth::Subject   => "subject",
            HydrationDepth::Distilled => "distilled",
            HydrationDepth::Full      => "full",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Argument builders
// ─────────────────────────────────────────────────────────────────────────────

/// Builds the argument map for a `moot_memory_search` call that pivots
/// from a known item UUID outward (the anchor-pivot pattern).
///
/// `near` is a first-class argument, mutually exclusive with `query`: the
/// server fetches the anchor, runs its verbatim content through the same
/// scored pipeline, and excludes the anchor row from the reply. That is a
/// different code path from text recall, which is the point of exercising it.
///
/// Emitting NO `query` key is load-bearing, not tidiness. `moot_memory_search`
/// rejects a call carrying both, and a call carrying only `query` runs an
/// ordinary text search — so a `query: "near:<uuid>"` string never reaches the
/// anchor path at all; it searches for that literal text.
///
/// `extra_args` are merged after the required `near` key. Passing `query`
/// there re-creates the mutual-exclusion violation and the server rejects it.
pub fn near_pivot_search_args(uuid: &str, extra_args: BTreeMap<String, JsonValue>) -> BTreeMap<String, JsonValue> {
    let mut args = BTreeMap::new();
    args.insert("near".to_string(), JsonValue::String(uuid.to_string()));
    for (k, v) in extra_args { args.insert(k, v); }
    args
}

/// Builds the argument map for a `moot_recall_shaped` call that pivots
/// from a known item UUID outward.
///
/// Same contract as `near_pivot_search_args` — `near` instead of `query`,
/// exactly one of the two — but targets the shaped recall verb, which fans
/// the anchor out under the active RecallShape preset.
pub fn near_pivot_shaped_args(uuid: &str, extra_args: BTreeMap<String, JsonValue>) -> BTreeMap<String, JsonValue> {
    let mut args = BTreeMap::new();
    args.insert("near".to_string(), JsonValue::String(uuid.to_string()));
    for (k, v) in extra_args { args.insert(k, v); }
    args
}

/// Builds the argument map for a `moot_memory_get` call that batch-hydrates
/// a set of UUIDs at a specified depth tier (PR-03 `ids+depth` pattern).
///
/// `ids` order is preserved in the JSON array. Defaults to `HydrationDepth::Full`.
/// `extra_args` are merged after the required keys.
pub fn batch_hydrate_args(ids: &[&str], depth: HydrationDepth, extra_args: BTreeMap<String, JsonValue>) -> BTreeMap<String, JsonValue> {
    // v2 renamed the batch key: `ids` (v1) → `memory_ids` (v2).
    let mut args = BTreeMap::new();
    args.insert(
        "memory_ids".to_string(),
        JsonValue::Array(ids.iter().map(|id| JsonValue::String(id.to_string())).collect()),
    );
    args.insert("depth".to_string(), JsonValue::String(depth.as_wire_str().to_string()));
    for (k, v) in extra_args { args.insert(k, v); }
    args
}

/// Builds the argument map for a `moot_memory_list` call that enumerates
/// id-only rows lacking a filed subject (PR-03 `filter:missing_subject` pattern).
///
/// `wing` is required by `moot_memory_list` and has NO server-side default, so
/// it is a required parameter here rather than one with a harness default. A
/// default would be the same failure the count validation exists to prevent:
/// enumerating a wing the operator never asked for, then labelling the result
/// with the run they thought they configured.
///
/// `extra_args` are merged after the required `wing` and `filter` keys.
pub fn missing_subject_args(wing: &str, extra_args: BTreeMap<String, JsonValue>) -> BTreeMap<String, JsonValue> {
    let mut args = BTreeMap::new();
    args.insert("wing".to_string(), JsonValue::String(wing.to_string()));
    args.insert("filter".to_string(), JsonValue::String("missing_subject".to_string()));
    for (k, v) in extra_args { args.insert(k, v); }
    args
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — D3 exercisers + D4 journey smoke (both in one module to share fixtures)
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json_value::JsonValue;
    use crate::journey_metrics::{compute_journey_metrics, JourneyStep};
    use crate::journey_recorder::JourneyRecorder;
    use crate::mcp_result::parse_tool_result;
    use crate::config::ResultFormat;

    // ─── Shared fixture helpers ───────────────────────────────────────────────

    /// Wraps raw reply text in the MCP content-block envelope.
    fn text_result(text: &str) -> JsonValue {
        JsonValue::object([(
            "content".to_string(),
            JsonValue::Array(vec![JsonValue::object([
                ("type".to_string(), JsonValue::String("text".to_string())),
                ("text".to_string(), JsonValue::String(text.to_string())),
            ])]),
        )])
    }

    // ─── Canned fixture replies ───────────────────────────────────────────────

    const PIVOT:  &str = "7CF35028-84BE-40D0-A8CB-7FCFE8EB6018";
    const ID1:    &str = "84B0178B-A133-4F43-91D0-2854E7AC45FB";
    const ID2:    &str = "A2C35028-84BE-40D0-A8CB-7FCFE8EB6019";
    const ANSWER: &str = "B3D46139-95CF-51E1-B9DC-8FDF9FC71200";
    const WING:   &str = "Agentic Memory";
    // Middle-dot separator for dense-row format (ARIA_MCP_SPEC 2.0.0). Defined as a const to
    // avoid the unicode-escape-inside-format! restriction: \u{NNNN} is only
    // valid in regular string literals, not inside format!() strings.
    const S: &str = " \u{00B7} ";

    fn survey_reply() -> String {
        format!(
            "found 3 candidate memories, one per line\n\
            {PIVOT}{S}Survey hit one, general topic.{S}General topic first sentence.{S}SSC_GEN{S}-{S}2020-01-01T00:00:00Z{S}0.91\n\
            {ID1}{S}Survey hit two, related domain.{S}Domain second sentence.{S}SSC_DOM{S}-{S}2020-01-02T00:00:00Z{S}0.85\n\
            {ID2}{S}Survey hit three, specific detail.{S}Specific detail sentence.{S}SSC_SPE{S}-{S}2020-01-03T00:00:00Z{S}0.80"
        )
    }

    fn pivot_reply() -> String {
        format!(
            "found 2 candidate memories, one per line\n\
            {ID1}{S}Neighbourhood entry one.{S}Domain neighbourhood sentence.{S}SSC_DOM{S}-{S}2020-02-01T00:00:00Z{S}0.88\n\
            {ID2}{S}Neighbourhood entry two.{S}Specific neighbourhood sentence.{S}SSC_SPE{S}-{S}2020-02-02T00:00:00Z{S}0.82"
        )
    }

    fn winnow_reply() -> String {
        format!("found 1 candidate memory, one per line\n{ANSWER}{S}Specific detail item.{S}Winnowed detail sentence.{S}SSC_SPE{S}-{S}2020-03-01T00:00:00Z{S}0.95")
    }

    fn hydrate_reply() -> String {
        format!("{ANSWER} [import/test] The full body content of the answer item: station reading 47.2 ppm.")
    }

    // ─── D3: HydrationDepth ──────────────────────────────────────────────────

    #[test]
    fn hydration_depth_wire_strings() {
        assert_eq!(HydrationDepth::Subject.as_wire_str(),   "subject");
        assert_eq!(HydrationDepth::Distilled.as_wire_str(), "distilled");
        assert_eq!(HydrationDepth::Full.as_wire_str(),      "full");
    }

    // ─── D3: near_pivot_search_args ──────────────────────────────────────────

    #[test]
    fn near_pivot_search_emits_near_argument_not_query_string() {
        let args = near_pivot_search_args(PIVOT, BTreeMap::new());
        assert_eq!(args.get("near"), Some(&JsonValue::String(PIVOT.to_string())));
        // query and near are mutually exclusive; emitting both is rejected by
        // the server, and emitting only query runs a text search for the
        // literal string instead of the anchor pivot.
        assert_eq!(args.get("query"), None);
    }

    #[test]
    fn near_pivot_search_extra_args_merged() {
        let mut extra = BTreeMap::new();
        extra.insert("limit".to_string(), JsonValue::Number(5.0));
        let args = near_pivot_search_args(PIVOT, extra);
        assert_eq!(args.get("near"), Some(&JsonValue::String(PIVOT.to_string())));
        assert_eq!(args.get("query"), None);
        assert_eq!(args.get("limit"), Some(&JsonValue::Number(5.0)));
    }

    #[test]
    fn near_pivot_search_canned_reply_parses_uuids() {
        let pivot_text = pivot_reply();
        let result = parse_tool_result(&text_result(&pivot_text), &ResultFormat::MootText);
        assert_eq!(result.ordered_ids, [ID1, ID2]);
    }

    // ─── D3: near_pivot_shaped_args ──────────────────────────────────────────

    #[test]
    fn near_pivot_shaped_emits_near_argument_not_query_string() {
        let args = near_pivot_shaped_args(PIVOT, BTreeMap::new());
        assert_eq!(args.get("near"), Some(&JsonValue::String(PIVOT.to_string())));
        assert_eq!(args.get("query"), None);
    }

    #[test]
    fn near_pivot_shaped_canned_reply_parses_uuids() {
        let reply = format!("found 1 candidate memory, one per line\n{ID1}{S}Shaped result.{S}Shaped first sentence.{S}SSC_X{S}-{S}2020-05-01T00:00:00Z{S}0.90");
        let result = parse_tool_result(&text_result(&reply), &ResultFormat::MootText);
        assert_eq!(result.ordered_ids, [ID1]);
    }

    // ─── D3: batch_hydrate_args ──────────────────────────────────────────────

    #[test]
    fn batch_hydrate_default_depth_is_full() {
        let args = batch_hydrate_args(&[ID1, ID2], HydrationDepth::Full, BTreeMap::new());
        assert_eq!(args.get("depth"), Some(&JsonValue::String("full".to_string())));
    }

    #[test]
    fn batch_hydrate_subject_depth_wire_value() {
        let args = batch_hydrate_args(&[ID1], HydrationDepth::Subject, BTreeMap::new());
        assert_eq!(args.get("depth"), Some(&JsonValue::String("subject".to_string())));
    }

    #[test]
    fn batch_hydrate_distilled_depth_wire_value() {
        let args = batch_hydrate_args(&[ID1, ID2], HydrationDepth::Distilled, BTreeMap::new());
        assert_eq!(args.get("depth"), Some(&JsonValue::String("distilled".to_string())));
    }

    #[test]
    fn batch_hydrate_ids_array_preserves_order() {
        let args = batch_hydrate_args(&[ID1, ID2, ANSWER], HydrationDepth::Full, BTreeMap::new());
        let expected = JsonValue::Array(vec![
            JsonValue::String(ID1.to_string()),
            JsonValue::String(ID2.to_string()),
            JsonValue::String(ANSWER.to_string()),
        ]);
        // v2: key renamed ids → memory_ids
        assert_eq!(args.get("memory_ids"), Some(&expected));
    }

    #[test]
    fn batch_hydrate_canned_reply_parses_content() {
        let reply = format!(
            "{ID1} [import/test] The quick brown fox content body.\n\
            {ID2} [import/test] Another item full body content."
        );
        let result = parse_tool_result(&text_result(&reply), &ResultFormat::MootText);
        assert_eq!(result.ordered_ids, [ID1, ID2]);
        assert!(result.items[0].content.as_deref().unwrap_or("").contains("quick brown fox"));
        assert!(result.items[1].content.as_deref().unwrap_or("").contains("Another item"));
    }

    // ─── D3: missing_subject_args ────────────────────────────────────────────

    #[test]
    fn missing_subject_supplies_required_wing_with_filter() {
        let args = missing_subject_args(WING, BTreeMap::new());
        assert_eq!(args.get("filter"), Some(&JsonValue::String("missing_subject".to_string())));
        // wing is required by moot_memory_list; without it the call fails
        // schema validation before it ever reaches the enumerator.
        assert_eq!(args.get("wing"), Some(&JsonValue::String(WING.to_string())));
    }

    #[test]
    fn missing_subject_extra_args_merged() {
        let mut extra = BTreeMap::new();
        extra.insert("room".to_string(), JsonValue::String("import/test".to_string()));
        let args = missing_subject_args(WING, extra);
        assert_eq!(args.get("filter"), Some(&JsonValue::String("missing_subject".to_string())));
        assert_eq!(args.get("wing"), Some(&JsonValue::String(WING.to_string())));
        assert_eq!(args.get("room"), Some(&JsonValue::String("import/test".to_string())));
    }

    // ─── D3: live-contract key sets ──────────────────────────────────────────
    //
    // Asserts each builder's key set against the tool schemas rather than
    // against a per-test literal, so a builder that drifts from the contract
    // fails here even if its own shape test was written to match the drift.
    //
    // LIMITATION, stated because it is how the query:"near:<uuid>" defect
    // shipped in the first place: these key sets are TRANSCRIBED, not imported.
    // The benchmarker takes no MOOTx01 kit dependency at the MCP boundary, so
    // AriaMcpKit's tool schemas are not reachable from this crate and cannot be
    // asserted against directly. If the server contract moves, this table goes
    // stale silently. Sources, verified at authoring time:
    //   moot_memory_search — ToolProjection.swift:211-219 (query XOR near),
    //                        enforced at ToolDispatch.swift:1369-1387
    //   moot_recall_shaped — RecipeTools.swift:172-181 (query XOR near),
    //                        enforced at RecipeTools.swift:833-846
    //   moot_memory_list   — ToolProjection.swift:229-234, required: ["wing"]
    const MEMORY_SEARCH_PERMITTED: &[&str] = &[
        "query", "near", "limit", "filter", "wing", "media_type",
        "explain", "scoring", "ordering", "estateID",
    ];
    const RECALL_SHAPED_PERMITTED: &[&str] =
        &["query", "near", "preset", "limit", "filter", "wing", "estateID"];
    const MEMORY_LIST_PERMITTED: &[&str] = &["wing", "room", "filter", "estateID"];
    const MEMORY_LIST_REQUIRED: &[&str] = &["wing"];

    /// Every emitted key is permitted by the named tool's schema.
    fn assert_keys_permitted(args: &BTreeMap<String, JsonValue>, permitted: &[&str]) {
        for key in args.keys() {
            assert!(permitted.contains(&key.as_str()), "key '{key}' is not in the tool schema");
        }
    }

    #[test]
    fn near_pivot_search_key_set_satisfies_memory_search_contract() {
        let args = near_pivot_search_args(PIVOT, BTreeMap::new());
        assert_keys_permitted(&args, MEMORY_SEARCH_PERMITTED);
        // Exactly one of query/near — the server rejects both, and treats
        // neither as a usage error.
        assert!(args.contains_key("near") && !args.contains_key("query"));
    }

    #[test]
    fn near_pivot_shaped_key_set_satisfies_recall_shaped_contract() {
        let args = near_pivot_shaped_args(PIVOT, BTreeMap::new());
        assert_keys_permitted(&args, RECALL_SHAPED_PERMITTED);
        assert!(args.contains_key("near") && !args.contains_key("query"));
    }

    #[test]
    fn missing_subject_key_set_satisfies_memory_list_contract() {
        let args = missing_subject_args(WING, BTreeMap::new());
        assert_keys_permitted(&args, MEMORY_LIST_PERMITTED);
        for required in MEMORY_LIST_REQUIRED {
            assert!(args.contains_key(*required), "missing required key '{required}'");
        }
    }

    #[test]
    fn missing_subject_canned_reply_parses_id_only_rows() {
        let reply = format!(
            "found 2 memory(s)\n\
            {ID1} [import/test]\n\
            {ID2} [import/test]"
        );
        let result = parse_tool_result(&text_result(&reply), &ResultFormat::MootText);
        assert!(result.ordered_ids.contains(&ID1.to_string()));
        assert!(result.ordered_ids.contains(&ID2.to_string()));
    }

    // ─── D4: Journey smoke — survey→pivot→winnow→hydrate ─────────────────────

    #[test]
    fn survey_step_parses_three_uuids() {
        let result = parse_tool_result(&text_result(&survey_reply()), &ResultFormat::MootText);
        assert_eq!(result.ordered_ids, [PIVOT, ID1, ID2]);
    }

    #[test]
    fn pivot_step_args_and_parse() {
        let args = near_pivot_search_args(PIVOT, BTreeMap::new());
        assert_eq!(args.get("near"), Some(&JsonValue::String(PIVOT.to_string())));
        // near and query are mutually exclusive on the live tool.
        assert_eq!(args.get("query"), None);
        let result = parse_tool_result(&text_result(&pivot_reply()), &ResultFormat::MootText);
        assert_eq!(result.ordered_ids, [ID1, ID2]);
    }

    #[test]
    fn winnow_step_parses_single_answer() {
        let result = parse_tool_result(&text_result(&winnow_reply()), &ResultFormat::MootText);
        assert_eq!(result.ordered_ids, [ANSWER]);
    }

    #[test]
    fn hydrate_step_args_and_parse() {
        let args = batch_hydrate_args(&[ANSWER], HydrationDepth::Full, BTreeMap::new());
        assert_eq!(args.get("depth"), Some(&JsonValue::String("full".to_string())));
        let result = parse_tool_result(&text_result(&hydrate_reply()), &ResultFormat::MootText);
        assert_eq!(result.ordered_ids, [ANSWER]);
        assert!(result.items[0].content.as_deref().unwrap_or("").contains("station reading"));
    }

    #[test]
    fn full_journey_metrics_via_recorder() {
        let mut recorder = JourneyRecorder::new();

        // Step 1: SURVEY — broad recall, not hydrated, not terminal.
        recorder.append("survey", &survey_reply(), false, false);
        // Step 2: PIVOT — neighbourhood recall, not hydrated, not terminal.
        recorder.append("pivot", &pivot_reply(), false, false);
        // Step 3: WINNOW — shaped recall, not hydrated, not terminal.
        recorder.append("winnow", &winnow_reply(), false, false);
        // Step 4: HYDRATE — full body fetch, hydrated, terminal.
        recorder.append("hydrate", &hydrate_reply(), true, true);

        let metrics = recorder.metrics();

        // hops: 4 steps.
        assert_eq!(metrics.hops, 4);
        // preTerminalFullContentTokens: step 4 is terminal+hydrated → 0.
        assert_eq!(metrics.pre_terminal_full_content_tokens, 0);
        // totalPayloadTokens > 0.
        assert!(metrics.total_payload_tokens > 0);
        // tokenTurnIntegral >= totalPayloadTokens for multi-step journeys.
        assert!(metrics.token_turn_integral >= metrics.total_payload_tokens);
    }

    #[test]
    fn journey_report_block_has_all_metric_keys() {
        let mut recorder = JourneyRecorder::new();
        recorder.append("survey", &survey_reply(), false, false);
        recorder.append("hydrate", &hydrate_reply(), true, true);

        let report = recorder.report_block();
        assert!(report.contains("hops:"), "report must contain 'hops:'");
        assert!(report.contains("token_turn_integral:"), "report must contain 'token_turn_integral:'");
        assert!(report.contains("pre_terminal_full_tokens:"), "report must contain 'pre_terminal_full_tokens:'");
        assert!(report.contains("total_payload_tokens:"), "report must contain 'total_payload_tokens:'");
    }

    #[test]
    fn recorder_steps_accumulate_in_order() {
        let mut recorder = JourneyRecorder::new();
        recorder.append("survey",  &survey_reply(),  false, false);
        recorder.append("pivot",   &pivot_reply(),   false, false);
        recorder.append("winnow",  &winnow_reply(),  false, false);
        recorder.append("hydrate", &hydrate_reply(), true,  true);

        let steps = recorder.current_steps();
        assert_eq!(steps.len(), 4);
        assert_eq!(steps[0].verb, "survey");
        assert_eq!(steps[1].verb, "pivot");
        assert_eq!(steps[2].verb, "winnow");
        assert_eq!(steps[3].verb, "hydrate");
        assert!(steps[3].terminal);
        assert!(steps[3].hydrated_full_content);
    }

    #[test]
    fn token_turn_integral_arithmetic() {
        // Manual verification of integral definition:
        //   integral = ∑_i (cumulative_payload_at_i)
        //   step0=10 tokens, step1=20 tokens
        //   cumulative at 0: 10; at 1: 30 → integral = 10+30 = 40
        let steps = vec![
            JourneyStep { verb: "a".into(), payload_tokens: 10, hydrated_full_content: false, terminal: false },
            JourneyStep { verb: "b".into(), payload_tokens: 20, hydrated_full_content: true,  terminal: true },
        ];
        let metrics = compute_journey_metrics(&steps);
        assert_eq!(metrics.token_turn_integral, 40);
        assert_eq!(metrics.hops, 2);
        assert_eq!(metrics.total_payload_tokens, 30);
        // step1 is terminal+hydrated: preTerminalFull = 0.
        assert_eq!(metrics.pre_terminal_full_content_tokens, 0);
    }

    #[test]
    fn pre_terminal_hydration_cost_counts_non_terminal_hydrated_steps() {
        let steps = vec![
            JourneyStep { verb: "a".into(), payload_tokens: 50, hydrated_full_content: true,  terminal: false },
            JourneyStep { verb: "b".into(), payload_tokens: 10, hydrated_full_content: true,  terminal: true },
        ];
        let metrics = compute_journey_metrics(&steps);
        // Only step 0 is non-terminal and hydrated.
        assert_eq!(metrics.pre_terminal_full_content_tokens, 50);
    }
}
