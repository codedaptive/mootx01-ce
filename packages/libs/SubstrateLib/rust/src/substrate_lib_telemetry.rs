// substrate_lib_telemetry.rs
//
// Self-report telemetry emission helpers for substrate-lib.
// Parity file: Swift/Sources/SubstrateLib/SubstrateLibTelemetry.swift
//
// ## Off-path guarantee
//
// Every emit is wrapped in the `report!` macro, which expands to
// `if Intellectus::is_enabled() { report_sample(make()) }`. When
// monitoring is disabled (the default), the macro body is never
// entered and the `StatSample` struct is never constructed. Off-path
// cost: one `AtomicBool::load(Acquire)` + branch. No allocation,
// no lock acquisition.
//
// ## Determinism
//
// Timestamps are caller-supplied (`ts` parameter as `f64` epoch seconds).
// No clock is ever read inside this module. The caller stamps once at
// the verb boundary; the helpers pass the value straight to the sample.
//
// ## Metric names (parity with Swift port)
//
// All names and tag keys in this file must exactly match the Swift
// `SubstrateLibMetric` constants. The test suite validates parity.
//
//   substratelib.audit_gate.admit_count   — per successful AuditGate.admit
//   substratelib.audit_gate.reject_count  — per rejected AuditGate.admit
//   substratelib.verb.capture_count       — per successful Substrate::capture
//   substratelib.verb.mutate_count        — per successful Substrate::mutate
//   substratelib.verb.withdraw_count      — per successful Substrate::withdraw
//   substratelib.verb.expunge_count       — per successful Substrate::expunge
//   substratelib.verb.recall_count        — per Substrate::recall call
//   substratelib.verb.reanchor_count      — per successful Substrate::reanchor
//   substratelib.write_gate.admitted_count — per admitted write (AuditGate)
//   substratelib.write_gate.rejected_count — per rejected write (AuditGate)

use intellectus_lib::{StatSample, report};

// ─────────────────────────────────────────────────────────────────
// Metric name constants
// ─────────────────────────────────────────────────────────────────

/// Metric names for the `substratelib.*` namespace.
///
/// All emission points reference these constants so the catalogue is
/// discoverable in one place. Parity with Swift's `SubstrateLibMetric`.
pub mod metric {
    /// Incremented once per successful `AuditGate::admit`.
    pub const AUDIT_GATE_ADMIT_COUNT: &str = "substratelib.audit_gate.admit_count";
    /// Incremented once per rejected `AuditGate::admit`.
    pub const AUDIT_GATE_REJECT_COUNT: &str = "substratelib.audit_gate.reject_count";
    /// Incremented once per successful `Substrate::capture`.
    pub const VERB_CAPTURE_COUNT: &str = "substratelib.verb.capture_count";
    /// Incremented once per successful `Substrate::mutate`.
    pub const VERB_MUTATE_COUNT: &str = "substratelib.verb.mutate_count";
    /// Incremented once per successful `Substrate::withdraw`.
    pub const VERB_WITHDRAW_COUNT: &str = "substratelib.verb.withdraw_count";
    /// Incremented once per successful `Substrate::expunge`.
    pub const VERB_EXPUNGE_COUNT: &str = "substratelib.verb.expunge_count";
    /// Incremented once per `Substrate::recall` call.
    pub const VERB_RECALL_COUNT: &str = "substratelib.verb.recall_count";
    /// Incremented once per successful `Substrate::reanchor`.
    pub const VERB_REANCHOR_COUNT: &str = "substratelib.verb.reanchor_count";
    /// Incremented once per admitted write through `AuditGate::admit`.
    pub const WRITE_GATE_ADMITTED_COUNT: &str = "substratelib.write_gate.admitted_count";
    /// Incremented once per rejected write through `AuditGate::admit`.
    pub const WRITE_GATE_REJECTED_COUNT: &str = "substratelib.write_gate.rejected_count";
}

// ─────────────────────────────────────────────────────────────────
// Emit helpers: AuditGate
// ─────────────────────────────────────────────────────────────────

/// Emit `substratelib.audit_gate.admit_count` for a successful admit.
///
/// Off-path cost when monitoring is disabled: one `AtomicBool::load(Acquire)`
/// + branch; `StatSample` is never constructed.
///
/// # Parameters
/// - `noun_type_raw`: The NounType ordinal as a string, for the `noun_type` tag.
/// - `ts`: Caller-supplied epoch seconds. Never read a clock here.
#[inline(always)]
pub fn emit_audit_gate_admit(noun_type_raw: &str, ts: f64) {
    report!(StatSample::metric(
        metric::AUDIT_GATE_ADMIT_COUNT.into(),
        1.0,
        [("noun_type".to_string(), noun_type_raw.to_string())].into(),
        ts,
    ));
}

