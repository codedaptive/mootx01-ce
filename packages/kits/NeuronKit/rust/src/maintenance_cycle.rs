//! The maintenance daemon's per-cycle ORCHESTRATION (NEURONKIT_SPEC § 3.2
//! and § 3.5 steps 0-6) over seam traits, the Rust parity of the Swift
//! `MaintenanceDaemon` actor's `runCycle`. Where `maintenance_decision`
//! owns the DECISIONS (key formats, scan order, thresholds, B-4 dedup),
//! this module owns the SEQUENCE: read the gathered scan inputs from the
//! reader seam, delegate to `maintenance_decision::decide`, emit one
//! proposal per cleared decision (the proposal kind chosen from the
//! category), carry `proposed_keys` across cycles, and write exactly one
//! diary entry (step 6).
//!
//! ── Same seam boundary as dreaming_cycle ─────────────────────────────
//! The estate-bound reads (active/tombstoned drawers, the I-3 secret-AND-
//! public bitmap, the drift observations) and the GLK-owned
//! `AuditChainVerifier.verify` are the ADAPTER's job; the reader seam
//! yields their identity-free results (the `maintenance_decision` input
//! shapes + an `AuditVerdict`). The write seam's `propose` goes through
//! `EstateMaintenanceSink` (the production adapter, shipped in both Swift
//! and Rust). The Rust adapter calls `store.add_proposal` directly
//! (B-1-compliant; no GLK coordinator needed in the sync Rust port).
//! The orchestration is gated with deterministic fakes mirroring the
//! Swift MaintenanceDaemonTests.
//!
//! Determinism: no clock, no RNG. The daemon carries `cycle_count`; all
//! time-derived inputs (ages, the audit verdict) arrive through the seam.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use intellectus_lib::{report, StatSample};

use crate::lattice_anchor::EnrichmentStatus;
use crate::maintenance_decision::{self, AgedRow, AuditVerdict, Category, DriftRow};

/// One drawer's node-tree data for node-tree integrity invariant verification. The
/// adapter populates these from the same active-drawer scan it uses for
/// decay/forbidden checks; the daemon verifies I-NT-3 (non-empty
/// parent_node_id) and sibling display-name consistency.
#[derive(Clone, Debug, PartialEq)]
pub struct NodeInvariantRow {
    pub drawer_id: String,
    pub parent_node_id: String,
    pub wing: String,
    pub room: String,
}

/// A proposal the sink receives. No Rust `ProposeFrame` estate type exists
/// (propose is Brain-layer); `kind` is the proposal-kind tag.
#[derive(Clone, Debug, PartialEq)]
pub struct ProposeFrameOut {
    pub target: String,
    pub kind: String,
    pub justification: String,
}

/// The one diary entry a cycle writes (step 6). The integer/bool summary is
/// byte-identical to the Swift actor's.
#[derive(Clone, Debug, PartialEq)]
pub struct MaintenanceDiaryEntry {
    pub agent_name: String,
    pub entry: String,
    pub topic: String,
    pub wing: String,
    pub room: String,
}

/// What one maintenance cycle did — the Rust parity of
/// `MaintenanceCycleReport`.
#[derive(Clone, Debug, PartialEq)]
pub struct MaintenanceCycleReport {
    pub audit_checked: bool,
    pub proposals_emitted: Vec<ProposeFrameOut>,
    pub decay_candidates: usize,
    pub tombstone_candidates: usize,
    pub forbidden_combinations: usize,
    pub fingerprint_drifts: usize,
    pub by_reference_drifts: usize,
    pub suppressed_duplicates: usize,
    pub diary_entry: MaintenanceDiaryEntry,
    // ── QID-pending enrichment retry telemetry (Board item 14) ────────
    /// Drawers with enrichment-status `qid_pending` that the daemon
    /// attempted to retry this cycle (capped at `QID_RETRY_SCAN_CAP`).
    /// Emitted as `neuronkit.enrichment.qid_retry`.
    pub qid_retried: usize,
    /// Retried drawers for which Q-ID resolution succeeded (enrichment
    /// status flipped to `qid_completed`). Emitted as
    /// `neuronkit.enrichment.qid_resolved`.
    pub qid_resolved: usize,
    /// Retried drawers that deterministic re-inference could not resolve and
    /// for which the daemon therefore filed an enrichment proposal and flipped
    /// the status to the terminal in-workflow state `qid_proposed`. These leave
    /// the retry backlog. Emitted as `neuronkit.enrichment.qid_proposed`.
    pub qid_proposed: usize,
    /// Retried drawers that remain `qid_pending` after this cycle SOLELY
    /// because the substrate write failed (a real runtime failure) — never a
    /// deterministic re-inference miss, which now terminates as `qid_proposed`.
    /// Emitted as `neuronkit.enrichment.qid_still_pending`.
    pub qid_still_pending: usize,
    // ── node-tree invariant verification telemetry ────────────────
    /// Number of node-tree invariant violations detected this
    /// cycle. Covers I-NT-3 (empty parent_node_id) and sibling display-name
    /// consistency. Emitted as `neuronkit.node_invariant.violations`.
    pub node_invariant_violations: usize,
}

/// Maintenance health-scan parameters the cycle reads, mirroring the Swift
/// `MaintenancePolicy` fields the decision uses (NEURONKIT_SPEC § 3.2).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct MaintenancePolicy {
    /// Tick cadence in milliseconds (spec default 300_000 / 5 minutes).
    pub tick_interval_ms: i64,
    /// How often the audit chain is re-verified, in milliseconds
    /// (spec default 300_000 / 5 minutes).
    pub audit_check_interval_ms: i64,
    /// Age past which an active drawer is a decay candidate, in seconds
    /// (spec default 2_592_000 / 30 days).
    pub decay_window_seconds: f64,
    /// Grace period past which a tombstoned drawer is an expunge candidate,
    /// in seconds (spec default 604_800 / 7 days).
    pub tombstone_grace_seconds: f64,
    /// Per-room/wing fingerprint Hamming-distance drift fraction past which
    /// a fingerprint-drift proposal is emitted (spec default 0.25).
    pub fingerprint_drift_threshold: f32,
    /// LearnedReference source-drift threshold (spec default 0.25).
    pub by_reference_drift_threshold: f32,
}

impl Default for MaintenancePolicy {
    /// Spec defaults (NEURONKIT_SPEC § 3.2):
    /// 300_000 / 300_000 / 30d / 7d / 0.25 / 0.25.
    fn default() -> Self {
        Self {
            tick_interval_ms: 300_000,
            audit_check_interval_ms: 300_000,
            decay_window_seconds: 2_592_000.0,
            tombstone_grace_seconds: 604_800.0,
            fingerprint_drift_threshold: 0.25,
            by_reference_drift_threshold: 0.25,
        }
    }
}

/// Persistence seam for the maintenance policy ("substrate-resident in
/// manifest", NEURONKIT_SPEC § 3.2).
///
/// The daemon never touches the manifest directly (B-1). It loads and
/// saves the policy through this trait. The production adapter binds
/// these methods to the estate manifest once GLK exposes a manifest
/// accessor; until then the seam is satisfied by an in-memory store.
/// Mirrors `MaintenancePolicyStore` (Swift `MaintenancePolicy.swift`).
pub trait MaintenancePolicyStore {
    /// Load the persisted policy, or `None` if none has been saved (the
    /// daemon then falls back to `MaintenancePolicy::default()`).
    fn load_policy(&self) -> Option<MaintenancePolicy>;

