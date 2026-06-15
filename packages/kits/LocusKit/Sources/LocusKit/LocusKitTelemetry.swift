// LocusKitTelemetry.swift
//
// IntellectusLib self-report telemetry for LocusKit — cp-locuskit-report.
//
// Design notes:
//   - All emit functions call Intellectus.report(_:) with an @autoclosure.
//     When monitoring is disabled (the default), the autoclosure is NEVER
//     evaluated. Off-path cost: one Atomic<Bool> load + branch (~1 ns).
//     No lock on the off-path. No allocation. Results are byte-identical
//     to the non-telemetry path (telemetry is additive; the store's
//     functional return values are never affected).
//   - The `now` parameter is always caller-supplied epoch seconds (Double).
//     Never read a clock inside a telemetry emit function — the clock was
//     already read at the operation boundary in DrawerStore (or the caller
//     passes it from the operation's `now: Date` parameter converted to
//     timeIntervalSince1970). This upholds IntellectusLib's determinism
//     contract (callers supply timestamps; the lib never reads a clock).
//   - Metric namespace: `locuskit.<noun>.<operation>` and
//     `locuskit.<noun>.<field>` — consistent with the vectorkit.* and
//     neuronkit.* naming used in sibling kits.
//   - Tags are kept small: `estate` (UUID string) identifies the estate.
//     Additional per-operation tags (`result_count`, `kind`) are included
//     where useful for funnel analysis (MANAGER_1.0_PLAN §4, GUI §4.4).
//
// Authority: DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28 + MANAGER_1.0_PLAN §4.

import Foundation
import IntellectusLib

// MARK: - Drawer telemetry

/// Emit a drawer-capture (add) metric.
///
/// Called at the end of `DrawerStore.addDrawer` / `gatedCapture`, after the
/// write completes. The `start` is captured before the storage round-trip so
/// the latency reflects the full path-write cost.
///
/// `locuskit.drawer.capture_latency_ms`: wall time from method entry to
/// operation boundary (includes gate validation + storage write).
/// `locuskit.drawer.capture_count`: increment-by-1 counter for each
/// successful capture event.
///
/// Tags: `estate` — the estate UUID string identifying the estate.
///
/// - Parameters:
///   - start: Epoch seconds when DrawerStore.addDrawer was entered.
///   - now: Epoch seconds at the operation boundary (post-write).
///   - estateTag: The estate UUID string.
@inline(__always)
func emitDrawerCapture(start: Double, now: Double, estateTag: String) {
    // Latency: wall time from start to now, in milliseconds.
    // Provides per-estate drawer ingest cost for dashboard funnel.
    Intellectus.report(.metric(
        name: "locuskit.drawer.capture_latency_ms",
        value: (now - start) * 1000.0,
        tags: ["estate": estateTag],
        ts: now
    ))
    // Count: one unit per successful capture.
    // Separate counter so the Activity view can show total ingested drawers
    // per estate without needing to aggregate the latency histogram.
    Intellectus.report(.metric(
        name: "locuskit.drawer.capture_count",
        value: 1.0,
        tags: ["estate": estateTag],
        ts: now
    ))
}

// MARK: - Drawer query telemetry

/// Emit a drawer-query (read) metric.
///
/// Called at the end of `DrawerStore.drawersIn` / `allDrawers` and similar
/// bulk-read methods, after the result array is populated.
///
/// `locuskit.drawer.query_latency_ms`: wall time for the query.
/// `locuskit.drawer.query_result_count`: number of drawers returned.
///
/// Tags: `estate`, `query` — `query` is a short label (e.g. "wing",
/// "wing_room", "all") so per-query-path latency is queryable.
///
/// - Parameters:
///   - start: Epoch seconds when the query method was entered.
///   - now: Epoch seconds at the operation boundary (post-query).
///   - resultCount: Number of drawers returned by the query.
///   - estateTag: The estate UUID string.
///   - queryLabel: Short label for the query path (e.g. "wing", "all").
@inline(__always)
func emitDrawerQuery(start: Double, now: Double, resultCount: Int,
                     estateTag: String, queryLabel: String) {
    // Latency: wall time from entry to result-ready.
    Intellectus.report(.metric(
        name: "locuskit.drawer.query_latency_ms",
        value: (now - start) * 1000.0,
        tags: ["estate": estateTag, "query": queryLabel],
        ts: now
    ))
    // Result count: drawers returned; useful for detecting empty-wing
    // and large-corpus conditions.
    Intellectus.report(.metric(
        name: "locuskit.drawer.query_result_count",
        value: Double(resultCount),
        tags: ["estate": estateTag, "query": queryLabel],
        ts: now
    ))
}

