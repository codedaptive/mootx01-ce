//! aria_v2_surface.rs — ARIA v2 surface adapter for the benchmark harness (Rust port).
//!
//! All MCP tool name constants and argument key constants used by the harness
//! route through this module. After this migration, `rg -n '"moot_[a-z_]+"' rust/src`
//! shows hits only in this file.
//!
//! The twin of this file on the Swift port is `AriaV2Surface.swift`.
//!
//! # v1→v2 naming changes
//! - `moot_federated_search`  →  `moot_federated_recall`  (renamed in v2)
//!   All other tool names are unchanged.
//!
//! # v1→v2 argument changes (dropped or remapped by this adapter)
//! - `ordering`  — accepted by moot_memory_search in v2 (catalog-confirmed accepted_key),
//!                  but the harness omits it because v2 defaults to byRelevanceDesc;
//!                  no caller currently passes it, and the adapter does not strip it
//! - `mode`      — removed from moot_json_import (v2 accepts only path + estate_id)
//! - `teachme`   — removed entirely; help is moot_help
//! - `confirmed` — renamed to `confirmation` on moot_erase_memory (not used by runners)
//! - `id`        — renamed to `memory_id` on moot_memory_get (scalar form)
//! - `ids`       — renamed to `memory_ids` on moot_memory_get (batch form)
//! - `location`  — renamed to `wing` on moot_memory_search (scope key changed in v2;
//!                  moot_file_memory still uses `location`)
//! - `ack`       — removed from moot_recall_distilled (v2 has no ack gate)
//!
//! # v2 structured response shapes (read by parse_moot_v2 in mcp_result.rs)
//! - moot_memory_search  → structuredContent.data.results[].{memory_id, excerpt}
//! - moot_recall_*       → structuredContent.data.results[].{id, bestSpan}
//! - moot_file_memory    → structuredContent.data.memory_id  (write receipt)
//! - moot_memory_get     → structuredContent.data.memories[].{memory_id, content}
//! - moot_memory_list    → structuredContent.data.memories[].{memory_id}
//!
//! # moot_distill is a RETIRED ALIAS in v2
//! The catalog lists it under negative_catalog_assertions with
//! absent_reason: "Retired alias." Callers must return
//! `Err(LaneError::Config("moot_distill is retired on ARIA v2 surface..."))`.
//! Use `refused_distill_call()` to build that error string.

use std::collections::BTreeMap;
use crate::json_value::JsonValue;

// ─────────────────────────────────────────────────────────────────────────────
// Core memory tools
// ─────────────────────────────────────────────────────────────────────────────

/// File a durable memory with explicit subject and placement.
/// v2 required args: `content`, `subject`, `location`. Optional: `wing`.
pub const FILE_MEMORY: &str = "moot_file_memory";

/// Search memories by query, returning compact authorised rows.
/// v2 scope key: `wing` (v1 used `location`).
/// v2 args: `query` OR `near` (oneOf), optional `wing`, `limit`, `estate_id`.
/// v1 `ordering` and `location` args are GONE in v2.
pub const MEMORY_SEARCH: &str = "moot_memory_search";

/// Fetch one or a bounded batch of authorised memories by UUID.
/// v2 keys: `memory_id` (scalar) or `memory_ids` (batch); v1 used `id`/`ids`.
pub const MEMORY_GET: &str = "moot_memory_get";

/// Enumerate a complete authorised structural memory inventory.
/// v2 accepts `wing`, `room`, `filter` (enum: "missing_subject"), `limit`, `cursor`.
pub const MEMORY_LIST: &str = "moot_memory_list";

// ─────────────────────────────────────────────────────────────────────────────
// Recall lenses
// ─────────────────────────────────────────────────────────────────────────────

/// Named precision composition recall.
pub const RECALL_PRECISE: &str = "moot_recall_precise";

/// Signed-weight fusion recall (shaped retrieval).
pub const RECALL_SHAPED: &str = "moot_recall_shaped";

/// Compact distilled memory projections recall.
/// v2: no `ack` argument — the gate was removed in v2.
pub const RECALL_DISTILLED: &str = "moot_recall_distilled";

// NOTE: RECALL_VAGUE and RECALL_CONNECTED are valid v2 tools but are unused
// in the harness runners. They are omitted to keep the adapter surface tight.

// ─────────────────────────────────────────────────────────────────────────────
// Maintenance operations
// ─────────────────────────────────────────────────────────────────────────────

/// Dream pass — generates associations and surfaces contradictions.
pub const DREAM: &str = "moot_dream";

/// Reindex — rebuilds the vector and BM25 indices.
pub const REINDEX: &str = "moot_reindex";

/// Synthesise — produce a grounded summary over a query window.
pub const SYNTHESIZE: &str = "moot_synthesize";