    /// Persist the policy. Subsequent `load_policy()` calls return it.
    fn save_policy(&mut self, policy: MaintenancePolicy);

    /// Load the persisted daemon cycle state, or `None` if none has been saved.
    /// Loaded once at governor construction so a restart continues from the prior
    /// run's idempotency/cycle memory. Default: no state persisted.
    /// Mirrors Swift `MaintenancePolicyStore.loadDaemonState`.
    fn load_daemon_state(&self) -> Option<MaintenanceDaemonState> {
        None
    }

    /// Persist the daemon cycle state. The governor calls this after each cycle.
    /// Default: discard (in-memory only); the manifest-backed store overrides it.
    /// Mirrors Swift `MaintenancePolicyStore.saveDaemonState`.
    fn save_daemon_state(&mut self, _state: MaintenanceDaemonState) {}
}

/// The maintenance daemon's across-cycle state, captured for persistence so a
/// restart continues instead of repeating suppressed proposals or resetting its
/// counters. `proposed_keys` is a SORTED Vec so the serialized
/// manifest value is byte-stable. Mirrors Swift `MaintenanceDaemonState`:
/// `last_fire_epoch_secs` ≡ `lastTickAt` (scan-tick baseline) and
/// `last_audit_check_epoch_secs` ≡ `lastAuditCheckAt` (audit-check cadence,
/// tracked independently of the scan tick — § 3.5).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MaintenanceDaemonState {
    pub last_fire_epoch_secs: Option<f64>,
    pub last_audit_check_epoch_secs: Option<f64>,
    pub proposed_keys: Vec<String>,
    pub cycle_count: i64,
}

/// In-memory `MaintenancePolicyStore` for tests and for hosts that do not
/// persist policy across process restarts.
/// Mirrors `InMemoryMaintenancePolicyStore` (Swift `MaintenancePolicy.swift`).
#[derive(Clone, Debug, Default)]
pub struct InMemoryMaintenancePolicyStore {
    stored: Option<MaintenancePolicy>,
}

impl InMemoryMaintenancePolicyStore {
    /// Create an empty store, or seed it with an initial policy.
    pub fn new(initial: Option<MaintenancePolicy>) -> Self {
        Self { stored: initial }
    }
}

impl MaintenancePolicyStore for InMemoryMaintenancePolicyStore {
    fn load_policy(&self) -> Option<MaintenancePolicy> {
        self.stored
    }

    fn save_policy(&mut self, policy: MaintenancePolicy) {
        self.stored = Some(policy);
    }
}

/// One active drawer whose enrichment status is `qid_pending`, extracted by
/// the reader seam for the QID-pending retry batch (Board item 14). The daemon
/// calls `infer_lattice_anchor(content)` and, on success (wikidata_qid != None),
/// calls `MaintenanceProposalSink::update_enrichment_status` to flip the status
/// bits to `qid_completed`. The `provenance` value is the full current bitmap
/// so the daemon can construct the new value without re-reading.
///
/// B-10a: the reader seam returns these rows through an internal maintenance
/// read — no trace_limit, no recall-trace rows written.
#[derive(Clone, Debug)]
pub struct QidPendingRow {
    /// The drawer's stable row ID.
    pub id: String,
    /// The drawer's text content, passed to `infer_lattice_anchor` on retry.
    pub content: String,
    /// The drawer's current full provenance bitmap (bits 36-41 == 1, QidPending).
    pub provenance: i64,
}

/// The gathered, identity-free scan inputs for one cycle — what the reader
/// seam produces after the estate reads, bitmap predicate, age
/// subtractions, and audit verify the adapter performs. The decision core
/// consumes these directly.
#[derive(Clone, Debug, Default)]
pub struct MaintenanceScan {
    /// The audit verdict when the chain was checked this cycle, else `None`.
    pub audit: Option<AuditVerdict>,
    /// Active drawers failing invariant I-3 (secret AND public).
    pub forbidden_drawer_ids: Vec<String>,
    /// `(id, age_seconds)` for active drawers (decay scan).
    pub aged_active: Vec<AgedRow>,
    /// `(id, tombstone_age_seconds)` for tombstoned drawers.
    pub aged_tombstoned: Vec<AgedRow>,
    /// `(scope_key, drift_fraction)` fingerprint observations.
    pub fingerprint_drift: Vec<DriftRow>,
    /// `(reference_id, source_drift_fraction)` learned-reference observations.
    pub reference_drift: Vec<DriftRow>,
    /// Active drawers with enrichment-status `qid_pending` (provenance bits
    /// 36-41 == 1, cookbook §2.5), capped at `QID_RETRY_SCAN_CAP` rows.
    /// The daemon retries each row via `infer_lattice_anchor`; on success the
    /// status is flipped to `qid_completed` via the sink.
    pub qid_pending_drawers: Vec<QidPendingRow>,
    /// Active drawers' node-tree data for node-tree integrity invariant verification
    /// (I-NT-3 empty parent_node_id, sibling display-name consistency).
    pub node_invariant_rows: Vec<NodeInvariantRow>,
}

/// Read seam: yields the gathered scan inputs for one cycle.
pub trait MaintenanceSubstrateReader {
    fn scan(&self) -> MaintenanceScan;
}

/// Write seam: emit a proposal, record the cycle diary, and (for the QID-
/// pending retry batch) update a drawer's enrichment-status provenance bits.
///
/// The `update_enrichment_status` method is the ONLY write the daemon is
/// permitted to make to a drawer's provenance. It is strictly additive:
/// `new_provenance` is the caller-computed full 64-bit value with bits 36-41
/// set to `qid_completed` (2); no other bits are changed. Routes through the
/// estate verb surface in the production adapter (B-1).
pub trait MaintenanceProposalSink {
    fn propose(&mut self, frame: ProposeFrameOut);
    fn record_cycle_diary(&mut self, entry: MaintenanceDiaryEntry);
    /// Update a drawer's provenance bitmap after a successful QID-pending retry
    /// (Board item 14). Called only when `infer_lattice_anchor` returns a
    /// non-`None` `wikidata_qid`. `new_provenance` has bits 36-41 set to
    /// `qid_completed` (2), all other bits identical to the row's prior value.
    /// `now_epoch_secs` is the deterministic cycle timestamp.
    fn update_enrichment_status(
        &mut self,
        row_id: &str,
        new_provenance: i64,
        now_epoch_secs: f64,
    );
}

const AGENT_NAME: &str = "maintenance-daemon";
const DIARY_WING: &str = "wing_maintenance-daemon";

/// Maximum number of qid-pending drawers the daemon picks up in a single
/// retry batch. Mirrors `QID_RETRY_SCAN_CAP` in
/// `GeniusLocusKit/Brain/EnrichmentRetryReads.swift` (64 rows). Bounded
/// so the retry scan is O(cap) per cycle; large estates converge over
/// successive cycles.
const QID_RETRY_SCAN_CAP: usize = 64;

