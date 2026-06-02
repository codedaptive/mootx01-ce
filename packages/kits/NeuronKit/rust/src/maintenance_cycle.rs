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
//! shapes + an `AuditVerdict`). The write seam's `propose` is the
//! Brain-layer verb, `NotSupportedByEstate` in both languages until the
//! Brain layer ships — so a live proposal adapter waits on the same
//! architectural boundary in both, not on this version. The orchestration is
//! gated with deterministic fakes mirroring the Swift MaintenanceDaemonTests.
//!
//! Determinism: no clock, no RNG. The daemon carries `cycle_count`; all
//! time-derived inputs (ages, the audit verdict) arrive through the seam.

use crate::maintenance_decision::{self, AgedRow, AuditVerdict, Category, DriftRow};

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
}

/// Maintenance health-scan parameters the cycle reads, mirroring the Swift
/// `MaintenancePolicy` fields the decision uses.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaintenancePolicy {
    pub decay_window_seconds: f64,
    pub tombstone_grace_seconds: f64,
    pub fingerprint_drift_threshold: f32,
    pub by_reference_drift_threshold: f32,
}

impl Default for MaintenancePolicy {
    /// Spec defaults (NEURONKIT_SPEC § 3.2).
    fn default() -> Self {
        Self {
            decay_window_seconds: 2_592_000.0,
            tombstone_grace_seconds: 604_800.0,
            fingerprint_drift_threshold: 0.25,
            by_reference_drift_threshold: 0.25,
        }
    }
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
}

/// Read seam: yields the gathered scan inputs for one cycle.
pub trait MaintenanceSubstrateReader {
    fn scan(&self) -> MaintenanceScan;
}

/// Write seam: emit a proposal and record the cycle diary. No remediation
/// method — the daemon can only propose (structural never-remediate).
pub trait MaintenanceProposalSink {
    fn propose(&mut self, frame: ProposeFrameOut);
    fn record_cycle_diary(&mut self, entry: MaintenanceDiaryEntry);
}

const AGENT_NAME: &str = "maintenance-daemon";
const DIARY_WING: &str = "wing_maintenance-daemon";

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
}

impl MaintenanceDaemon {
    pub fn new(policy: MaintenancePolicy) -> Self {
        Self {
            policy,
            proposed_keys: std::collections::BTreeSet::new(),
            cycle_count: 0,
        }
    }

    /// Run one maintenance cycle (steps 0-6) against the seams. Mirrors
    /// `MaintenanceDaemon.runCycle`.
    pub fn run_cycle<R, S>(&mut self, reader: &R, sink: &mut S) -> MaintenanceCycleReport
    where
        R: MaintenanceSubstrateReader,
        S: MaintenanceProposalSink,
    {
        let scan = reader.scan();
        let audit_checked = scan.audit.is_some();

        // Delegate every decision to the pure core (steps 0-5).
        let outcome = maintenance_decision::decide(&maintenance_decision::Inputs {
            audit: scan.audit,
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
        self.proposed_keys = outcome.updated_proposed_keys.clone();

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
            proposals_emitted.push(frame);
        }

        // Step 6: exactly one diary entry; the summary is byte-identical to
        // the Swift actor's.
        self.cycle_count += 1;
        let entry = MaintenanceDiaryEntry {
            agent_name: AGENT_NAME.to_string(),
            entry: format!(
                "maintenance cycle {}: audit-checked {}, forbidden {}, decay {}, \
tombstone {}, fingerprint-drift {}, byReference-drift {}, proposed {}, suppressed {}",
                self.cycle_count,
                audit_checked,
                outcome.forbidden_combinations,
                outcome.decay_candidates,
                outcome.tombstone_candidates,
                outcome.fingerprint_drifts,
                outcome.by_reference_drifts,
                proposals_emitted.len(),
                outcome.suppressed_duplicates
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
    }
    impl MaintenanceProposalSink for RecordingSink {
        fn propose(&mut self, frame: ProposeFrameOut) {
            self.proposals.push(frame);
        }
        fn record_cycle_diary(&mut self, entry: MaintenanceDiaryEntry) {
            self.diaries.push(entry);
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
            }),
            forbidden_drawer_ids: vec!["d-forbidden".to_string()],
            aged_active: vec![aged("d-old", 3_000_000.0), aged("d-forbidden", 1.0)],
            aged_tombstoned: vec![aged("d-tomb", 700_000.0)],
            fingerprint_drift: vec![drift("wing_a/room_b", 0.5)],
            reference_drift: vec![drift("ref-1", 0.5)],
        }
    }

    // MC-1: all five scan categories emit (valid chain adds no audit
    // proposal); the report counts and the single diary entry are assembled.
    #[test]
    fn mc1_all_five_categories_emit_and_report() {
        let reader = FakeReader { scan: full_scan() };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(&reader, &mut sink);

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
tombstone 1, fingerprint-drift 1, byReference-drift 1, proposed 5, suppressed 0"
        );
    }

    // MC-2: a tampered audit chain emits exactly the audit-integrity
    // proposal, target audit-break-<millis>. (Swift C4, broken at 2000.)
    #[test]
    fn mc2_tampered_audit_emits_integrity() {
        let scan = MaintenanceScan {
            audit: Some(AuditVerdict {
                valid: false,
                first_broken_at_millis: Some(2000),
            }),
            ..MaintenanceScan::default()
        };
        let reader = FakeReader { scan };
        let mut sink = RecordingSink::default();
        let mut d = MaintenanceDaemon::new(MaintenancePolicy::default());
        let report = d.run_cycle(&reader, &mut sink);
        assert_eq!(report.proposals_emitted.len(), 1);
        assert_eq!(report.proposals_emitted[0].target, "audit-break-2000");
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

        let first = d.run_cycle(&reader, &mut sink);
        assert_eq!(first.proposals_emitted.len(), 5);

        let second = d.run_cycle(&reader, &mut sink);
        assert_eq!(second.proposals_emitted.len(), 0);
        assert_eq!(second.suppressed_duplicates, 5);
        assert_eq!(second.decay_candidates, 1, "counts still report crossers");
        assert!(sink.diaries[1].entry.starts_with("maintenance cycle 2:"));
        assert!(sink.diaries[1].entry.contains("proposed 0, suppressed 5"));
    }
}
