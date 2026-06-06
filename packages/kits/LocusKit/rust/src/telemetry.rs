//! LocusKit IntellectusLib self-report telemetry — cp-locuskit-report.
//!
//! This module provides the emit helper functions called at operation
//! boundaries in `DrawerStoreCore`. All emit calls go through the
//! `report!` macro from `intellectus_lib`, which is a no-op when
//! monitoring is disabled (the default). Off-path cost: one `AtomicBool`
//! load + branch (~1 ns), no lock, no allocation.
//!
//! ## Metric namespace
//!
//! `locuskit.<noun>.<field>` — consistent with `vectorkit.*` and
//! `neuronkit.*` used in sibling kits:
//!
//! - `locuskit.drawer.capture_latency_ms`   — wall time for `add_drawer`
//! - `locuskit.drawer.capture_count`        — increment per successful add_drawer
//! - `locuskit.drawer.query_latency_ms`     — wall time for drawer queries
//! - `locuskit.drawer.query_result_count`   — rows returned by drawer queries
//! - `locuskit.kgfact.add_count`            — increment per successful add_kg_fact
//! - `locuskit.kgfact.query_result_count`   — rows returned by KGFact queries
//! - `locuskit.tunnel.add_count`            — increment per successful add_tunnel
//!
//! ## Tags
//!
//! Every metric carries an `estate` tag (the estate UUID string) so
//! per-estate statistics are queryable and tests can filter by estate
//! to avoid cross-test pollution from concurrent runs. Query-path
//! metrics also carry a `query` tag labelling the query variant
//! ("wing", "wing_room", "all", "drawer").
//!
//! ## Determinism contract
//!
//! The `now_secs` timestamp is always the epoch-seconds value derived
//! from the caller-supplied `now: i64` argument to the store method.
//! The `start` `Instant` is captured at operation entry (before I/O).
//! Elapsed is computed inside the `report!` body, which is never
//! evaluated when monitoring is disabled — no clock is read on the
//! off-path.
//!
//! ## Two emit calls per compound operation
//!
//! Operations like `add_drawer` emit both a latency metric and a count
//! metric. Each gets its own `report!` call — the enabled-path guard is
//! checked twice (two atomic loads), which is acceptable because both
//! are inside the same already-enabled monitoring window in practice.
//! The pattern mirrors the Swift implementation which calls
//! `Intellectus.report(_:)` twice per operation.
//!
//! Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 + MANAGER_1.0_PLAN §4.

use intellectus_lib::{StatSample, report};
use std::time::Instant;
use uuid::Uuid;

// ─────────────────────────────────────────────────────────────────
// Drawer capture telemetry
// ─────────────────────────────────────────────────────────────────

/// Emit drawer-capture (add) metrics at the `add_drawer` operation boundary.
///
/// Called after the write completes inside `DrawerStoreCore::add_drawer`.
/// The `start` instant is captured before the storage round-trip so the
/// latency reflects the full path-write cost including gate validation.
///
/// Emits two metrics:
/// - `locuskit.drawer.capture_latency_ms`: wall time from operation entry.
/// - `locuskit.drawer.capture_count`: 1.0 per successful capture event.
///
/// Tags: `estate` — estate UUID string.
/// Off-path cost when monitoring is disabled: two `AtomicBool` loads.
#[inline(always)]
pub(crate) fn emit_drawer_capture(start: &Instant, now_secs: f64, estate: &Uuid) {
    let estate_tag = estate.to_string();
    // Latency metric: wall time from method entry to post-write boundary.
    // Provides per-estate drawer ingest cost for dashboard funnel.
    report!({
        let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
        let mut tags = std::collections::HashMap::new();
        tags.insert("estate".to_string(), estate_tag.clone());
        StatSample::metric(
            "locuskit.drawer.capture_latency_ms".to_string(),
            elapsed_ms,
            tags,
            now_secs,
        )
    });
    // Count metric: one unit per successful capture. Separate counter
    // so the Activity view can show total ingested drawers per estate
    // without needing to aggregate the latency histogram.
    report!({
        let mut tags = std::collections::HashMap::new();
        tags.insert("estate".to_string(), estate_tag.clone());
        StatSample::metric(
            "locuskit.drawer.capture_count".to_string(),
            1.0,
            tags,
            now_secs,
        )
    });
}

// ─────────────────────────────────────────────────────────────────
// Drawer query telemetry
// ─────────────────────────────────────────────────────────────────

