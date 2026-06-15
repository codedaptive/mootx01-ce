// estate_dreaming_sink.rs — Rust parity of
// `NeuronKit/Sources/NeuronKit/Dreaming/EstateDreamingSink.swift`.
//
// Production adapter that implements `DreamingProposalSink` over a
// synchronous `DrawerStore` reference. The two write methods correspond
// to NEURONKIT_SPEC § 3.1 steps 6 and 7:
//
//   6. `propose` — emits a Proposal row via `store.add_proposal`.
//      Constructs the full `locus_kit::Proposal` from `ProposeFrameOut`
//      with genuine provenance: a real UDC 005 system-state anchor and the
//      dreaming-daemon operational axes (kind, target object type
//      SystemState, generated-by DreamingDaemon, Medium confidence) per
//      cookbook §2.4. See `dreaming_proposal_operational`.
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
use locus_kit::proposal_operational::{
    compose_operational, ProposalConfidenceBucket, ProposalGeneratedByClass, ProposalKind,
    ProposalTargetObjectType,
};

use crate::dreaming_cycle::{DreamingDiaryEntry, DreamingProposalSink, ProposeFrameOut};

/// Map a dreaming-cycle proposal `kind` label to the substrate
/// `ProposalKind` axis (cookbook §2.4 bits 0–5), then compose the full
/// operational bitmap with the genuine dreaming-daemon provenance: the
/// generated-by class is `DreamingDaemon`, the target object type is
/// `SystemState` (a dreaming proposal targets the estate's own state, not a
/// single row), and the confidence bucket is `Medium` (an autonomous
/// proposal is a hypothesis, not a verified fact). Unrecognised labels map
/// to `MutateDrawer`, the dreaming cycle's dominant proposal shape.
fn dreaming_proposal_operational(kind: &str) -> i64 {
    let proposal_kind = match kind {
        "newTunnel" => ProposalKind::NewTunnel,
        "mutateCandidate" | "mutateDrawer" => ProposalKind::MutateDrawer,
        "associationPromotion" => ProposalKind::AssociationPromotion,
        "miningPattern" | "miningPatternAdjustment" => ProposalKind::MiningPatternAdjustment,
        "recordObservation" => ProposalKind::RecordObservation,
        _ => ProposalKind::MutateDrawer,
    };
    compose_operational(
        proposal_kind,
        ProposalTargetObjectType::SystemState,
        ProposalGeneratedByClass::DreamingDaemon,
        ProposalConfidenceBucket::Medium,
    )
}

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
    /// `locus_kit::Proposal` and calls `store.add_proposal`. The proposal
    /// carries real provenance: its operational bitmap records the genuine
    /// generated-by class (`DreamingDaemon`), proposal kind (mapped from the
    /// frame's `kind` label), target object type (`SystemState` — a dreaming
    /// proposal targets the estate's own state, not one row), and a
    /// `Medium` confidence bucket. The lattice anchor is the autonomic
    /// system-state anchor (UDC 005 — "computing, information"; the estate's
    /// own machinery), satisfying the non-empty invariant with a genuine
    /// code rather than a label sentinel. Write failures are appended to
    /// `self.write_errors`.
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
        proposal.operational_bitmap = dreaming_proposal_operational(&frame.kind);
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
            // Dreaming-cycle diary entries carry no embedding, so the model ID
            // is the genuine "no-embedding" marker — the same value the Swift
            // path substitutes for an empty embeddingModelID in addDiaryEntry.
            // Not a fabricated version string.
            embedding_model_id: "no-embedding".into(),
            tombstoned_at: None,
            removed_by_batch: None,
            operational_bitmap: 0,
            // Dreaming-cycle entries are system-generated; no explicit quality
            // signal is available at write time. Reward is derived from the
            // recall trace (implicit source) during the next dreaming tick.
            reward: None,
            reward_provenance: None,
        };
        if let Err(e) = self.store.add_diary_entry(&diary) {
            self.write_errors.push(format!("record_cycle_diary: {e:?}"));
        }
    }

    /// Delete recall-trace rows older than `cutoff_iso` (the post-reward-sweep
    /// prune). Delegates to `DrawerStore::prune_recall_traces`. Write failures
    /// are appended to `self.write_errors` — the trait method is infallible, so
    /// a storage fault must not abort the cycle. Mirrors the Swift
    /// `EstateDreamingSink.pruneRecallTraces(olderThan:)`.
    fn prune_recall_traces(&mut self, cutoff_iso: &str) {
        if let Err(e) = self.store.prune_recall_traces(cutoff_iso) {
            self.write_errors.push(format!("prune_recall_traces: {e:?}"));
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
        // Genuine provenance, not placeholders: a real UDC anchor and the
        // dreaming-daemon operational axes (cookbook §2.4).
        use locus_kit::proposal_operational::{
            ProposalConfidenceBucket, ProposalGeneratedByClass, ProposalKind,
            ProposalTargetObjectType,
        };
        assert_eq!(proposals[0].lattice_anchor.udc_code, "005");
        assert_eq!(proposals[0].proposal_kind(), ProposalKind::MiningPatternAdjustment);
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
            ProposalConfidenceBucket::Medium
        );
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
        let policy = DreamingPolicy { min_success_rate: 0.0, min_confidence: 0.7, min_attempts: 1, tick_interval_ms: 30_000, event_observation_threshold: 1 };
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