// NOTE: DISTILL ("moot_distill") is a RETIRED ALIAS in ARIA v2 and is absent
// from this adapter. Callers must use refused_distill_call() to build the
// LaneError::Config string and return it immediately without calling call_tool.

// ─────────────────────────────────────────────────────────────────────────────
// Import tools
// ─────────────────────────────────────────────────────────────────────────────

/// JSON import from a local file path.
/// v2 args: `path`, optional `estate_id`. `mode` is GONE in v2.
/// Requires vault capability — not available on default scratch estates.
pub const JSON_IMPORT: &str = "moot_json_import";

// ─────────────────────────────────────────────────────────────────────────────
// Facts and knowledge-graph
// ─────────────────────────────────────────────────────────────────────────────

/// File a KG fact.
pub const FILE_FACT: &str = "moot_file_fact";

/// Search KG facts.
pub const FACT_SEARCH: &str = "moot_fact_search";

/// Retire a KG fact.
pub const RETIRE_FACT: &str = "moot_retire_fact";

/// Hunt for contradictions across the estate.
pub const HUNT_CONTRADICTIONS: &str = "moot_hunt_contradictions";

/// Contradiction lens — used by the supersession runner's fact-hunt pass.
pub const LENS_CONTRADICTION: &str = "moot_lens_contradiction";

// ─────────────────────────────────────────────────────────────────────────────
// Diagnostics
// ─────────────────────────────────────────────────────────────────────────────

/// Encode-queue drain status.
pub const DRAIN_STATUS: &str = "moot_drain_status";

/// Per-operation timing report.
pub const TIMING_REPORT: &str = "moot_timing_report";

// ─────────────────────────────────────────────────────────────────────────────
// Request builders — the adapter owns every argument key shape
// ─────────────────────────────────────────────────────────────────────────────

/// Build the argument dict for a `moot_memory_search` call.
///
/// v2 replaced the `location` scope key with `wing`. This builder remaps
/// `constant_args["location"]` → `"wing"` so every runner routes the
/// translation through one place. All other constant args pass through
/// unchanged.
///
/// # Arguments
/// * `constant_args` — The VerbMap's constant_args (typically
///   `{"location": "benchmarks/<dataset>"}`).
/// * `query` — The query string.
///
/// Returns an argument map ready for `client.call_tool(MEMORY_SEARCH, ...)`.
pub fn memory_search_args(
    constant_args: &BTreeMap<String, String>,
    query: &str,
) -> BTreeMap<String, JsonValue> {
    let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
    args.insert("query".to_string(), JsonValue::String(query.to_string()));
    for (k, v) in constant_args {
        // v2 renamed the scope key: `location` (v1) → `wing` (v2)
        // on moot_memory_search. moot_file_memory still uses `location`.
        let mapped_key = if k == "location" { "wing" } else { k.as_str() };
        args.insert(mapped_key.to_string(), JsonValue::String(v.clone()));
    }
    args
}

/// Build the argument dict for `moot_memory_get` (scalar form).
/// v2 replaced the `id` key with `memory_id`.
pub fn memory_get_args(memory_id: &str, depth: Option<&str>) -> BTreeMap<String, JsonValue> {
    let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
    args.insert("memory_id".to_string(), JsonValue::String(memory_id.to_string()));
    if let Some(d) = depth {
        args.insert("depth".to_string(), JsonValue::String(d.to_string()));
    }
    args
}

/// Build the argument dict for `moot_memory_get` (batch form).
/// v2 replaced the `ids` key with `memory_ids`.
pub fn memory_get_batch_args(
    memory_ids: &[&str],
    depth: Option<&str>,
) -> BTreeMap<String, JsonValue> {
    let mut args: BTreeMap<String, JsonValue> = BTreeMap::new();
    args.insert(
        "memory_ids".to_string(),
        JsonValue::Array(
            memory_ids
                .iter()
                .map(|id| JsonValue::String(id.to_string()))
                .collect(),
        ),
    );
    if let Some(d) = depth {
        args.insert("depth".to_string(), JsonValue::String(d.to_string()));
    }
    args
}

/// Return the typed lane-fatal error string for a moot_distill call.
///
/// moot_distill is listed in the v2 catalog's negative_catalog_assertions
/// with absent_reason: "Retired alias." The dense arm must refuse without
/// attempting the call. Both ports produce identical behaviour: Swift throws
/// AriaV2SurfaceError.retiredOperation; Rust returns LaneError::Config.
///
/// Call site in the dense arm:
///   replace `client.call_tool(DISTILL, args, &format)?`
///   with     `return Err(LaneError::Config(aria_v2_surface::refused_distill_call()))`
pub fn refused_distill_call() -> String {
    "moot_distill is retired on the ARIA v2 surface \
     (negative_catalog_assertions absent_reason: \"Retired alias.\"). \
     No equivalent operation exists on v2; the dense arm refuses."
        .to_string()
}