// MARK: - KGFact telemetry

/// Emit a KGFact-add metric.
///
/// Called at the end of `DrawerStore.addKGFact`, after the insert completes.
///
/// `locuskit.kgfact.add_count`: one unit per successful KGFact insertion.
///
/// Tags: `estate`.
///
/// - Parameters:
///   - now: Epoch seconds at the operation boundary.
///   - estateTag: The estate UUID string.
@inline(__always)
func emitKGFactAdd(now: Double, estateTag: String) {
    // Count: tracks knowledge-graph growth rate per estate.
    Intellectus.report(.metric(
        name: "locuskit.kgfact.add_count",
        value: 1.0,
        tags: ["estate": estateTag],
        ts: now
    ))
}

/// Emit a KGFact-query metric.
///
/// Called at the end of `DrawerStore.kgFacts(forDrawerID:)` and
/// `DrawerStore.allKGFacts()`, after the result array is populated.
///
/// `locuskit.kgfact.query_result_count`: number of facts returned.
///
/// Tags: `estate`, `query` — "drawer" for the per-drawer path, "all" for
/// the estate-wide path.
///
/// - Parameters:
///   - now: Epoch seconds at the operation boundary.
///   - resultCount: Number of KGFacts returned.
///   - estateTag: The estate UUID string.
///   - queryLabel: Short label: "drawer" or "all".
@inline(__always)
func emitKGFactQuery(now: Double, resultCount: Int,
                     estateTag: String, queryLabel: String) {
    // Result count: how many facts the KG surface is returning per
    // recall; correlates with recall-graph density.
    Intellectus.report(.metric(
        name: "locuskit.kgfact.query_result_count",
        value: Double(resultCount),
        tags: ["estate": estateTag, "query": queryLabel],
        ts: now
    ))
}

// MARK: - Tunnel telemetry

/// Emit a tunnel-add metric.
///
/// Called at the end of `DrawerStore.addTunnel`, after the insert completes.
///
/// `locuskit.tunnel.add_count`: one unit per successful tunnel insertion.
///
/// Tags: `estate`.
///
/// - Parameters:
///   - now: Epoch seconds at the operation boundary.
///   - estateTag: The estate UUID string.
@inline(__always)
func emitTunnelAdd(now: Double, estateTag: String) {
    // Count: tracks link density growth between drawers.
    Intellectus.report(.metric(
        name: "locuskit.tunnel.add_count",
        value: 1.0,
        tags: ["estate": estateTag],
        ts: now
    ))
}

// MARK: - Write-gate telemetry

/// Emit a write-gate ADMIT event (the write passed validation).
///
/// Called from DrawerStore.gatedCapture after AuditGate.admit succeeds.
///
/// `locuskit.gate.admit_count`: value 1.0 per admitted write.
///
/// Tags: `estate`.
///
/// - Parameters:
///   - now: Epoch seconds at the gate decision point.
///   - estateTag: The estate UUID string.
@inline(__always)
func emitGateAdmit(now: Double, estateTag: String) {
    // Count: one unit per write that passed AuditGate.admit validation.
    // Correlates with successful capture volume for the estate.
    Intellectus.report(.metric(
        name: "locuskit.gate.admit_count",
        value: 1.0,
        tags: ["estate": estateTag],
        ts: now
    ))
}

/// Emit a write-gate REJECT event (the write failed validation).
///
/// Called from DrawerStore.gatedCapture when AuditGate.admit returns failure.
///
/// `locuskit.gate.reject_count`: value 1.0 per rejected write.
///
/// Tags: `estate`, `reason` — reason is the gate's violation description,
/// truncated to 64 characters to bound tag cardinality.
///
/// - Parameters:
///   - now: Epoch seconds at the gate decision point.
///   - estateTag: The estate UUID string.
///   - reason: The gate violation description.
@inline(__always)
func emitGateReject(now: Double, estateTag: String, reason: String) {
    // Count: one unit per write that failed AuditGate.admit validation.
    // Non-zero values indicate schema / vocabulary violations at the write boundary.
    // Reason tag truncated to 64 chars to bound metric-tag cardinality.
    let truncatedReason = reason.count > 64 ? String(reason.prefix(64)) : reason
    Intellectus.report(.metric(
        name: "locuskit.gate.reject_count",
        value: 1.0,
        tags: ["estate": estateTag, "reason": truncatedReason],
        ts: now
    ))
}