/// The proposal-kind tag for a decision category, mirroring the Swift
/// actor's `ProposalKind` choices (audit/fingerprint via the `.other`
/// escape hatch; decay+tombstone both `mutateCandidate`).
fn kind_tag(category: Category) -> &'static str {
    match category {
        Category::AuditIntegrity => "other:audit_integrity",
        Category::DisciplineViolation => "disciplineViolation",
        Category::Decay => "mutateCandidate",
        Category::Tombstone => "mutateCandidate",
        Category::FingerprintDrift => "other:fingerprint_drift",
        Category::ByReferenceDrift => "byReferenceDrift",
    }
}

/// The maintenance daemon's across-cycle state and cycle driver — the Rust
/// parity of the Swift `MaintenanceDaemon` actor (without the async/timer
/// machinery, which is the runtime's concern).
pub struct MaintenanceDaemon {
    pub policy: MaintenancePolicy,
    proposed_keys: std::collections::BTreeSet<String>,
    cycle_count: i64,
    /// Epoch-seconds timestamp of the last `pump` fire, or `None` on first
    /// call. Used by `pump` for interval gating — the daemon never reads the
    /// system clock; the caller injects `now`. Mirrors Swift `lastTickAt`.
    last_fire_epoch_secs: Option<f64>,
    /// Epoch-seconds timestamp of the last audit-chain integrity check, or `None`
    /// before the first check. The audit check runs on its own cadence
    /// (`policy.audit_check_interval_ms`), tracked independently of the scan tick
    /// so a slow full-chain verify need not run every cycle (§ 3.5). Mirrors
    /// Swift `lastAuditCheckAt`.
    last_audit_check_epoch_secs: Option<f64>,
}

impl MaintenanceDaemon {
    pub fn new(policy: MaintenancePolicy) -> Self {
        Self {
            policy,
            proposed_keys: std::collections::BTreeSet::new(),
            cycle_count: 0,
            last_fire_epoch_secs: None,
            last_audit_check_epoch_secs: None,
        }
    }

    /// Export the daemon's across-cycle state for persistence.
    /// `proposed_keys` is emitted sorted (BTreeSet iterates in order) so the
    /// serialized value is byte-stable. Mirrors Swift `currentDaemonState()`.
    pub fn daemon_state(&self) -> MaintenanceDaemonState {
        MaintenanceDaemonState {
            last_fire_epoch_secs: self.last_fire_epoch_secs,
            last_audit_check_epoch_secs: self.last_audit_check_epoch_secs,
            proposed_keys: self.proposed_keys.iter().cloned().collect(),
            cycle_count: self.cycle_count,
        }
    }

    /// Restore the daemon's across-cycle state from persistence.
    /// Called once at governor construction so a restart resumes the prior run's
    /// idempotency/cycle memory.
    pub fn restore_state(&mut self, state: MaintenanceDaemonState) {
        self.last_fire_epoch_secs = state.last_fire_epoch_secs;
        self.last_audit_check_epoch_secs = state.last_audit_check_epoch_secs;
        self.proposed_keys = state.proposed_keys.into_iter().collect();
        self.cycle_count = state.cycle_count;
    }

    /// Interval-gated pump — the entry point for the resident loop.
    ///
    /// Mirrors Swift `MaintenanceDaemon.pump(now:)`:
    /// - First call always fires (no prior fire timestamp).
    /// - Subsequent calls fire only when `policy.tick_interval_ms` has elapsed
    ///   since the last fire.
    /// - Returns `Some(report)` when the cycle ran, `None` when the interval
    ///   has not elapsed.
    ///
    /// DETERMINISM: `now_epoch_secs` is injected by the caller. The daemon
    /// never reads `SystemTime::now()`. The caller (the resident pump loop)
    /// reads the clock once per tick and passes it to every daemon, guaranteeing
    /// that all daemons in a single tick operate on the same `now`.
    pub fn pump<R, S>(
        &mut self,
        now_epoch_secs: f64,
        reader: &R,
        sink: &mut S,
    ) -> Option<MaintenanceCycleReport>
    where
        R: MaintenanceSubstrateReader,
        S: MaintenanceProposalSink,
    {
        // Gate: fire if this is the first call or the interval has elapsed.
        // Guard: treat a future `last_fire_epoch_secs` (a persisted timestamp
        // ahead of `now`) as "never fired" and fire immediately. A future epoch
        // can arise from a system clock warp backward (NTP step, VM snapshot
        // restore, test fixture injection). Without this guard, the gate would
        // return `now - future < interval` (a large negative ≥ interval only
        // after the clock catches up), permanently blocking the maintenance cycle.
        // Mirrors Swift `MaintenanceDaemon.due(now:)` nil-guard discipline and
        // aligns with the Rust `due()` guard below. (NK-16 planned hardening)
        let interval_secs = self.policy.tick_interval_ms as f64 / 1000.0;
        let should_fire = match self.last_fire_epoch_secs {
            None => true, // first call always fires
            Some(last) => last > now_epoch_secs || (now_epoch_secs - last) >= interval_secs,
        };
        if !should_fire {
            return None;
        }
        self.last_fire_epoch_secs = Some(now_epoch_secs);
        Some(self.run_cycle(now_epoch_secs, reader, sink))
    }

    /// Cheap predicate: would `pump(now)` fire at `now`? Lets the resident
    /// governor SKIP building the EstateMaintenanceReader snapshot on ticks where
    /// the interval has not elapsed (maintenance fires every 5 min by default but
    /// the governor ticks sub-second). Mirrors the gate inside `pump`; does NOT
    /// mutate state. Swift twin: `MaintenanceDaemon.due(now:)`.
    ///
    /// Guard: treat a future `last_fire_epoch_secs` as "never fired" and report
    /// due = true. A future epoch can arise from a clock warp backward; the guard
    /// here mirrors the `pump` guard above. (NK-16 planned hardening)
    pub fn due(&self, now_epoch_secs: f64) -> bool {
        let interval_secs = self.policy.tick_interval_ms as f64 / 1000.0;
        match self.last_fire_epoch_secs {
            None => true,
            Some(last) => last > now_epoch_secs || (now_epoch_secs - last) >= interval_secs,
        }
    }

