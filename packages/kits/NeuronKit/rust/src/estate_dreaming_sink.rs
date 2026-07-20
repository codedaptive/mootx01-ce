// estate_dreaming_sink.rs — Rust parity of
// `NeuronKit/Sources/NeuronKit/Dreaming/EstateDreamingSink.swift`.
//
// Production adapter that implements `DreamingProposalSink` by routing all
// writes through the GLK `EstateCoordinator` verb surface (B-1 compliant).
// The three write methods correspond to NEURONKIT_SPEC § 3.1 steps 6 and 7:
//
//   6. `propose` — delegates to `EstateCoordinator::propose`, which maps
//      the Brain-layer `ProposalKind` to the substrate's LocusKit kind and
//      dispatches to `Estate::propose`. The coordinator stamps the canonical
//      dreaming-daemon provenance (DreamingDaemon / Null confidence).
//
//   7. `record_cycle_diary` — delegates to `EstateCoordinator::add_diary_entry`,
//      which resolves the handle and writes to the estate's DrawerStore.
//
//   post-7. `prune_recall_traces` — delegates to
//      `EstateCoordinator::prune_recall_traces` (reward-sweep cleanup).
//
// ── Write error handling ─────────────────────────────────────────────
// The `DreamingProposalSink` trait methods are infallible (no `Result`
// return), matching the sync Rust port's convention. Write failures are
// captured in the `write_errors` field so callers can inspect them after
// a cycle — consistent with the daemon's autonomic contract (a cycle's
// write failure does not abort the cycle, it is logged and the daemon
// continues). Tests assert `write_errors.is_empty()`.
//
// ── Architecture note ────────────────────────────────────────────────
// Same layering rationale as `EstateDreamingReader`: lives in NeuronKit
// because it implements a NeuronKit trait. All writes route through the
// GLK coordinator, matching the Swift `EstateDreamingSink` which delegates
// to `GeniusLocusKit.propose(_:_:)`, `GeniusLocusKit.addDiaryEntry(in:_:)`,
// and `GeniusLocusKit.pruneRecallTraces(in:olderThan:)`.

use genius_locus_kit::coordinator::EstateCoordinator;
use genius_locus_kit::handle::EstateHandle;
use genius_locus_kit::verbs::frames::ProposeFrame as GlkProposeFrame;

use crate::dreaming_cycle::{DreamingDiaryEntry, DreamingProposalSink, ProposeFrameOut};

/// Map a dreaming-cycle proposal `kind` label to the GLK Brain-layer
/// `ProposalKind`. The dreaming decision emits camelCase labels; the GLK
/// enum uses snake_case wire values. This mapping bridges the two.
fn dreaming_kind_to_glk(kind: &str) -> genius_locus_kit::brain::scheduler::api::ProposalKind {
    use genius_locus_kit::brain::scheduler::api::ProposalKind;
    match kind {
        "miningPattern" | "miningPatternAdjustment" => ProposalKind::MiningPattern,
        "mutateCandidate" | "mutateDrawer" => ProposalKind::MutateCandidate,
        "enrichment" => ProposalKind::Enrichment,
        "newTunnel" => ProposalKind::Other("newTunnel".to_string()),
        "associationPromotion" => ProposalKind::Other("associationPromotion".to_string()),
        "recordObservation" => ProposalKind::DisciplineViolation,
        other => ProposalKind::Other(other.to_string()),
    }
}

/// Production adapter that binds `DreamingProposalSink` to a live estate
/// through the GLK `EstateCoordinator` verb surface.
///
/// Mirrors `EstateDreamingSink.swift`. Holds a coordinator reference and
/// estate handle, routing all writes through GLK (B-1 compliance).
/// Accumulates any write errors in `write_errors` — the trait methods are
/// infallible, but callers should inspect this field after a cycle to detect
/// failures.
pub struct EstateDreamingSink<'a> {
    coordinator: &'a EstateCoordinator,
    handle: EstateHandle,
    /// Deterministic timestamp for all rows written this cycle (epoch
    /// seconds). Passed at construction; not derived from the system clock.
    now: i64,
    /// Accumulated write errors from GLK coordinator calls. Empty on success.
    pub write_errors: Vec<String>,
}

impl<'a> EstateDreamingSink<'a> {
    /// Construct a sink over `coordinator` and `handle` with timestamps at `now`.
    ///
    /// `now` is explicit for determinism per the fleet rule; callers supply
    /// the epoch-seconds timestamp that the cycle should use for all rows.
    pub fn new(coordinator: &'a EstateCoordinator, handle: EstateHandle, now: i64) -> Self {
        Self {
            coordinator,
            handle,
            now,
            write_errors: Vec::new(),
        }
    }
}