/// Emit `substratelib.audit_gate.reject_count` for a gate violation.
///
/// # Parameters
/// - `violation_name`: Short name for the `GateViolation` case.
/// - `ts`: Caller-supplied epoch seconds.
#[inline(always)]
pub fn emit_audit_gate_reject(violation_name: &str, ts: f64) {
    report!(StatSample::metric(
        metric::AUDIT_GATE_REJECT_COUNT.into(),
        1.0,
        [("violation".to_string(), violation_name.to_string())].into(),
        ts,
    ));
}

// ─────────────────────────────────────────────────────────────────
// Emit helpers: Write-gate decisions
// ─────────────────────────────────────────────────────────────────

/// Emit `substratelib.write_gate.admitted_count` when a write is admitted.
///
/// # Parameters
/// - `verb`: The verb string passed to the admit call.
/// - `ts`: Caller-supplied epoch seconds.
#[inline(always)]
pub fn emit_write_gate_admitted(verb: &str, ts: f64) {
    report!(StatSample::metric(
        metric::WRITE_GATE_ADMITTED_COUNT.into(),
        1.0,
        [("verb".to_string(), verb.to_string())].into(),
        ts,
    ));
}

/// Emit `substratelib.write_gate.rejected_count` when a write is rejected.
///
/// # Parameters
/// - `verb`: The verb string passed to the admit call.
/// - `reason`: A short string describing the rejection cause.
/// - `ts`: Caller-supplied epoch seconds.
#[inline(always)]
pub fn emit_write_gate_rejected(verb: &str, reason: &str, ts: f64) {
    report!(StatSample::metric(
        metric::WRITE_GATE_REJECTED_COUNT.into(),
        1.0,
        [
            ("verb".to_string(), verb.to_string()),
            ("reason".to_string(), reason.to_string()),
        ]
        .into(),
        ts,
    ));
}

// ─────────────────────────────────────────────────────────────────
// Emit helpers: Verb activity
// ─────────────────────────────────────────────────────────────────

/// Emit `substratelib.verb.capture_count` after a successful capture.
///
/// # Parameters
/// - `noun_type_raw`: NounType ordinal string for the `noun_type` tag.
/// - `ts`: Caller-supplied epoch seconds.
#[inline(always)]
pub fn emit_verb_capture_count(noun_type_raw: &str, ts: f64) {
    report!(StatSample::metric(
        metric::VERB_CAPTURE_COUNT.into(),
        1.0,
        [("noun_type".to_string(), noun_type_raw.to_string())].into(),
        ts,
    ));
}

/// Emit `substratelib.verb.mutate_count` after a successful mutate.
///
/// # Parameters
/// - `mutation_kind_token`: The mutation kind token string.
/// - `ts`: Caller-supplied epoch seconds.
#[inline(always)]
pub fn emit_verb_mutate_count(mutation_kind_token: &str, ts: f64) {
    report!(StatSample::metric(
        metric::VERB_MUTATE_COUNT.into(),
        1.0,
        [("mutation_kind".to_string(), mutation_kind_token.to_string())].into(),
        ts,
    ));
}

/// Emit `substratelib.verb.withdraw_count` after a successful withdraw.
///
/// # Parameters
/// - `ts`: Caller-supplied epoch seconds.
#[inline(always)]
pub fn emit_verb_withdraw_count(ts: f64) {
    report!(StatSample::metric(
        metric::VERB_WITHDRAW_COUNT.into(),
        1.0,
        Default::default(),
        ts,
    ));
}

/// Emit `substratelib.verb.expunge_count` after a successful expunge.
///
/// # Parameters
/// - `ts`: Caller-supplied epoch seconds.
#[inline(always)]
pub fn emit_verb_expunge_count(ts: f64) {
    report!(StatSample::metric(
        metric::VERB_EXPUNGE_COUNT.into(),
        1.0,
        Default::default(),
        ts,
    ));
}

/// Emit `substratelib.verb.recall_count` after a recall call returns.
///
/// # Parameters
/// - `result_count`: Number of rows returned by the recall.
/// - `ts`: Caller-supplied epoch seconds.
#[inline(always)]
pub fn emit_verb_recall_count(result_count: usize, ts: f64) {
    report!(StatSample::metric(
        metric::VERB_RECALL_COUNT.into(),
        1.0,
        [("result_count".to_string(), result_count.to_string())].into(),
        ts,
    ));
}

/// Emit `substratelib.verb.reanchor_count` after a successful reanchor.
///
/// # Parameters
/// - `ts`: Caller-supplied epoch seconds.
#[inline(always)]
pub fn emit_verb_reanchor_count(ts: f64) {
    report!(StatSample::metric(
        metric::VERB_REANCHOR_COUNT.into(),
        1.0,
        Default::default(),
        ts,
    ));
}
