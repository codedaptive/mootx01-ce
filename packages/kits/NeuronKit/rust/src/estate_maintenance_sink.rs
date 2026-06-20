// estate_maintenance_sink.rs — Rust parity of
// `NeuronKit/Sources/NeuronKit/Maintenance/EstateMaintenanceSink.swift`.
//
// Production adapter that implements `MaintenanceProposalSink` over a
// synchronous `DrawerStore` reference. The two write methods correspond
// to NEURONKIT_SPEC § 3.2 steps 5 and 6:
//
//   5. `propose` — emits a Proposal row via `store.add_proposal`.
//      Constructs the full `locus_kit::Proposal` from `ProposeFrameOut`
//      with genuine provenance: a real UDC 005 system-state anchor and the
//      maintenance-daemon operational axes (kind, target object type
//      SystemState, generated-by DreamingDaemon, High confidence) per
//      cookbook §2.4. See `maintenance_proposal_operational`.
//
//   6. `record_cycle_diary` — writes a DiaryEntry row via
//      `store.add_diary_entry`, translating the cycle-local
//      `MaintenanceDiaryEntry` struct to the full `locus_kit::DiaryEntry`.
//
// ── Write error handling ─────────────────────────────────────────────
// The `MaintenanceProposalSink` trait methods are infallible (no `Result`
// return), matching the dreaming sink's convention. Write failures are
// captured in `write_errors` so callers can inspect them after a cycle.
// Tests assert `write_errors.is_empty()`.
//
// ── Architecture note ────────────────────────────────────────────────
// Same layering rationale as `EstateMaintenanceReader`: lives in NeuronKit
// because it implements a NeuronKit trait and calls locus-kit methods.
// The Rust DrawerStore trait exposes `add_proposal` and `add_diary_entry`
// as the direct write path (B-1-compliant; no GLK coordinator needed in
// the sync Rust port).

use std::sync::Arc;

use locus_kit::diary_entry::DiaryEntry as LkDiaryEntry;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::estate_types::LatticeAnchor;
use locus_kit::proposal::Proposal;
use locus_kit::proposal_operational::{
    compose_operational, ProposalConfidenceBucket, ProposalGeneratedByClass, ProposalKind,
    ProposalTargetObjectType,
};

use crate::maintenance_cycle::{MaintenanceDiaryEntry, MaintenanceProposalSink, ProposeFrameOut};

/// Map a maintenance-cycle proposal `kind` label to the substrate
/// `ProposalKind` axis (cookbook §2.4 bits 0–5), then compose the full
/// operational bitmap with the genuine maintenance-daemon provenance: the
/// generated-by class is `DreamingDaemon` (the autonomic governor is the
/// daemon producer class), the target object type is `SystemState` (a
/// maintenance proposal targets the estate's own state), and the confidence
/// bucket is `High` (maintenance remediations are rule-driven, not
/// hypotheses). Unrecognised labels map to `MutateDrawer`, the maintenance
/// cycle's dominant remediation shape.
fn maintenance_proposal_operational(kind: &str) -> i64 {
    let proposal_kind = match kind {
        "newTunnel" => ProposalKind::NewTunnel,
        "mutateCandidate" | "mutateDrawer" => ProposalKind::MutateDrawer,
        "withdrawDrawer" => ProposalKind::WithdrawDrawer,
        "recordObservation" => ProposalKind::RecordObservation,
        _ => ProposalKind::MutateDrawer,
    };
    compose_operational(
        proposal_kind,
        ProposalTargetObjectType::SystemState,
        ProposalGeneratedByClass::DreamingDaemon,
        ProposalConfidenceBucket::High,
    )
}

/// Production adapter that binds `MaintenanceProposalSink` to a live
/// `DrawerStore`.
///
/// Mirrors `EstateMaintenanceSink.swift`. Holds a `DrawerStore` reference and
/// a deterministic `now` (epoch seconds) for row timestamps. Accumulates
/// any write errors in `write_errors` — the trait methods are infallible,
/// but callers should inspect this field after a cycle to detect failures.
///
/// Row IDs are generated deterministically: `maintenance-<now>-<counter>`,
/// where `counter` increments per write. This satisfies the substrate's
/// non-empty ID requirement and the fleet determinism rule (no RNG inside
/// engines).
///
/// The `?Sized` bound on `S` allows `Arc<dyn DrawerStore>` to be used as the
/// store type — `Arc<dyn DrawerStore>` implements `DrawerStore` via the blanket
/// impl in `locus_kit::drawer_store`, so callers that hold a type-erased store
/// (e.g. the AutonomicGovernor) can pass it directly without a double-Arc wrapper.
pub struct EstateMaintenanceSink<S: DrawerStore + ?Sized> {
    store: Arc<S>,
    /// Deterministic timestamp for all rows written this cycle (epoch
    /// seconds). Passed at construction; not derived from the system clock.
    now: i64,
    /// Per-instance write counter, used to generate unique deterministic IDs.
    id_counter: u64,
    /// Accumulated write errors from `add_proposal` / `add_diary_entry`
    /// calls. Empty on success.
    pub write_errors: Vec<String>,
}