impl<'a> DreamingProposalSink for EstateDreamingSink<'a> {
    /// Emit a proposal row (step 6). Constructs a GLK `ProposeFrame` and
    /// delegates to `EstateCoordinator::propose`, which maps the Brain-layer
    /// kind to the substrate kind and stamps the canonical dreaming-daemon
    /// provenance. Write failures are appended to `self.write_errors`.
    fn propose(&mut self, frame: ProposeFrameOut) {
        let glk_frame = GlkProposeFrame {
            target: frame.target,
            kind: dreaming_kind_to_glk(&frame.kind),
            justification: Some(frame.justification),
        };
        if let Err(e) = self.coordinator.propose(&self.handle, glk_frame, self.now) {
            self.write_errors.push(format!("propose: {e:?}"));
        }
    }

    /// Record exactly one diary entry per cycle (step 7). Delegates to
    /// `EstateCoordinator::add_diary_entry`. Write failures are appended
    /// to `self.write_errors`.
    fn record_cycle_diary(&mut self, entry: DreamingDiaryEntry) {
        if let Err(e) = self.coordinator.add_diary_entry(
            &self.handle,
            &entry.agent_name,
            &entry.entry,
            &entry.topic,
            "no-embedding",
            self.now,
        ) {
            self.write_errors.push(format!("record_cycle_diary: {e:?}"));
        }
    }

    /// Delete recall-trace rows older than `cutoff_iso` (the post-reward-sweep
    /// prune). Delegates to `EstateCoordinator::prune_recall_traces`. Write
    /// failures are appended to `self.write_errors` — the trait method is
    /// infallible, so a storage fault must not abort the cycle. Mirrors the
    /// Swift `EstateDreamingSink.pruneRecallTraces(olderThan:)`.
    fn prune_recall_traces(&mut self, cutoff_iso: &str) {
        if let Err(e) = self.coordinator.prune_recall_traces(&self.handle, cutoff_iso) {
            self.write_errors.push(format!("prune_recall_traces: {e:?}"));
        }
    }

