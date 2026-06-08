// estate_dreaming_sink.rs — Rust parity of
// `NeuronKit/Sources/NeuronKit/Dreaming/EstateDreamingSink.swift`.
//
// Production adapter that implements `DreamingProposalSink` over a
// synchronous `DrawerStore` reference. The two write methods correspond
// to NEURONKIT_SPEC § 3.1 steps 6 and 7:
//
//   6. `propose` — emits a Proposal row via `store.add_proposal`.
//      Constructs the full `locus_kit::Proposal` from `ProposeFrameOut`
//      with a "dreaming" UDC lattice anchor (required non-empty by the
//      substrate; proposals carry the target's anchor in production; this
//      placeholder is the correct shape for automated dreaming proposals).
//
//   7. `record_cycle_diary` — writes a DiaryEntry row via
//      `store.add_diary_entry`, translating the cycle-local
//      `DreamingDiaryEntry` struct to the full `locus_kit::DiaryEntry`.
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
// because it implements a NeuronKit trait and calls locus-kit methods.
// The GLK coordinator is not needed here because the Rust DrawerStore
// trait already exposes `add_proposal` and `add_diary_entry` as the
// direct write path, bypassing the need for the GLK-level `propose` verb
// dispatch (which carries the `now` clock that is unavailable in the
// sync trait signatures anyway).

use std::sync::Arc;

use locus_kit::diary_entry::DiaryEntry as LkDiaryEntry;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::estate_types::LatticeAnchor;
use locus_kit::proposal::Proposal;

use crate::dreaming_cycle::{DreamingDiaryEntry, DreamingProposalSink, ProposeFrameOut};

/// Production adapter that binds `DreamingProposalSink` to a live
/// `DrawerStore`.
///
/// Mirrors `EstateDreamingSink.swift`. Holds a `DrawerStore` reference and
/// a deterministic `now` (epoch seconds) for row timestamps. Accumulates
/// any write errors in `write_errors` — the trait methods are infallible,
/// but callers should inspect this field after a cycle to detect failures.
///
/// Row IDs are generated deterministically: `dreaming-<now>-<counter>`, where
/// `counter` increments per write. This satisfies the substrate's non-empty ID
/// requirement and the fleet determinism rule (no RNG inside engines).
///
/// The `?Sized` bound on `S` allows `Arc<dyn DrawerStore>` to be used as the
/// store type — `Arc<dyn DrawerStore>` implements `DrawerStore` via the blanket
/// impl in `locus_kit::drawer_store`, so callers that hold a type-erased store
/// (e.g. the BrainPump, which receives the registry's `Arc<dyn DrawerStore>`)
/// can pass it directly without a double-Arc wrapper.
pub struct EstateDreamingSink<S: DrawerStore + ?Sized> {
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

impl<S: DrawerStore + ?Sized> EstateDreamingSink<S> {
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

    /// Generate a deterministic row ID of the form `dreaming-<now>-<counter>`.
    /// Increments the counter on each call so successive calls within a cycle
    /// produce distinct IDs.
    fn next_id(&mut self) -> String {
        let id = format!("dreaming-{}-{}", self.now, self.id_counter);
        self.id_counter += 1;
        id
    }
}

impl<S: DrawerStore + ?Sized> DreamingProposalSink for EstateDreamingSink<S> {
    /// Emit a proposal row (step 6). Translates `ProposeFrameOut` to a
    /// `locus_kit::Proposal` and calls `store.add_proposal`. A "dreaming"
    /// UDC lattice anchor satisfies the substrate's non-empty requirement.
    /// Write failures are appended to `self.write_errors`.
    fn propose(&mut self, frame: ProposeFrameOut) {
        let mut proposal = Proposal::new(
            self.next_id(),
            frame.target,
            // Dreaming proposals carry a placeholder "dreaming" UDC anchor.
            // In production, the target row's anchor is looked up; for
            // autonomous dreaming proposals there is no single target anchor,
            // so this placeholder satisfies the non-empty invariant.
            LatticeAnchor::udc("dreaming"),
            self.now,
        );
        proposal.justification = Some(frame.justification);
        if let Err(e) = self.store.add_proposal(&proposal) {
            self.write_errors.push(format!("propose: {e:?}"));
        }
    }