impl<S: DrawerStore + ?Sized> EstateMaintenanceSink<S> {
    /// Construct a sink over `store` with timestamps at `now`.
    ///
    /// `now` is explicit for determinism per the fleet rule; callers supply
    /// the epoch-seconds timestamp that the cycle should use for all rows.
    pub fn new(store: Arc<S>, now: i64) -> Self {
        Self {
            store,
            now,
            id_counter: 0,
            write_errors: Vec::new(),
        }
    }

    /// Generate a deterministic row ID of the form `maintenance-<now>-<counter>`.
    /// Increments the counter on each call so successive calls within a cycle
    /// produce distinct IDs.
    fn next_id(&mut self) -> String {
        let id = format!("maintenance-{}-{}", self.now, self.id_counter);
        self.id_counter += 1;
        id
    }
}

impl<S: DrawerStore + ?Sized> MaintenanceProposalSink for EstateMaintenanceSink<S> {
    /// Emit a remediation proposal (step 5). Translates `ProposeFrameOut` to
    /// a `locus_kit::Proposal` and calls `store.add_proposal`. Carries genuine
    /// provenance: a real UDC 005 system-state anchor and the maintenance-
    /// daemon operational axes (see `maintenance_proposal_operational`).
    /// Write failures are appended to `self.write_errors`.
    fn propose(&mut self, frame: ProposeFrameOut) {
        let mut proposal = Proposal::new(
            self.next_id(),
            frame.target,
            // UDC 005 ("computing, information") — the estate's own autonomic
            // machinery is the genuine subject of a system-state proposal.
            LatticeAnchor::udc("005"),
            self.now,
        );
        proposal.justification = Some(frame.justification);
        proposal.operational_bitmap = maintenance_proposal_operational(&frame.kind);
        if let Err(e) = self.store.add_proposal(&proposal) {
            self.write_errors.push(format!("propose: {e:?}"));
        }
    }

    /// Record exactly one diary entry per cycle (step 6). Translates
    /// `MaintenanceDiaryEntry` to a `locus_kit::DiaryEntry` and calls
    /// `store.add_diary_entry`. Write failures are appended to
    /// `self.write_errors`.
    fn record_cycle_diary(&mut self, entry: MaintenanceDiaryEntry) {
        let diary = LkDiaryEntry {
            id: self.next_id(),
            agent_name: entry.agent_name,
            entry: entry.entry,
            topic: entry.topic,
            wing: entry.wing,
            room: entry.room,
            filed_at: self.now,
            // Maintenance-cycle diary entries carry no embedding, so the model
            // ID is the genuine "no-embedding" marker — the same value the
            // Swift path substitutes for an empty embeddingModelID in
            // addDiaryEntry. Not a fabricated version string.
            embedding_model_id: "no-embedding".into(),
            tombstoned_at: None,
            removed_by_batch: None,
            operational_bitmap: 0,
            // Maintenance-cycle entries are system-generated; no explicit
            // quality signal is available at write time. Reward derives from
            // the recall trace during the next dreaming tick.
            reward: None,
            reward_provenance: None,
        };
        if let Err(e) = self.store.add_diary_entry(&diary) {
            self.write_errors.push(format!("record_cycle_diary: {e:?}"));
        }
    }