    /// Retire a tunnel by flipping bit 13 of its `operational_bitmap`.
    ///
    /// Called by `run_omega_cycle` for each unreinforced dreamed tunnel. Delegates to
    /// `EstateCoordinator::retire_tunnel`, which delegates to `Estate::retire_tunnel`
    /// (B-1: NeuronKit never touches the substrate directly). Infallible — write
    /// failures are appended to `self.write_errors` so a single retire failure does
    /// not abort the OMEGA sweep.
    ///
    /// `changed_by` is the agent tag ("dreaming-daemon") for audit logs.
    /// `now_epoch_secs` is the deterministic cycle timestamp (i64 for SQLite TEXT rows).
    ///
    /// Mirrors Swift `EstateDreamingSink.retireTunnel(id:changedBy:now:)`.
    fn retire_tunnel(&mut self, tunnel_id: &str, changed_by: &str, now_epoch_secs: i64) {
        if let Err(e) = self.coordinator.retire_tunnel(
            &self.handle,
            tunnel_id,
            changed_by,
            now_epoch_secs,
        ) {
            self.write_errors.push(format!("retire_tunnel({tunnel_id}): {e:?}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::Arc;

    use genius_locus_kit::coordinator::EstateCoordinator;
    use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::OwnerCredentials;

    fn make_coordinator_and_handle() -> (EstateCoordinator, EstateHandle) {
        let store: Arc<dyn LocusDrawerStore> =
            Arc::new(InMemoryDrawerStore::new(0, None).expect("store"));
        let mut coord = EstateCoordinator::new();
        let handle = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .expect("open");
        (coord, handle)
    }

    /// Capture a drawer with the given content and return its assigned row ID.
    fn capture_drawer(coord: &EstateCoordinator, handle: &EstateHandle, content: &str, now: i64) -> String {
        use locus_kit::estate_types::LatticeAnchor;
        use locus_kit::drawer_operational::CaptureChannel;
        use locus_kit::frames::CaptureFrame;
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "test-room",
            LatticeAnchor::udc("000"),
            "test",
            "no-embedding",
        );
        coord.capture(handle, frame, now).expect("capture").id
    }

    #[test]
    fn propose_writes_proposal_through_glk() {
        let (coord, handle) = make_coordinator_and_handle();
        // GLK propose requires the target drawer to exist.
        let row_id = capture_drawer(&coord, &handle, "test content abc", 999_999);
        let mut sink = EstateDreamingSink::new(&coord, handle.clone(), 1_000_000);
        let frame = ProposeFrameOut {
            target: row_id.clone(),
            kind: "miningPattern".into(),
            justification: "dreaming: latent alignment".into(),
        };
        sink.propose(frame);
        assert!(sink.write_errors.is_empty(), "write errors: {:?}", sink.write_errors);
        // Verify the proposal landed via the coordinator's read surface.
        let proposals = coord.recall_proposals(&handle).expect("proposals");
        assert_eq!(proposals.len(), 1, "expected one proposal");
        assert_eq!(proposals[0].target_row_id, row_id);
        assert_eq!(
            proposals[0].justification.as_deref(),
            Some("dreaming: latent alignment")
        );
        assert_eq!(proposals[0].filed_at, 1_000_000);
    }

    #[test]
    fn record_cycle_diary_writes_entry_through_glk() {
        let (coord, handle) = make_coordinator_and_handle();
        let mut sink = EstateDreamingSink::new(&coord, handle.clone(), 2_000_000);
        let entry = DreamingDiaryEntry {
            agent_name: "dreaming-daemon".into(),
            entry: "dreaming cycle 1: considered 3, proposed 2, suppressed 0, below-threshold 1"
                .into(),
            topic: "dreaming-cycle".into(),
            wing: "wing_dreaming-daemon".into(),
            room: "diary".into(),
        };
        sink.record_cycle_diary(entry);
        assert!(sink.write_errors.is_empty(), "write errors: {:?}", sink.write_errors);
        // Verify the diary entry landed via the coordinator's read surface.
        let entries = coord
            .diary_entries(&handle, "dreaming-daemon", 10)
            .expect("diary_entries");
        assert_eq!(entries.len(), 1, "expected one diary entry");
        assert_eq!(entries[0].agent_name, "dreaming-daemon");
        assert_eq!(entries[0].topic, "dreaming-cycle");
        assert_eq!(entries[0].filed_at, 2_000_000);
    }

    #[test]
    fn round_trip_daemon_cycle_writes_proposal_and_diary() {
        use crate::dreaming_cycle::{
            DreamingDaemon, DreamingPolicy, DreamingSubstrateReader,
            RecallTraceItem, RecallTraceRewardSource, TunnelLink,
        };

        let (coord, handle) = make_coordinator_and_handle();
        // Capture drawers so the dreaming cycle's proposals can target
        // real estate rows. The stub reader returns these ids as recall
        // trace targets and co-occurrence endpoints.
        let id_a = capture_drawer(&coord, &handle, "content a", 2_999_000);
        let id_b = capture_drawer(&coord, &handle, "content b", 2_999_001);

        struct IdReader { a: String, b: String }
        impl DreamingSubstrateReader for IdReader {
            fn recent_recall_traces(&self) -> Vec<RecallTraceItem> {
                vec![
                    RecallTraceItem { target: self.a.clone(), used: true },
                    RecallTraceItem { target: self.b.clone(), used: true },
                ]
            }
            /// Returns 9 windows for pair (a, b) so coRecallCount(a,b)=9 after
            /// drain. This test calls run_cycle once, so this method is called once.
            /// min_attempts=1 gate clears easily; traces a+b used → proposal emits.
            fn drain_dreaming_window(&self) -> Vec<Vec<String>> {
                (0..9)
                    .map(|_| vec![self.a.clone(), self.b.clone()])
                    .collect()
            }
            fn existing_tunnels(&self) -> Vec<TunnelLink> {
                vec![]
            }
        }

        let mut sink = EstateDreamingSink::new(&coord, handle.clone(), 3_000_000);
        let reader = IdReader { a: id_a, b: id_b };
        let reward = RecallTraceRewardSource;
        let policy = DreamingPolicy {
            min_success_rate: 0.0,
            min_confidence: 0.7,
            min_attempts: 1,
            tick_interval_ms: 30_000,
            event_observation_threshold: 1,
        };
        let mut daemon = DreamingDaemon::new(policy);

        let report = daemon.run_cycle(3_000_000.0, &reader, &reward, &mut sink);

        assert!(sink.write_errors.is_empty(), "write errors: {:?}", sink.write_errors);
        assert!(!report.proposals_emitted.is_empty(), "daemon should emit proposals");
        // One diary entry per cycle, readable through GLK.
        let diary = coord.diary_entries(&handle, "dreaming-daemon", 10).expect("diary");
        assert_eq!(diary.len(), 1);
        // Proposals readable through GLK.
        let proposals = coord.recall_proposals(&handle).expect("proposals");
        assert!(!proposals.is_empty());
    }
}