    /// Run one maintenance cycle (steps 0-6) against the seams. Mirrors
    /// `MaintenanceDaemon.runCycle`.
    ///
    /// DETERMINISM: `now_epoch_secs` is the injected timestamp the caller
    /// supplies. Neither dreaming nor maintenance reads the system clock
    /// internally; the clock is owned by the resident pump loop.
    pub fn run_cycle<R, S>(
        &mut self,
        now_epoch_secs: f64,
        reader: &R,
        sink: &mut S,
    ) -> MaintenanceCycleReport
    where
        R: MaintenanceSubstrateReader,
        S: MaintenanceProposalSink,
    {
        let scan = reader.scan();

        // ── Step 0: audit-chain integrity monitor cadence (§ 3.5) ──────────
        // The audit verdict is consumed only when DUE, tracked independently of
        // the scan tick via `last_audit_check_epoch_secs` so a slow full-chain
        // verify need not run every cycle. First run always checks (None). Mirrors
        // Swift `MaintenanceDaemon.runCycle` step 0 (`lastAuditCheckAt` /
        // `auditCheckIntervalMs`). With the default config (audit interval == tick
        // interval) the check runs every fired cycle, identical to the prior
        // behavior; the cadence only diverges from the tick when an operator sets
        // `audit_check_interval_ms` larger than `tick_interval_ms`.
        //
        // NOTE: the reader's `scan()` computes the verdict every call; gating it
        // here matches Swift's OBSERVABLE behavior (verdict consumed / proposal
        // emitted only on the audit cadence) and state shape. Avoiding the verify
        // work entirely when not due would require splitting the reader seam — a
        // performance refinement, not a parity concern (no proposal/state effect).
        let audit_due = match self.last_audit_check_epoch_secs {
            None => true,
            Some(last) => {
                (now_epoch_secs - last) * 1000.0 >= self.policy.audit_check_interval_ms as f64
            }
        };
        let audit_input = if audit_due { scan.audit } else { None };
        if audit_due {
            self.last_audit_check_epoch_secs = Some(now_epoch_secs);
        }
        let audit_checked = audit_due;

        // Delegate every decision to the pure core (steps 0-5).
        let outcome = maintenance_decision::decide(&maintenance_decision::Inputs {
            audit: audit_input,
            forbidden_drawer_ids: &scan.forbidden_drawer_ids,
            aged_active: &scan.aged_active,
            decay_window_seconds: self.policy.decay_window_seconds,
            aged_tombstoned: &scan.aged_tombstoned,
            tombstone_grace_seconds: self.policy.tombstone_grace_seconds,
            fingerprint_drift: &scan.fingerprint_drift,
            fingerprint_drift_threshold: self.policy.fingerprint_drift_threshold,
            reference_drift: &scan.reference_drift,
            by_reference_drift_threshold: self.policy.by_reference_drift_threshold,
            already_proposed_keys: &self.proposed_keys,
        });
        // B-4 idempotency: a key enters the "already proposed" memory ONLY
        // after its proposal is written — committed per-key in the loop below,
        // not wholesale here. The current sink seam is infallible so this
        // ordering is presently inert, but it keeps parity with the Swift
        // daemon (whose sink can throw) so a future fallible Rust sink cannot
        // reintroduce the permanent-suppression bug.

        // Emit one proposal per cleared decision, in the core's scan order.
        let mut proposals_emitted: Vec<ProposeFrameOut> = Vec::new();
        for d in &outcome.emitted {
            let detail = d.detail_value.map(|v| v.to_string()).unwrap_or_default();
            let frame = ProposeFrameOut {
                target: d.target.clone(),
                kind: kind_tag(d.category).to_string(),
                justification: format!("maintenance: {:?} on {} {}", d.category, d.target, detail),
            };
            sink.propose(frame.clone());
            self.proposed_keys.insert(d.key.clone());
            proposals_emitted.push(frame);
        }

        // ── Step 5.5: QID-pending enrichment retry + completion (Board item
        // 14 + Q-ID-completion terminal workflow) ─────────────────────────
        //
        // Re-run `infer_lattice_anchor` for each drawer supplied by the reader
        // seam (bounded to `QID_RETRY_SCAN_CAP` rows). Two terminal outcomes —
        // no drawer is left in passive qid_pending after a cycle:
        //
        //   • RESOLVED (wikidata_qid != None): flip enrichment-status bits
        //     (36-41) from qid_pending (1) to qid_completed (2) via the sink.
        //
        //   • UNRESOLVED (wikidata_qid == None): deterministic re-inference
        //     produced no Q-ID, so retrying again is futile (same pinned
        //     artifacts → same nil). Leaving the row at qid_pending would be
        //     DURABLE pending state, which the beta gate forbids. Instead the
        //     daemon files a real enrichment proposal (kind "enrichment",
        //     carrying the drawer target + resolved MDCC code) and flips the
        //     status to the terminal in-workflow state qid_proposed (4). The
        //     qid_pending scan does not re-pick qid_proposed rows, so the row
        //     leaves the retry backlog; proposal acceptance completes it.
        //
        // Provenance bit arithmetic:
        //   mask  = 0x3F << 36  (6-bit field, shift 36)
        //   new   = (old & !mask) | (status.raw() << 36)
        //
        // B-10a: the reader returned these rows through an internal maintenance
        // scan — no trace_limit, no recall-trace rows written.
        // Determinism: `now_epoch_secs` is the caller's injected clock.
        let qid_batch = &scan.qid_pending_drawers;
        let qid_retried = qid_batch.len().min(QID_RETRY_SCAN_CAP);
        // Emit qid_retry counter before processing (Swift parity).
        {
            let mut tags = std::collections::HashMap::new();
            tags.insert("cycle".to_string(), (self.cycle_count + 1).to_string());
            report!(StatSample::metric(
                "neuronkit.enrichment.qid_retry".to_string(),
                qid_retried as f64,
                tags,
                now_epoch_secs,
            ));
        }
        let mut qid_resolved: usize = 0;
        let mut qid_proposed: usize = 0;
        // qid_still_pending is reserved for a real substrate-write failure. The
        // current sink seam's writes are infallible (the production adapter
        // surfaces host failures out of band), so no censused inference outcome
        // ends here — both RESOLVED and UNRESOLVED reach a terminal state.
        let qid_still_pending: usize = 0;
        let enrichment_status_mask: i64 = 0x3F << 36;

        for row in qid_batch.iter().take(QID_RETRY_SCAN_CAP) {
            let inference = crate::infer_lattice_anchor(&row.content);
            if inference.wikidata_qid.is_some() {
                // RESOLVED: flip bits 36-41 to qid_completed (2).
                let new_provenance = (row.provenance & !enrichment_status_mask)
                    | (i64::from(EnrichmentStatus::QidCompleted.raw()) << 36);
                sink.update_enrichment_status(&row.id, new_provenance, now_epoch_secs);
                qid_resolved += 1;
            } else {
                // UNRESOLVED: file an enrichment proposal and move to the
                // terminal in-workflow state qid_proposed (4). `inference.code`
                // is empty only for a wholly-unresolved concept (Mode C); record
                // "unresolved" in that case so reviewers know no code was found.
                let code_context = if inference.code.is_empty() {
                    "unresolved".to_string()
                } else {
                    inference.code.clone()
                };
                sink.propose(ProposeFrameOut {
                    target: row.id.clone(),
                    kind: "enrichment".to_string(),
                    justification: format!(
                        "maintenance: Q-ID unresolved by deterministic inference for \
drawer {} (mdcc: {}); enrichment proposal filed for human/agent Q-ID assignment",
                        row.id, code_context
                    ),
                });
                let new_provenance = (row.provenance & !enrichment_status_mask)
                    | (i64::from(EnrichmentStatus::QidProposed.raw()) << 36);
                sink.update_enrichment_status(&row.id, new_provenance, now_epoch_secs);
                qid_proposed += 1;
            }
        }

        // Emit per-cycle QID outcome counters (Swift parity: qid_resolved,
        // qid_proposed, qid_still_pending).
        {
            let cycle_tag = (self.cycle_count + 1).to_string();
            let mut tags_resolved = std::collections::HashMap::new();
            tags_resolved.insert("cycle".to_string(), cycle_tag.clone());
            report!(StatSample::metric(
                "neuronkit.enrichment.qid_resolved".to_string(),
                qid_resolved as f64,
                tags_resolved,
                now_epoch_secs,
            ));
            let mut tags_proposed = std::collections::HashMap::new();
            tags_proposed.insert("cycle".to_string(), cycle_tag.clone());
            report!(StatSample::metric(
                "neuronkit.enrichment.qid_proposed".to_string(),
                qid_proposed as f64,
                tags_proposed,
                now_epoch_secs,
            ));
            let mut tags_pending = std::collections::HashMap::new();
            tags_pending.insert("cycle".to_string(), cycle_tag);
            report!(StatSample::metric(
                "neuronkit.enrichment.qid_still_pending".to_string(),
                qid_still_pending as f64,
                tags_pending,
                now_epoch_secs,
            ));
        }

        // ── Step 5.9: node-tree invariant verification ────────────
        // Verify a subset of node-tree containment invariants from
        // the drawer corpus already gathered by the adapter. Full invariant
        // verification (I-NT-1 through I-NT-6) requires node-table access
        // not yet exposed through the GLK public surface.
        //
        //   I-NT-3 (partial): every drawer must have a non-empty parent_node_id.
        //   Consistency: drawers sharing a parent_node_id must have consistent
        //   wing/room display names.
        let mut node_invariant_violations: usize = 0;
        for row in &scan.node_invariant_rows {
            if row.parent_node_id.is_empty() {
                node_invariant_violations += 1;
                let mut tags = std::collections::HashMap::new();
                tags.insert("drawer_id".to_string(), row.drawer_id.clone());
                report!(StatSample::metric(
                    "neuronkit.node_invariant.empty_parent".to_string(),
                    1.0,
                    tags,
                    now_epoch_secs,
                ));
            }
        }
        let mut node_groups: BTreeMap<String, (String, String)> = BTreeMap::new();
        for row in &scan.node_invariant_rows {
            if row.parent_node_id.is_empty() {
                continue;
            }
            if let Some(existing) = node_groups.get(&row.parent_node_id) {
                if existing.0 != row.wing || existing.1 != row.room {
                    node_invariant_violations += 1;
                }
            } else {
                node_groups.insert(
                    row.parent_node_id.clone(),
                    (row.wing.clone(), row.room.clone()),
                );
            }
        }

        // Per-cycle violation counter (Swift parity).
        {
            let mut tags = std::collections::HashMap::new();
            tags.insert("cycle".to_string(), (self.cycle_count + 1).to_string());
            report!(StatSample::metric(
                "neuronkit.node_invariant.violations".to_string(),
                node_invariant_violations as f64,
                tags,
                now_epoch_secs,
            ));
        }

        // Step 6: exactly one diary entry; the summary is byte-identical to
        // the Swift actor's (diary text includes QID and node-invariant
        // telemetry).
        self.cycle_count += 1;
        let entry = MaintenanceDiaryEntry {
            agent_name: AGENT_NAME.to_string(),
            entry: format!(
                "maintenance cycle {}: audit-checked {}, forbidden {}, decay {}, \
tombstone {}, fingerprint-drift {}, byReference-drift {}, proposed {}, suppressed {}, \
qid-retried {}, qid-resolved {}, qid-proposed {}, qid-pending {}, \
node-invariant-violations {}",
                self.cycle_count,
                audit_checked,
                outcome.forbidden_combinations,
                outcome.decay_candidates,
                outcome.tombstone_candidates,
                outcome.fingerprint_drifts,
                outcome.by_reference_drifts,
                proposals_emitted.len(),
                outcome.suppressed_duplicates,
                qid_retried,
                qid_resolved,
                qid_proposed,
                qid_still_pending,
                node_invariant_violations
            ),
            topic: "maintenance-cycle".to_string(),
            wing: DIARY_WING.to_string(),
            room: "diary".to_string(),
        };
        sink.record_cycle_diary(entry.clone());

        MaintenanceCycleReport {
            audit_checked,
            proposals_emitted,
            decay_candidates: outcome.decay_candidates,
            tombstone_candidates: outcome.tombstone_candidates,
            forbidden_combinations: outcome.forbidden_combinations,
            fingerprint_drifts: outcome.fingerprint_drifts,
            by_reference_drifts: outcome.by_reference_drifts,
            suppressed_duplicates: outcome.suppressed_duplicates,
            diary_entry: entry,
            qid_retried,
            qid_resolved,
            qid_proposed,
            qid_still_pending,
            node_invariant_violations,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeReader {
        scan: MaintenanceScan,
    }
    impl MaintenanceSubstrateReader for FakeReader {
        fn scan(&self) -> MaintenanceScan {
            self.scan.clone()
        }
    }

    #[derive(Default)]
    struct RecordingSink {
        proposals: Vec<ProposeFrameOut>,
        diaries: Vec<MaintenanceDiaryEntry>,
        /// (row_id, new_provenance) pairs from QID-pending retry writes.
        enrichment_updates: Vec<(String, i64)>,
    }
    impl MaintenanceProposalSink for RecordingSink {
        fn propose(&mut self, frame: ProposeFrameOut) {
            self.proposals.push(frame);
        }
        fn record_cycle_diary(&mut self, entry: MaintenanceDiaryEntry) {
            self.diaries.push(entry);
        }
        fn update_enrichment_status(
            &mut self,
            row_id: &str,
            new_provenance: i64,
            _now_epoch_secs: f64,
        ) {
            self.enrichment_updates.push((row_id.to_string(), new_provenance));
        }
    }

    fn aged(id: &str, age: f64) -> AgedRow {
        AgedRow {
            id: id.to_string(),
            age_seconds: age,
        }
    }
    fn drift(key: &str, f: f32) -> DriftRow {
        DriftRow {
            key: key.to_string(),
            drift_fraction: f,
        }
    }

    fn full_scan() -> MaintenanceScan {
        MaintenanceScan {
            audit: Some(AuditVerdict {
                valid: true,
                first_broken_at_millis: None,
                rejected_entry_count: 0,
            }),
            forbidden_drawer_ids: vec!["d-forbidden".to_string()],
            aged_active: vec![aged("d-old", 3_000_000.0), aged("d-forbidden", 1.0)],
            aged_tombstoned: vec![aged("d-tomb", 700_000.0)],
            fingerprint_drift: vec![drift("wing_a/room_b", 0.5)],
            reference_drift: vec![drift("ref-1", 0.5)],
            qid_pending_drawers: vec![],
            node_invariant_rows: vec![],
        }
    }

    // MC-1: all five scan categories emit (valid chain adds no audit
    // proposal); the report counts and the single diary entry are assembled.
    #[test]
    fn mc1_all_five_categories_emit_and_report() {
        let reader = FakeReader { scan: full_scan() };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);

        assert_eq!(report.proposals_emitted.len(), 5);
        assert_eq!(report.forbidden_combinations, 1);
        assert_eq!(report.decay_candidates, 1);
        assert_eq!(report.tombstone_candidates, 1);
        assert_eq!(report.fingerprint_drifts, 1);
        assert_eq!(report.by_reference_drifts, 1);
        assert!(report.audit_checked);
        // decay + tombstone both map to the mutateCandidate kind.
        let mutate = report
            .proposals_emitted
            .iter()
            .filter(|f| f.kind == "mutateCandidate")
            .count();
        assert_eq!(mutate, 2);
        assert_eq!(sink.diaries.len(), 1);
        assert_eq!(sink.diaries[0].wing, "wing_maintenance-daemon");
        assert_eq!(
            sink.diaries[0].entry,
            "maintenance cycle 1: audit-checked true, forbidden 1, decay 1, \
tombstone 1, fingerprint-drift 1, byReference-drift 1, proposed 5, suppressed 0, \
qid-retried 0, qid-resolved 0, qid-proposed 0, qid-pending 0, \
node-invariant-violations 0"
        );
        // No pending drawers were seeded — QID telemetry all zero.
        assert_eq!(report.qid_retried, 0);
        assert_eq!(report.qid_resolved, 0);
        assert_eq!(report.qid_still_pending, 0);
        assert_eq!(report.node_invariant_violations, 0);
    }

    // MC-2: a tampered audit chain emits exactly the audit-integrity
    // proposal, target audit-break-<millis>. (Swift C4, broken at 2000.)
    //
    // This test injects a fake `AuditVerdict { valid: false, .. }` directly
    // — it exercises `decide`'s HLC-reversal branch but never the real
    // `UnifiedAuditLog` ingress / `AuditChainVerifier`. See
    // `mc2b_real_tampered_entry_rejected_at_ingress_emits_integrity_proposal`
    // below for the real-path coverage (AUDIT-ALERT-RESTORE, 2026-07-09).
    #[test]
    fn mc2_tampered_audit_emits_integrity() {
        let scan = MaintenanceScan {
            audit: Some(AuditVerdict {
                valid: false,
                first_broken_at_millis: Some(2000),
                rejected_entry_count: 0,
            }),
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);
        assert_eq!(report.proposals_emitted.len(), 1);
        assert_eq!(report.proposals_emitted[0].target, "audit-break-2000");
        assert_eq!(report.proposals_emitted[0].kind, "other:audit_integrity");
    }

    // MC-2b: AUDIT-ALERT-RESTORE (2026-07-09) — drives the REAL path. Unlike
    // MC-2 above (a fake verdict struct literal), this test builds a real
    // `genius_locus_kit::UnifiedAuditLog`, tampers an entry (mutates a
    // public field post-construction so its stored id no longer matches its
    // content hash — the same technique `audit/verifier.rs`'s
    // `av3_tampered_entry_rejected_at_add_boundary` test uses), feeds it
    // through the REAL `add()` ingress (the entry is rejected;
    // `rejected_count()` observes it), runs the REAL `AuditChainVerifier`
    // over what remains (vacuously valid — the tampered entry never
    // reached the walk), and derives a real `AuditVerdict` from both. Only
    // then does it hand that verdict to the daemon via the `FakeReader`
    // seam (the seam itself stays a fake — only the estate reads are
    // faked, per the established pattern; the audit primitives are real).
    #[test]
    fn mc2b_real_tampered_entry_rejected_at_ingress_emits_integrity_proposal() {
        use genius_locus_kit::audit::{
            AuditChainVerifier, AuditTier, EntryUUID, UnifiedAuditEntry, UnifiedAuditLog,
            UnifiedAuditValue, UnifiedAuditVerb,
        };
        use substrate_types::hlc::HLC;

        let honest = UnifiedAuditEntry::new(
            AuditTier::Locus,
            HLC::new(1_000, 0, 1),
            UnifiedAuditVerb::Capture,
            EntryUUID([7u8; 16]),
            "content".to_string(),
            UnifiedAuditValue::Null,
            UnifiedAuditValue::StringValue("x".to_string()),
            None,
        );
        let mut tampered = UnifiedAuditEntry::new(
            AuditTier::Locus,
            HLC::new(2_000, 0, 1),
            UnifiedAuditVerb::Mutate,
            EntryUUID([7u8; 16]),
            "content".to_string(),
            UnifiedAuditValue::StringValue("a".to_string()),
            UnifiedAuditValue::StringValue("b".to_string()),
            None,
        );
        // Alter a field WITHOUT recomputing the id — simulates the forgery
        // a hostile peer (or corrupted decode) might supply. The stored id
        // no longer matches the wire encoding of the mutated entry.
        tampered.field_path = "provenance".to_string();

        let mut log = UnifiedAuditLog::new();
        log.add(honest);
        log.add(tampered); // rejected at the real add() boundary

        assert_eq!(log.count(), 1, "only the honest entry was admitted");
        assert_eq!(log.rejected_count(), 1, "the real ingress path counted the rejection");

        let report = AuditChainVerifier::verify(&log);
        assert!(report.valid, "the walked chain is vacuously valid — the tampered entry never reached it");

        let audit_verdict = AuditVerdict {
            valid: report.valid,
            first_broken_at_millis: report.first_broken_at_millis,
            rejected_entry_count: log.rejected_count(),
        };

        let scan = MaintenanceScan {
            audit: Some(audit_verdict),
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);

        assert_eq!(report.proposals_emitted.len(), 1, "the ingress rejection is alerted via exactly one integrity proposal");
        assert_eq!(report.proposals_emitted[0].target, "audit-rejected-1");
        assert_eq!(report.proposals_emitted[0].kind, "other:audit_integrity");
    }

    // MC-3: a second cycle over unchanged state proposes nothing new — all
    // five suppressed by the B-4 idempotency memory; counts still report
    // the crossers; the diary's cycle index advances. (Swift B4.)
    #[test]
    fn mc3_second_cycle_suppresses_all() {
        let reader = FakeReader { scan: full_scan() };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());

        let first = d.run_cycle(1_000_000.0, &reader, &mut sink);
        assert_eq!(first.proposals_emitted.len(), 5);

        let second = d.run_cycle(1_300_000.0, &reader, &mut sink);
        assert_eq!(second.proposals_emitted.len(), 0);
        assert_eq!(second.suppressed_duplicates, 5);
        assert_eq!(second.decay_candidates, 1, "counts still report crossers");
        assert!(sink.diaries[1].entry.starts_with("maintenance cycle 2:"));
        assert!(sink.diaries[1].entry.contains("proposed 0, suppressed 5"));
        assert!(sink.diaries[1].entry.contains("qid-retried 0, qid-resolved 0, qid-proposed 0, qid-pending 0, node-invariant-violations 0"));
    }

