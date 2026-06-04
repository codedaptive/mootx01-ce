// estate_dreaming_reader.rs — Rust parity of
// `NeuronKit/Sources/NeuronKit/Dreaming/EstateDreamingReader.swift`.
//
// Production adapter that implements `DreamingSubstrateReader` over a
// synchronous `DrawerStore` reference. Unlike the Swift actor that
// calls async GLK surface methods, the Rust version snapshots the three
// reads at construction time — the trait's methods are sync (no time args)
// and the store is sync, so pre-fetching is the natural fit.
//
// Architecture note: same layering rationale as Swift. `EstateDreamingReader`
// lives in NeuronKit because it needs to implement `DreamingSubstrateReader`
// (declared in `dreaming_cycle.rs`) AND call locus-kit DrawerStore methods.
// NeuronKit already depends on both; locus-kit does not depend on
// neuron-kit, so there is no circular dependency.

use std::collections::BTreeMap;

use locus_kit::drawer_store::DrawerStore;
use locus_kit::error::LocusKitError;

use crate::dreaming_cycle::{
    CoOccurrenceObservation, DreamingSubstrateReader, RecallTraceItem as CycleRecallTraceItem,
    TunnelLink,
};

/// Snapshot-based production adapter for `DreamingSubstrateReader`.
///
/// Reads are snapshotted from the store at construction via
/// `EstateDreamingReader::new`. The three trait methods return
/// references into those snapshots so no store call is needed after
/// construction. This matches the Rust `DreamingSubstrateReader` trait
/// contract (sync, no time parameters).
pub struct EstateDreamingReader {
    traces: Vec<CycleRecallTraceItem>,
    observations: Vec<CoOccurrenceObservation>,
    tunnels: Vec<TunnelLink>,
}

impl EstateDreamingReader {
    /// Construct the adapter by snapshotting all three reads from `store`.
    ///
    /// `since` and `now` are ISO8601 strings bounding the recall-trace
    /// reward window (both inclusive). The co-occurrence observations are
    /// derived from the drawer snapshot using the v1 room-grouping algorithm.
    pub fn new<S: DrawerStore>(
        store: &S,
        since: &str,
        now: &str,
    ) -> Result<Self, LocusKitError> {
        let raw_traces = store.recent_recall_traces(since, now)?;
        let traces = raw_traces
            .into_iter()
            .map(|t| CycleRecallTraceItem {
                target: t.target.clone(),
                used: t.used(),
            })
            .collect();

        let drawers = store.all_drawers()?;
        let observations = build_co_occurrence_observations(&drawers);

        let raw_tunnels = store.all_tunnels()?;
        let tunnels = raw_tunnels
            .into_iter()
            .map(|t| TunnelLink {
                source_drawer_id: t.source_drawer_id.clone(),
                target_drawer_id: t.target_drawer_id.clone(),
            })
            .collect();

        Ok(EstateDreamingReader {
            traces,
            observations,
            tunnels,
        })
    }
}

impl DreamingSubstrateReader for EstateDreamingReader {
    fn recent_recall_traces(&self) -> Vec<CycleRecallTraceItem> {
        self.traces.clone()
    }

    fn co_occurrence_observations(&self) -> Vec<CoOccurrenceObservation> {
        self.observations.clone()
    }

    fn existing_tunnels(&self) -> Vec<TunnelLink> {
        self.tunnels.clone()
    }
}

// MARK: - Co-occurrence builder (v1 room-grouping algorithm)
//
// Mirrors `EstateDreamingReader.buildObservations(from:)` in Swift.
// Groups non-tombstoned drawers by (wing, room) and emits one
// CoOccurrenceObservation per pair of drawers that share a room.
// `attempts` = total drawers in that room (proxy for evidence density).

