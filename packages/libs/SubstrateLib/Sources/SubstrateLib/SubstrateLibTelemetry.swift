// SubstrateLibTelemetry.swift
//
// Self-report telemetry emission helpers for SubstrateLib.
//
// SubstrateLib is the determinism floor of the substrate stack — it
// must never read a clock, introduce non-determinism, or change the
// functional output of any verb based on monitoring state. The emit
// helpers in this file satisfy those invariants:
//
//   1. Every emit is wrapped in `Intellectus.report(...)`, which is a
//      single `Atomic<Bool>.load(.acquiring) + branch` when monitoring
//      is disabled (the default). No metric is constructed, no lock
//      is acquired, and no allocation occurs on the off-path. The
//      substrate's functional behavior is byte-identical whether
//      monitoring is on or off.
//
//   2. Timestamps are caller-supplied (`ts` parameter as epoch seconds
//      Double). No clock is ever read inside this file or inside any
//      SubstrateLib source. The caller stamps once at the verb boundary
//      and passes the value down; the verb helpers pass it to the emit
//      functions.
//
//   3. Counts and outcomes are derived from values already computed
//      by the verb path — no extra work is done on the off-path.
//
// Mirror: rust/src/substrate_lib_telemetry.rs
//
// Metric shapes (parity table — exact names and tag keys are shared
// between Swift and Rust ports):
//
//   substratelib.audit_gate.admit_count
//     kind: metric, value: 1.0 per successful admit
//     tags: ["noun_type": "<raw>"], ts: epoch seconds
//
//   substratelib.audit_gate.reject_count
//     kind: metric, value: 1.0 per rejected admit (GateViolation)
//     tags: ["violation": "<violation-name>"], ts: epoch seconds
//
//   substratelib.verb.capture_count
//     kind: metric, value: 1.0 per successful Substrate.capture
//     tags: ["noun_type": "<raw>"], ts: epoch seconds
//
//   substratelib.verb.mutate_count
//     kind: metric, value: 1.0 per successful Substrate.mutate
//     tags: ["mutation_kind": "<token>"], ts: epoch seconds
//
//   substratelib.verb.withdraw_count
//     kind: metric, value: 1.0 per successful Substrate.withdraw
//     tags: [:], ts: epoch seconds
//
//   substratelib.verb.expunge_count
//     kind: metric, value: 1.0 per successful Substrate.expunge
//     tags: [:], ts: epoch seconds
//
//   substratelib.verb.recall_count
//     kind: metric, value: 1.0 per Substrate.recall call
//     tags: ["result_count": "<n>"], ts: epoch seconds
//
//   substratelib.verb.reanchor_count
//     kind: metric, value: 1.0 per successful Substrate.reanchor
//     tags: [:], ts: epoch seconds
//
//   substratelib.write_gate.admitted_count
//     kind: metric, value: 1.0 per successful AuditGate.admit
//     tags: ["verb": "<verb>"], ts: epoch seconds
//
//   substratelib.write_gate.rejected_count
//     kind: metric, value: 1.0 per rejected AuditGate.admit
//     tags: ["verb": "<verb>", "reason": "<reason>"], ts: epoch seconds

import IntellectusLib

// MARK: - Metric name constants

/// Metric name constants for the `substratelib.*` namespace.
///
/// All emission points reference these constants rather than inline
/// string literals, so the complete metric catalogue is discoverable
/// in one place and typos are caught at compile time.
enum SubstrateLibMetric {

    // MARK: AuditGate metrics

    /// Incremented once per successful `AuditGate.admit` call.
    static let auditGateAdmitCount = "substratelib.audit_gate.admit_count"

    /// Incremented once per rejected `AuditGate.admit` call (GateViolation).
    static let auditGateRejectCount = "substratelib.audit_gate.reject_count"

    // MARK: Verb activity metrics

    /// Incremented once per successful `Substrate.capture`.
    static let verbCaptureCount = "substratelib.verb.capture_count"

    /// Incremented once per successful `Substrate.mutate`.
    static let verbMutateCount = "substratelib.verb.mutate_count"

    /// Incremented once per successful `Substrate.withdraw`.
    static let verbWithdrawCount = "substratelib.verb.withdraw_count"

    /// Incremented once per successful `Substrate.expunge`.
    static let verbExpungeCount = "substratelib.verb.expunge_count"

    /// Incremented once per `Substrate.recall` call.
    static let verbRecallCount = "substratelib.verb.recall_count"

    /// Incremented once per successful `Substrate.reanchor`.
    static let verbReanchorCount = "substratelib.verb.reanchor_count"

    // MARK: Write-gate decision metrics

    /// Incremented once per admitted write through `AuditGate.admit`.
    static let writeGateAdmittedCount = "substratelib.write_gate.admitted_count"

    /// Incremented once per rejected write through `AuditGate.admit`.
    static let writeGateRejectedCount = "substratelib.write_gate.rejected_count"
}

// MARK: - Emit helpers: AuditGate