    /// Update a drawer's provenance bitmap after a QID-pending retry
    /// (Board item 14). Writes the new provenance value by calling
    /// `store.mutate_provenance(row_id, new_provenance)` — the production
    /// write path for provenance changes (B-1 compliant; routes through the
    /// DrawerStore trait, not raw SQL).
    ///
    /// Write failures are appended to `self.write_errors` and logged — the
    /// daemon never panics on a sink write failure; the pending row will be
    /// retried on the next maintenance cycle.
    fn update_enrichment_status(
        &mut self,
        row_id: &str,
        new_provenance: i64,
        _now_epoch_secs: f64,
    ) {
        if let Err(e) = self.store.mutate_provenance(
            row_id,
            new_provenance,
            // The maintenance daemon is the stable audit actor for QID retry
            // writes — the same name the cycle diary entries are filed under.
            "maintenance-daemon",
            Some("maintenance: enrichment-status retry"),
            self.now,
        ) {
            self.write_errors.push(format!("update_enrichment_status({row_id}): {e:?}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;

    fn make_store() -> Arc<InMemoryDrawerStore> {
        Arc::new(InMemoryDrawerStore::new(0, None).expect("store"))
    }

    #[test]
    fn propose_writes_proposal_to_store() {
        let store = make_store();
        let mut sink = EstateMaintenanceSink::new(Arc::clone(&store), 1_000_000);
        let frame = ProposeFrameOut {
            target: "row-abc".into(),
            kind: "mutateCandidate".into(),
            justification: "maintenance: decay candidate; drawer row-abc older than decay window"
                .into(),
        };
        sink.propose(frame);
        assert!(sink.write_errors.is_empty(), "write errors: {:?}", sink.write_errors);
        let proposals = store.proposals_for_target("row-abc").expect("proposals");
        assert_eq!(proposals.len(), 1, "expected one proposal");
        assert_eq!(proposals[0].target_row_id, "row-abc");
        assert_eq!(proposals[0].filed_at, 1_000_000);
        assert!(proposals[0]
            .justification
            .as_deref()
            .unwrap_or("")
            .contains("decay candidate"));
        // Genuine provenance, not placeholders: a real UDC anchor and the
        // maintenance-daemon operational axes (cookbook §2.4).
        use locus_kit::proposal_operational::{
            ProposalConfidenceBucket, ProposalGeneratedByClass, ProposalKind,
            ProposalTargetObjectType,
        };
        assert_eq!(proposals[0].lattice_anchor.udc_code, "005");
        assert_eq!(proposals[0].proposal_kind(), ProposalKind::MutateDrawer);
        assert_eq!(
            proposals[0].target_object_type(),
            ProposalTargetObjectType::SystemState
        );
        assert_eq!(
            proposals[0].generated_by_class(),
            ProposalGeneratedByClass::DreamingDaemon
        );
        assert_eq!(
            proposals[0].confidence_bucket(),
            ProposalConfidenceBucket::High
        );
    }

    #[test]
    fn record_cycle_diary_writes_entry_to_store() {
        let store = make_store();
        let mut sink = EstateMaintenanceSink::new(Arc::clone(&store), 2_000_000);
        let entry = MaintenanceDiaryEntry {
            agent_name: "maintenance-daemon".into(),
            entry: "maintenance cycle 1: audit-checked false, forbidden 0, decay 0, tombstone 0, \
                    fingerprint-drift 0, byReference-drift 0, proposed 0, suppressed 0"
                .into(),
            topic: "maintenance-cycle".into(),
            wing: "wing_maintenance-daemon".into(),
            room: "diary".into(),
        };
        sink.record_cycle_diary(entry);
        assert!(sink.write_errors.is_empty(), "write errors: {:?}", sink.write_errors);
        let entries = store.read_diary("maintenance-daemon", 10).expect("read_diary");
        assert_eq!(entries.len(), 1, "expected one diary entry");
        assert_eq!(entries[0].agent_name, "maintenance-daemon");
        assert_eq!(entries[0].topic, "maintenance-cycle");
        assert_eq!(entries[0].wing, "wing_maintenance-daemon");
        assert_eq!(entries[0].filed_at, 2_000_000);
    }

    #[test]
    fn round_trip_daemon_cycle_writes_proposal_and_diary() {
        use crate::maintenance_cycle::{
            MaintenanceDaemon, MaintenancePolicy, MaintenanceScan, MaintenanceSubstrateReader,
        };
        use crate::maintenance_decision::AgedRow;

        // Stub reader: one active drawer past the decay window.
        struct StubReader;
        impl MaintenanceSubstrateReader for StubReader {
            fn scan(&self) -> MaintenanceScan {
                MaintenanceScan {
                    aged_active: vec![AgedRow {
                        id: "row-a".into(),
                        age_seconds: 3_000_000.0, // well past 30-day decay window
                    }],
                    ..MaintenanceScan::default()
                }
            }
        }

        let store = make_store();
        let mut sink = EstateMaintenanceSink::new(Arc::clone(&store), 3_000_000);
        let reader = StubReader;
        let policy = MaintenancePolicy::default();
        let mut daemon = MaintenanceDaemon::new(policy);

        let report = daemon.run_cycle(3_000_000.0, &reader, &mut sink);

        assert!(sink.write_errors.is_empty(), "write errors: {:?}", sink.write_errors);
        // One decay proposal emitted.
        assert!(!report.proposals_emitted.is_empty(), "daemon should emit decay proposal");
        // One diary entry per cycle.
        let diary = store.read_diary("maintenance-daemon", 10).expect("read_diary");
        assert_eq!(diary.len(), 1);
        // Proposals written to store.
        let proposals =
            store.proposals_for_target(&report.proposals_emitted[0].target).expect("proposals");
        assert!(!proposals.is_empty());
    }
}