/// Emit drawer-query (read) metrics at the query operation boundary.
///
/// Called after the result `Vec<Drawer>` is assembled inside
/// `DrawerStoreCore::drawers_in_wing`, `drawers_in_wing_room`, and
/// `all_drawers`.
///
/// Emits two metrics:
/// - `locuskit.drawer.query_latency_ms`: wall time for the query.
/// - `locuskit.drawer.query_result_count`: number of drawers returned.
///
/// Tags: `estate`, `query` — query label: "wing", "wing_room", or "all".
#[inline(always)]
pub(crate) fn emit_drawer_query(
    start: &Instant,
    now_secs: f64,
    result_count: usize,
    estate: &Uuid,
    query_label: &str,
) {
    let estate_tag = estate.to_string();
    let query_tag = query_label.to_string();
    // Latency metric: full query cost including storage scan.
    report!({
        let elapsed_ms = start.elapsed().as_secs_f64() * 1000.0;
        let mut tags = std::collections::HashMap::new();
        tags.insert("estate".to_string(), estate_tag.clone());
        tags.insert("query".to_string(), query_tag.clone());
        StatSample::metric(
            "locuskit.drawer.query_latency_ms".to_string(),
            elapsed_ms,
            tags,
            now_secs,
        )
    });
    // Result count metric: how many drawers were returned.
    // Useful for detecting empty-wing and large-corpus conditions.
    report!({
        let mut tags = std::collections::HashMap::new();
        tags.insert("estate".to_string(), estate_tag.clone());
        tags.insert("query".to_string(), query_tag.clone());
        StatSample::metric(
            "locuskit.drawer.query_result_count".to_string(),
            result_count as f64,
            tags,
            now_secs,
        )
    });
}

// ─────────────────────────────────────────────────────────────────
// KGFact telemetry
// ─────────────────────────────────────────────────────────────────

/// Emit a KGFact-add metric at the `add_kg_fact` operation boundary.
///
/// Called after the insert completes inside `DrawerStoreCore::add_kg_fact`.
///
/// Emits one metric:
/// - `locuskit.kgfact.add_count`: 1.0 per successful insertion.
///
/// Tags: `estate`. Tracks knowledge-graph growth rate per estate.
#[inline(always)]
pub(crate) fn emit_kgfact_add(now_secs: f64, estate: &Uuid) {
    let estate_tag = estate.to_string();
    report!({
        let mut tags = std::collections::HashMap::new();
        tags.insert("estate".to_string(), estate_tag.clone());
        StatSample::metric(
            "locuskit.kgfact.add_count".to_string(),
            1.0,
            tags,
            now_secs,
        )
    });
}

/// Emit a KGFact-query metric at the query operation boundary.
///
/// Called after the result `Vec<KGFact>` is assembled inside
/// `DrawerStoreCore::kg_facts_for_drawer` and `all_kg_facts`.
///
/// Emits one metric:
/// - `locuskit.kgfact.query_result_count`: number of facts returned.
///
/// Tags: `estate`, `query` — "drawer" for per-drawer path, "all" for
/// the estate-wide path. Correlates with recall-graph density.
#[inline(always)]
pub(crate) fn emit_kgfact_query(
    now_secs: f64,
    result_count: usize,
    estate: &Uuid,
    query_label: &str,
) {
    let estate_tag = estate.to_string();
    let query_tag = query_label.to_string();
    report!({
        let mut tags = std::collections::HashMap::new();
        tags.insert("estate".to_string(), estate_tag.clone());
        tags.insert("query".to_string(), query_tag.clone());
        StatSample::metric(
            "locuskit.kgfact.query_result_count".to_string(),
            result_count as f64,
            tags,
            now_secs,
        )
    });
}

// ─────────────────────────────────────────────────────────────────
// Tunnel telemetry
// ─────────────────────────────────────────────────────────────────

/// Emit a tunnel-add metric at the `add_tunnel` operation boundary.
///
/// Called after the insert completes inside `DrawerStoreCore::add_tunnel`.
///
/// Emits one metric:
/// - `locuskit.tunnel.add_count`: 1.0 per successful tunnel insertion.
///
/// Tags: `estate`. Tracks link density growth between drawers.
#[inline(always)]
pub(crate) fn emit_tunnel_add(now_secs: f64, estate: &Uuid) {
    let estate_tag = estate.to_string();
    report!({
        let mut tags = std::collections::HashMap::new();
        tags.insert("estate".to_string(), estate_tag.clone());
        StatSample::metric(
            "locuskit.tunnel.add_count".to_string(),
            1.0,
            tags,
            now_secs,
        )
    });
}