    // MPS-1: InMemoryMaintenancePolicyStore starts empty; save then load
    // returns the saved policy (in-memory round-trip).
    #[test]
    fn mps1_in_memory_store_empty_then_round_trip() {
        let mut store = InMemoryMaintenancePolicyStore::new(None);
        assert!(store.load_policy().is_none(), "empty store returns None");
        let custom = MaintenancePolicy {
            tick_interval_ms: 60_000,
            audit_check_interval_ms: 120_000,
            decay_window_seconds: 1_296_000.0, // 15 days
            tombstone_grace_seconds: 302_400.0,  // 3.5 days
            fingerprint_drift_threshold: 0.15,
            by_reference_drift_threshold: 0.10,
        };
        store.save_policy(custom);
        let loaded = store.load_policy();
        assert_eq!(loaded, Some(custom), "load returns saved policy");
    }

    // MPS-2: seed the store with an initial policy; overwrite with a second;
    // the second is returned.
    #[test]
    fn mps2_save_overwrites_previous() {
        let initial = MaintenancePolicy::default();
        let mut store = InMemoryMaintenancePolicyStore::new(Some(initial));
        assert_eq!(store.load_policy(), Some(initial));

        let updated = MaintenancePolicy {
            tick_interval_ms: 10_000,
            ..initial
        };
        store.save_policy(updated);
        assert_eq!(store.load_policy(), Some(updated), "second save overwrites first");
    }