    /// Record exactly one diary entry per cycle (step 7). Translates
    /// `DreamingDiaryEntry` to a `locus_kit::DiaryEntry` and calls
    /// `store.add_diary_entry`. Write failures are appended to
    /// `self.write_errors`.
    fn record_cycle_diary(&mut self, entry: DreamingDiaryEntry) {
        let diary = LkDiaryEntry {
            id: self.next_id(),
            agent_name: entry.agent_name,
            entry: entry.entry,
            topic: entry.topic,
            wing: entry.wing,
            room: entry.room,
            filed_at: self.now,
            // "dreaming-v1" is the placeholder model ID for autonomic diary
            // entries (no embedding is generated; the field must be non-empty).
            embedding_model_id: "dreaming-v1".into(),
            tombstoned_at: None,
            removed_by_batch: None,
            operational_bitmap: 0,
        };
        if let Err(e) = self.store.add_diary_entry(&diary) {
            self.write_errors.push(format!("record_cycle_diary: {e:?}"));
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
        let mut sink = EstateDreamingSink::new(Arc::clone(&store), 1_000_000);
        let frame = ProposeFrameOut {
            target: "row-abc".into(),
            kind: "miningPattern".into(),
            justification: "dreaming: latent alignment row-abc<->row-xyz".into(),
        };
        sink.propose(frame);
        assert!(sink.write_errors.is_empty(), "write errors: {:?}", sink.write_errors);
        // Verify the proposal landed: look up by target row id.
        let proposals = store.proposals_for_target("row-abc").expect("proposals");
        assert_eq!(proposals.len(), 1, "expected one proposal");
        assert_eq!(proposals[0].target_row_id, "row-abc");
        assert_eq!(
            proposals[0].justification.as_deref(),
            Some("dreaming: latent alignment row-abc<->row-xyz")
        );
        assert_eq!(proposals[0].filed_at, 1_000_000);
    }

    #[test]
    fn record_cycle_diary_writes_entry_to_store() {
        let store = make_store();
        let mut sink = EstateDreamingSink::new(Arc::clone(&store), 2_000_000);
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
        // Verify the diary entry landed.
        let entries = store
            .read_diary("dreaming-daemon", 10)
            .expect("read_diary");
        assert_eq!(entries.len(), 1, "expected one diary entry");
        assert_eq!(entries[0].agent_name, "dreaming-daemon");
        assert_eq!(entries[0].topic, "dreaming-cycle");
        assert_eq!(entries[0].wing, "wing_dreaming-daemon");
        assert_eq!(entries[0].filed_at, 2_000_000);
    }

    #[test]
    fn round_trip_daemon_cycle_writes_proposal_and_diary() {
        use crate::dreaming_cycle::{
            CoOccurrenceObservation, DreamingDaemon, DreamingPolicy, DreamingSubstrateReader,
            RecallTraceItem, RecallTraceRewardSource, TunnelLink,
        };

        // Minimal stub reader: one co-occurrence pair with high reward.
        struct StubReader;
        impl DreamingSubstrateReader for StubReader {
            fn recent_recall_traces(&self) -> Vec<RecallTraceItem> {
                vec![
                    RecallTraceItem { target: "row-a".into(), used: true },
                    RecallTraceItem { target: "row-b".into(), used: true },
                ]
            }
            fn co_occurrence_observations(&self) -> Vec<CoOccurrenceObservation> {
                vec![CoOccurrenceObservation {
                    endpoint_a: "row-a".into(),
                    endpoint_b: "row-b".into(),
                    attempts: 5,
                    evidence_targets: vec!["row-a".into(), "row-b".into()],
                }]
            }
            fn existing_tunnels(&self) -> Vec<TunnelLink> {
                vec![]
            }
        }

        let store = make_store();
        let mut sink = EstateDreamingSink::new(Arc::clone(&store), 3_000_000);
        let reader = StubReader;
        let reward = RecallTraceRewardSource;
        let policy = DreamingPolicy { min_success_rate: 0.0, min_confidence: 0.7, min_attempts: 1, tick_interval_ms: 30_000 };
        let mut daemon = DreamingDaemon::new(policy);

        let report = daemon.run_cycle(3_000_000.0, &reader, &reward, &mut sink);

        assert!(sink.write_errors.is_empty(), "write errors: {:?}", sink.write_errors);
        // Cycle emitted at least one proposal (high-reward pair clears gate).
        assert!(!report.proposals_emitted.is_empty(), "daemon should emit proposals");
        // One diary entry per cycle.
        let diary = store.read_diary("dreaming-daemon", 10).expect("read_diary");
        assert_eq!(diary.len(), 1);
        // Proposals written to store equal emitted count.
        let proposals = store
            .proposals_for_target(&report.proposals_emitted[0].target)
            .expect("proposals");
        assert!(!proposals.is_empty());
    }
}