/// Emit `substratelib.audit_gate.admit_count` for a successful admit.
///
/// Call this after `AuditGate.admit` returns `.success`. The `nounType`
/// raw value is included as a tag so callers can break down admit
/// traffic by noun type.
///
/// Off-path guarantee: when `Intellectus.isEnabled` is false this
/// function returns after a single atomic load with no allocation.
///
/// - Parameters:
///   - nounTypeRaw: `NounType.rawValue` as a String for the tag
///   - ts:          epoch seconds (caller-supplied — never read a clock here)
@inline(__always)
func emitAuditGateAdmit(nounTypeRaw: String, ts: Double) {
    // Disabled path: single atomic load + branch; no metric constructed.
    Intellectus.report(.metric(
        name: SubstrateLibMetric.auditGateAdmitCount,
        value: 1.0,
        tags: ["noun_type": nounTypeRaw],
        ts: ts
    ))
}

/// Emit `substratelib.audit_gate.reject_count` for a gate violation.
///
/// Call this after `AuditGate.admit` returns `.failure`. The violation
/// name is included as a tag so operators can distinguish vocabulary
/// errors from transition errors.
///
/// - Parameters:
///   - violationName: short name for the `GateViolation` case
///   - ts:            epoch seconds (caller-supplied)
@inline(__always)
func emitAuditGateReject(violationName: String, ts: Double) {
    Intellectus.report(.metric(
        name: SubstrateLibMetric.auditGateRejectCount,
        value: 1.0,
        tags: ["violation": violationName],
        ts: ts
    ))
}

// MARK: - Emit helpers: Write-gate decisions

/// Emit `substratelib.write_gate.admitted_count` when a write is
/// admitted through `AuditGate.admit`.
///
/// - Parameters:
///   - verb: the verb string passed to the admit call
///   - ts:   epoch seconds (caller-supplied)
@inline(__always)
func emitWriteGateAdmitted(verb: String, ts: Double) {
    Intellectus.report(.metric(
        name: SubstrateLibMetric.writeGateAdmittedCount,
        value: 1.0,
        tags: ["verb": verb],
        ts: ts
    ))
}

/// Emit `substratelib.write_gate.rejected_count` when a write is
/// rejected through `AuditGate.admit`.
///
/// - Parameters:
///   - verb:   the verb string passed to the admit call
///   - reason: a short string describing the rejection cause
///   - ts:     epoch seconds (caller-supplied)
@inline(__always)
func emitWriteGateRejected(verb: String, reason: String, ts: Double) {
    Intellectus.report(.metric(
        name: SubstrateLibMetric.writeGateRejectedCount,
        value: 1.0,
        tags: ["verb": verb, "reason": reason],
        ts: ts
    ))
}

// MARK: - Emit helpers: Verb activity

/// Emit `substratelib.verb.capture_count` after a successful capture.
///
/// - Parameters:
///   - nounTypeRaw: `NounType.rawValue` as a String for the tag
///   - ts:          epoch seconds (caller-supplied)
@inline(__always)
func emitVerbCaptureCount(nounTypeRaw: String, ts: Double) {
    Intellectus.report(.metric(
        name: SubstrateLibMetric.verbCaptureCount,
        value: 1.0,
        tags: ["noun_type": nounTypeRaw],
        ts: ts
    ))
}

/// Emit `substratelib.verb.mutate_count` after a successful mutate.
///
/// - Parameters:
///   - mutationKindToken: the mutation kind token string
///   - ts:                epoch seconds (caller-supplied)
@inline(__always)
func emitVerbMutateCount(mutationKindToken: String, ts: Double) {
    Intellectus.report(.metric(
        name: SubstrateLibMetric.verbMutateCount,
        value: 1.0,
        tags: ["mutation_kind": mutationKindToken],
        ts: ts
    ))
}

/// Emit `substratelib.verb.withdraw_count` after a successful withdraw.
///
/// - Parameters:
///   - ts: epoch seconds (caller-supplied)
@inline(__always)
func emitVerbWithdrawCount(ts: Double) {
    Intellectus.report(.metric(
        name: SubstrateLibMetric.verbWithdrawCount,
        value: 1.0,
        tags: [:],
        ts: ts
    ))
}

/// Emit `substratelib.verb.expunge_count` after a successful expunge.
///
/// - Parameters:
///   - ts: epoch seconds (caller-supplied)
@inline(__always)
func emitVerbExpungeCount(ts: Double) {
    Intellectus.report(.metric(
        name: SubstrateLibMetric.verbExpungeCount,
        value: 1.0,
        tags: [:],
        ts: ts
    ))
}

/// Emit `substratelib.verb.recall_count` after a recall call returns.
///
/// Note: recall is a pure read — it always emits on completion
/// (regardless of result count, which may be zero). The count is
/// included as a tag for drill-down.
///
/// - Parameters:
///   - resultCount: number of rows returned by the recall
///   - ts:          epoch seconds (caller-supplied)
@inline(__always)
func emitVerbRecallCount(resultCount: Int, ts: Double) {
    Intellectus.report(.metric(
        name: SubstrateLibMetric.verbRecallCount,
        value: 1.0,
        tags: ["result_count": "\(resultCount)"],
        ts: ts
    ))
}

/// Emit `substratelib.verb.reanchor_count` after a successful reanchor.
///
/// - Parameters:
///   - ts: epoch seconds (caller-supplied)
@inline(__always)
func emitVerbReanchorCount(ts: Double) {
    Intellectus.report(.metric(
        name: SubstrateLibMetric.verbReanchorCount,
        value: 1.0,
        tags: [:],
        ts: ts
    ))
}