fn build_co_occurrence_observations(
    drawers: &[locus_kit::drawer::Drawer],
) -> Vec<CoOccurrenceObservation> {
    let mut by_room: BTreeMap<(String, String), Vec<String>> = BTreeMap::new();

    for drawer in drawers {
        // Rust `tombstoned_at` is `Option<i64>` (epoch seconds); None means live.
        if drawer.tombstoned_at.is_some() {
            continue;
        }
        by_room
            .entry((drawer.wing.clone(), drawer.room.clone()))
            .or_default()
            .push(drawer.id.clone());
    }

    let mut observations: Vec<CoOccurrenceObservation> = Vec::new();
    for (_, ids) in &by_room {
        if ids.len() < 2 {
            continue;
        }
        // IDs are already in BTreeMap insertion order but we sort for
        // determinism (matching Swift's `.sorted()` before enumeration).
        let mut sorted = ids.clone();
        sorted.sort();
        let room_count = sorted.len() as i64;

        for i in 0..sorted.len() {
            for j in (i + 1)..sorted.len() {
                observations.push(CoOccurrenceObservation {
                    endpoint_a: sorted[i].clone(),
                    endpoint_b: sorted[j].clone(),
                    attempts: room_count,
                    evidence_targets: vec![sorted[i].clone(), sorted[j].clone()],
                });
            }
        }
    }

    // Sort by (endpoint_a, endpoint_b) for determinism.
    observations.sort_by(|a, b| {
        a.endpoint_a
            .cmp(&b.endpoint_a)
            .then(a.endpoint_b.cmp(&b.endpoint_b))
    });

    observations
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_observations_pairs_same_room_drawers() {
        let drawers = vec![
            make_drawer("a", "wing1", "room1"),
            make_drawer("b", "wing1", "room1"),
            make_drawer("c", "wing1", "room1"),
            make_drawer("x", "wing2", "room2"), // solo room
        ];
        let obs = build_co_occurrence_observations(&drawers);
        // C(3,2) = 3 pairs from room1; solo x emits none.
        assert_eq!(obs.len(), 3);
        let pairs: Vec<(&str, &str)> = obs.iter().map(|o| (o.endpoint_a.as_str(), o.endpoint_b.as_str())).collect();
        assert!(pairs.contains(&("a", "b")));
        assert!(pairs.contains(&("a", "c")));
        assert!(pairs.contains(&("b", "c")));
    }

    #[test]
    fn build_observations_attempts_equals_room_count() {
        let drawers = vec![
            make_drawer("a", "w", "r"),
            make_drawer("b", "w", "r"),
            make_drawer("c", "w", "r"),
        ];
        let obs = build_co_occurrence_observations(&drawers);
        assert!(obs.iter().all(|o| o.attempts == 3));
    }

    #[test]
    fn build_observations_empty_when_no_room_has_two_drawers() {
        let drawers = vec![
            make_drawer("a", "w1", "r1"),
            make_drawer("b", "w2", "r2"),
        ];
        let obs = build_co_occurrence_observations(&drawers);
        assert!(obs.is_empty());
    }

    #[test]
    fn build_observations_sorted_deterministically() {
        let drawers = vec![
            make_drawer("z", "w", "r"),
            make_drawer("a", "w", "r"),
            make_drawer("m", "w", "r"),
        ];
        let obs = build_co_occurrence_observations(&drawers);
        for i in 0..(obs.len().saturating_sub(1)) {
            if obs[i].endpoint_a == obs[i + 1].endpoint_a {
                assert!(obs[i].endpoint_b <= obs[i + 1].endpoint_b);
            } else {
                assert!(obs[i].endpoint_a <= obs[i + 1].endpoint_a);
            }
        }
    }

    fn make_drawer(id: &str, wing: &str, room: &str) -> locus_kit::drawer::Drawer {
        locus_kit::drawer::Drawer::new(
            id,
            format!("content-{id}"),
            wing,
            room,
            "test",
            0_i64,
            "model-v1",
        )
    }
}