    // ─── Pump cadence tests (mirror Swift MaintenanceDaemonTests cadence suite) ───

    fn empty_reader() -> FakeReader {
        FakeReader { scan: MaintenanceScan::default() }
    }

    // PC-M1: first pump call always fires regardless of interval (no prior
    // fire timestamp). Mirrors Swift `testMaintenancePumpFirstCallAlwaysFires`.
    #[test]
    fn pc_m1_pump_first_call_always_fires() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        // tick_interval_ms = 300_000 (5 min). At t=0 there is no prior fire.
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let result = d.pump(0.0, &reader, &mut sink);
        assert!(result.is_some(), "first pump call must always fire");
    }

    // PC-M2: a call before the interval has elapsed returns None.
    // Mirrors Swift `testMaintenancePumpSkipsBeforeInterval`.
    #[test]
    fn pc_m2_pump_skips_before_interval() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy { tick_interval_ms: 300_000, ..MaintenancePolicy::default() });
        // First call fires (t=0).
        let first = d.pump(0.0, &reader, &mut sink);
        assert!(first.is_some(), "first call must fire");
        // Second call at t=299 s — interval (300 s) has not elapsed.
        let before = d.pump(299.0, &reader, &mut sink);
        assert!(before.is_none(), "call before interval must return None");
    }

    // PC-M3: a call at exactly the interval boundary fires.
    // Mirrors Swift `testMaintenancePumpFiresAtInterval`.
    #[test]
    fn pc_m3_pump_fires_at_interval() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy { tick_interval_ms: 300_000, ..MaintenancePolicy::default() });
        // First call fires at t=0.
        let _ = d.pump(0.0, &reader, &mut sink);
        // Call at t=300 s — exactly at the interval boundary.
        let at_boundary = d.pump(300.0, &reader, &mut sink);
        assert!(at_boundary.is_some(), "call at interval boundary must fire");
    }

    // ─── Board item 14: QID-pending enrichment retry batch ───────────────

    fn pending_row(id: &str, content: &str, provenance: i64) -> QidPendingRow {
        QidPendingRow {
            id: id.to_string(),
            content: content.to_string(),
            provenance,
        }
    }

    // Board-14-R1: no pending drawers → all QID counters are zero.
    #[test]
    fn board14_r1_zero_pending_all_counters_zero() {
        let reader = FakeReader { scan: MaintenanceScan::default() };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);

        assert_eq!(report.qid_retried, 0);
        assert_eq!(report.qid_resolved, 0);
        assert_eq!(report.qid_still_pending, 0);
        assert!(sink.enrichment_updates.is_empty(), "no writes when no pending drawers");
    }

    // Board-14-R2 (completion): unresolved pending drawers do NOT stay pending —
    // empty content → infer_lattice_anchor returns wikidata_qid = None → the
    // daemon files an enrichment proposal and flips the status to qid_proposed
    // (4). No drawer ends at the durable-pending assertion the beta gate forbids.
    #[test]
    fn board14_r2_unresolved_reaches_qid_proposed_terminal() {
        let qid_pending_bit: i64 = 1 << 36; // enrichment-status qid_pending (1)
        let qid_proposed_bit: i64 = 4 << 36; // enrichment-status qid_proposed (4)
        let scan = MaintenanceScan {
            qid_pending_drawers: vec![
                pending_row("row-a", "", qid_pending_bit),
                pending_row("row-b", "", qid_pending_bit),
            ],
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);

        assert_eq!(report.qid_retried, 2);
        assert_eq!(report.qid_resolved, 0);
        // Terminal: both reached qid_proposed, none durable-pending.
        assert_eq!(report.qid_proposed, 2);
        assert_eq!(report.qid_still_pending, 0);
        // One enrichment proposal AND one status write per unresolved drawer.
        let enrichment_proposals = sink
            .proposals
            .iter()
            .filter(|f| f.kind == "enrichment")
            .count();
        assert_eq!(enrichment_proposals, 2);
        assert_eq!(sink.enrichment_updates.len(), 2);
        for (_, prov) in &sink.enrichment_updates {
            assert_eq!(prov & (0x3F << 36), qid_proposed_bit,
                "status must be flipped to qid_proposed (4)");
        }
        // Counter invariant: retried == resolved + proposed + still_pending.
        assert_eq!(
            report.qid_retried,
            report.qid_resolved + report.qid_proposed + report.qid_still_pending
        );
    }

    // Board-14-R3: counter integrity holds across outcomes — retried == resolved
    // + still-pending. Uses real infer_lattice_anchor; exact resolution depends
    // on FDC artifacts, so we only assert the structural invariant.
    #[test]
    fn board14_r3_counter_integrity_holds() {
        let qid_pending_bit: i64 = 1 << 36;
        let scan = MaintenanceScan {
            qid_pending_drawers: vec![
                pending_row("row-0", "content zero", qid_pending_bit),
                pending_row("row-1", "content one", qid_pending_bit),
                pending_row("row-2", "content two", qid_pending_bit),
            ],
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);

        assert_eq!(report.qid_retried, 3);
        assert_eq!(
            report.qid_retried,
            report.qid_resolved + report.qid_proposed + report.qid_still_pending,
            "retried == resolved + proposed + still_pending"
        );
        // No drawer ends durable-pending: every retried drawer reaches a
        // terminal (resolved or proposed).
        assert_eq!(report.qid_still_pending, 0);
        // One enrichment-status write per resolved drawer AND per proposed
        // drawer (both flip the status field).
        assert_eq!(
            sink.enrichment_updates.len(),
            report.qid_resolved + report.qid_proposed
        );
    }

    // Board-14-R4: resolved drawers get provenance bits flipped to
    // qid_completed. Conditional on at least one resolving — uses
    // the same content as the Swift success-path test ("mathematics").
    #[test]
    fn board14_r4_resolved_provenance_bits_flipped() {
        let qid_pending_bit: i64 = 1 << 36; // bits 36-41 == 1
        let qid_completed_bit: i64 = 2 << 36; // bits 36-41 == 2

        let scan = MaintenanceScan {
            qid_pending_drawers: vec![
                pending_row("row-math", "mathematics", qid_pending_bit),
            ],
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);

        assert_eq!(report.qid_retried, 1);
        assert_eq!(
            report.qid_retried,
            report.qid_resolved + report.qid_proposed + report.qid_still_pending
        );
        // Either way the row reaches a terminal — never durable-pending.
        assert_eq!(report.qid_still_pending, 0);

        let qid_proposed_bit: i64 = 4 << 36; // bits 36-41 == 4
        if report.qid_resolved == 1 {
            // Resolved path: status flipped to qid_completed (2).
            assert_eq!(sink.enrichment_updates.len(), 1);
            let (written_id, written_prov) = &sink.enrichment_updates[0];
            assert_eq!(written_id, "row-math");
            let written_bits = written_prov & (0x3F << 36);
            assert_eq!(written_bits, qid_completed_bit,
                "bits 36-41 must be flipped to qid_completed (2)");
        } else {
            // Unresolved path: an enrichment proposal was filed and the status
            // flipped to qid_proposed (4) — the terminal in-workflow state.
            assert_eq!(report.qid_proposed, 1);
            assert_eq!(sink.enrichment_updates.len(), 1);
            let (_, written_prov) = &sink.enrichment_updates[0];
            assert_eq!(written_prov & (0x3F << 36), qid_proposed_bit,
                "bits 36-41 must be flipped to qid_proposed (4)");
            let enrichment_proposals = sink
                .proposals
                .iter()
                .filter(|f| f.kind == "enrichment")
                .count();
            assert_eq!(enrichment_proposals, 1);
        }
    }

    // Board-14-R5: bounded scan cap is honoured — more than QID_RETRY_SCAN_CAP
    // rows in the scan input → daemon processes at most QID_RETRY_SCAN_CAP.
    #[test]
    fn board14_r5_bounded_scan_cap_honoured() {
        let qid_pending_bit: i64 = 1 << 36;
        // Supply 100 pending drawers — more than the 64-row cap.
        let rows: Vec<QidPendingRow> = (0..100)
            .map(|i| pending_row(&format!("row-cap-{i}"), "", qid_pending_bit))
            .collect();
        let scan = MaintenanceScan {
            qid_pending_drawers: rows,
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);

        assert_eq!(
            report.qid_retried, QID_RETRY_SCAN_CAP,
            "daemon must not process more than QID_RETRY_SCAN_CAP rows; got {}",
            report.qid_retried
        );
        assert_eq!(
            report.qid_retried,
            report.qid_resolved + report.qid_proposed + report.qid_still_pending
        );
        // Bounded cap honoured AND every processed row reached a terminal —
        // none durable-pending.
        assert_eq!(report.qid_still_pending, 0);
        assert_eq!(report.qid_proposed, QID_RETRY_SCAN_CAP);
    }

    // Board-14-R6: diary entry includes QID telemetry fields.
    #[test]
    fn board14_r6_diary_entry_includes_qid_telemetry() {
        let qid_pending_bit: i64 = 1 << 36;
        let scan = MaintenanceScan {
            qid_pending_drawers: vec![
                pending_row("row-diary", "", qid_pending_bit),
            ],
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);

        let text = &report.diary_entry.entry;
        assert!(text.contains("qid-retried"), "diary must include qid-retried count");
        assert!(text.contains("qid-resolved"), "diary must include qid-resolved count");
        assert!(text.contains("qid-proposed"), "diary must include qid-proposed count");
        assert!(text.contains("qid-pending"), "diary must include qid-pending count");
    }

    // Board-14-R7 (completion gate): no censused inference outcome ends at a
    // durable-pending assertion. A mixed batch (one resolvable + several
    // unresolvable) drains entirely to terminals: resolved → qid_completed,
    // unresolved → qid_proposed (proposal filed). qid_still_pending stays 0.
    #[test]
    fn board14_r7_no_durable_pending_after_cycle() {
        let qid_pending_bit: i64 = 1 << 36;
        let scan = MaintenanceScan {
            qid_pending_drawers: vec![
                pending_row("row-resolvable", "mathematics", qid_pending_bit),
                pending_row("row-unknown-1", "", qid_pending_bit),
                pending_row("row-unknown-2", "zzzqxx novel token", qid_pending_bit),
            ],
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);

        assert_eq!(report.qid_retried, 3);
        // THE GATE: nothing left durable-pending.
        assert_eq!(report.qid_still_pending, 0, "no durable pending state allowed");
        // Every retried drawer reached a terminal.
        assert_eq!(report.qid_resolved + report.qid_proposed, 3);
        // Every drawer got exactly one enrichment-status write (to completed or
        // proposed); unresolved ones additionally got an enrichment proposal.
        assert_eq!(sink.enrichment_updates.len(), 3);
        let enrichment_proposals = sink
            .proposals
            .iter()
            .filter(|f| f.kind == "enrichment")
            .count();
        assert_eq!(enrichment_proposals, report.qid_proposed);
    }

    // ─── node-tree invariant verification ────────────────────────────

    // NI-1: no invariant rows → zero violations.
    #[test]
    fn ni1_empty_invariant_rows_zero_violations() {
        let reader = empty_reader();
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);
        assert_eq!(report.node_invariant_violations, 0);
        assert!(report.diary_entry.entry.contains("node-invariant-violations 0"));
    }

    // NI-2: empty parent_node_id triggers I-NT-3 violation.
    #[test]
    fn ni2_empty_parent_node_id_violation() {
        let scan = MaintenanceScan {
            node_invariant_rows: vec![
                NodeInvariantRow {
                    drawer_id: "d-ok".into(),
                    parent_node_id: "node-1".into(),
                    wing: "study".into(),
                    room: "desk".into(),
                },
                NodeInvariantRow {
                    drawer_id: "d-orphan".into(),
                    parent_node_id: "".into(),
                    wing: "study".into(),
                    room: "desk".into(),
                },
            ],
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);
        assert_eq!(report.node_invariant_violations, 1);
        assert!(report.diary_entry.entry.contains("node-invariant-violations 1"));
    }

    // NI-3: sibling display-name inconsistency triggers a violation.
    #[test]
    fn ni3_inconsistent_display_names_violation() {
        let scan = MaintenanceScan {
            node_invariant_rows: vec![
                NodeInvariantRow {
                    drawer_id: "d-a".into(),
                    parent_node_id: "node-1".into(),
                    wing: "study".into(),
                    room: "desk".into(),
                },
                NodeInvariantRow {
                    drawer_id: "d-b".into(),
                    parent_node_id: "node-1".into(),
                    wing: "study".into(),
                    room: "shelf".into(), // different room name for same node
                },
            ],
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);
        assert_eq!(report.node_invariant_violations, 1);
    }

    // NI-4: both violations co-occur (empty parent + inconsistent display).
    #[test]
    fn ni4_multiple_violation_types() {
        let scan = MaintenanceScan {
            node_invariant_rows: vec![
                NodeInvariantRow {
                    drawer_id: "d-orphan".into(),
                    parent_node_id: "".into(),
                    wing: "x".into(),
                    room: "y".into(),
                },
                NodeInvariantRow {
                    drawer_id: "d-a".into(),
                    parent_node_id: "node-2".into(),
                    wing: "wing-a".into(),
                    room: "room-a".into(),
                },
                NodeInvariantRow {
                    drawer_id: "d-b".into(),
                    parent_node_id: "node-2".into(),
                    wing: "wing-b".into(), // different wing for same node
                    room: "room-a".into(),
                },
            ],
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(1_000_000.0, &reader, &mut sink);
        // 1 empty parent + 1 inconsistent display = 2 violations.
        assert_eq!(report.node_invariant_violations, 2);
    }
}
