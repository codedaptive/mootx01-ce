// estate_dreaming_reader.rs — Rust parity of
// `NeuronKit/Sources/NeuronKit/Dreaming/EstateDreamingReader.swift`.
//
// Production adapter that implements `DreamingSubstrateReader` over a
// GeniusLocusKit estate handle. The adapter calls the GLK coordinator's
// `drain_dreaming_items` to drain pending dreaming-queue windows (T8 v2);
// the v1 snapshot-based approach (co-occurrence observations from drawer
// pairs) is deleted — `DrainDreamingWindow` is the only candidate source.
//
// Architecture note: same layering rationale as Swift. `EstateDreamingReader`
// lives in NeuronKit because it needs to implement `DreamingSubstrateReader`
// (declared in `dreaming_cycle.rs`) AND call genius_locus_kit coordinator
// methods. NeuronKit already depends on both; genius_locus_kit does not
// depend on neuron_kit, so there is no circular dependency.
//
// B-1 compliance: all estate reads route through genius_locus_kit's
// EstateCoordinator surface — no direct locus_kit storage calls.

use genius_locus_kit::{EstateCoordinator, EstateHandle, VerbDispatchError};

use crate::dreaming_cycle::{
    DreamingSubstrateReader, DreamingTunnelItem, RecallTraceItem as CycleRecallTraceItem,
    TunnelLink,
};

/// Snapshot-based production adapter for `DreamingSubstrateReader`.
///
/// `recent_recall_traces` and `existing_tunnels` are snapshotted from the
/// estate at construction via `EstateDreamingReader::new`. `drain_dreaming_window`
/// is NOT snapshotted — it calls the GLK coordinator's `drain_dreaming_items`
/// lazily when the dreaming cycle calls the trait method (T8 v2 drain-fed approach).
///
/// `recent_recall_traces` and `existing_tunnels` remain snapshot-based because
/// they are pure reads (no queue mutation); `drain_dreaming_window` is stateful
/// (it pops jobs from the queue) so it must be a live call, not a pre-fetch.
///
/// `now_epoch_secs` captures the construction instant (epoch-seconds). The
/// dreaming cycle injects the clock once at reader construction so the drain
/// telemetry is deterministic — no SystemTime reads inside the reader.
pub struct EstateDreamingReader<'a> {
    traces: Vec<CycleRecallTraceItem>,
    tunnels: Vec<TunnelLink>,
    /// Dreamed-active tunnels for OMEGA retire evaluation (T13 / ADR-021 Phase 7).
    /// Snapshotted at construction via `coordinator.all_active_tunnels`, then
    /// filtered to `is_dreamed() == true`. Pre-fetching keeps `dreamed_active_tunnels()`
    /// a cheap `Vec::clone()` inside the cycle — consistent with how `traces` and
    /// `tunnels` are handled.
    dreamed_active: Vec<DreamingTunnelItem>,
    /// Live coordinator reference for the drain call.
    coordinator: &'a EstateCoordinator,
    /// The estate whose dreaming queue this reader drains.
    handle: EstateHandle,
    /// Injected construction timestamp used for drain telemetry.
    now_epoch_secs: f64,
}

impl<'a> EstateDreamingReader<'a> {
    /// Construct the adapter by snapshotting recall traces and tunnels from
    /// the addressed estate through the GeniusLocusKit coordinator surface.
    ///
    /// `since` and `now` are ISO8601 strings bounding the recall-trace
    /// reward window (both inclusive). `now_epoch_secs` is the same instant
    /// in epoch-seconds — used for drain telemetry. Dreaming-queue windows are
    /// NOT snapshotted here — they are drained lazily via `drain_dreaming_window`.
    ///
    /// All reads go through `coordinator.recent_recall_traces` and
    /// `coordinator.all_tunnels` — B-1 compliant.
    pub fn new(
        coordinator: &'a EstateCoordinator,
        handle: &EstateHandle,
        since: &str,
        now: &str,
        now_epoch_secs: f64,
    ) -> Result<Self, VerbDispatchError> {
        let raw_traces = coordinator.recent_recall_traces(handle, since, now)?;
        let traces = raw_traces
            .into_iter()
            .map(|t| CycleRecallTraceItem {
                target: t.target.clone(),
                used: t.used(),
            })
            .collect();

        let raw_tunnels = coordinator.all_tunnels(handle)?;
        let tunnels = raw_tunnels
            .into_iter()
            .map(|t| TunnelLink {
                source_drawer_id: t.source_drawer_id.clone(),
                target_drawer_id: t.target_drawer_id.clone(),
            })
            .collect();

        // Snapshot dreamed-active tunnels for OMEGA retire evaluation (T13 / ADR-021 Phase 7).
        // `all_active_tunnels` excludes retired tunnels (bit 13 clear); filtering to
        // `is_dreamed() == true` enforces the §12.8 guard (declared tunnels never retired).
        // `source_drawer_id` and `target_drawer_id` are Options on the substrate type
        // (room-level tunnels have None endpoints); drawer-pair tunnels always have Some.
        // We skip room-level tunnels (None endpoints) — they cannot be dreamed and are
        // never in the retire population.
        let raw_active = coordinator.all_active_tunnels(handle)?;
        let dreamed_active = raw_active
            .into_iter()
            .filter(|t| t.is_dreamed())
            .filter_map(|t| {
                // Only drawer-pair tunnels (both endpoints Some) enter OMEGA.
                // Room-level tunnels (either endpoint None) are skipped.
                match (&t.source_drawer_id, &t.target_drawer_id) {
                    (Some(src), Some(tgt)) => Some(DreamingTunnelItem {
                        id: t.id.clone(),
                        source_drawer_id: src.clone(),
                        target_drawer_id: tgt.clone(),
                    }),
                    _ => None,
                }
            })
            .collect();

        Ok(EstateDreamingReader {
            traces,
            tunnels,
            dreamed_active,
            coordinator,
            handle: handle.clone(),
            now_epoch_secs,
        })
    }
}

impl<'a> DreamingSubstrateReader for EstateDreamingReader<'a> {
    fn recent_recall_traces(&self) -> Vec<CycleRecallTraceItem> {
        self.traces.clone()
    }

    /// Drain pending dreaming-queue windows from the estate (T8 v2).
    ///
    /// Each inner Vec is the set of drawer IDs from one DreamingItem — a
    /// single recall event that co-recalled ≥ 2 distinct drawers. Returns an
    /// empty Vec when the queue has no pending jobs.
    ///
    /// Delegates to `coordinator.drain_dreaming_items`, which drains the queue
    /// and replies Done to the consumed jobs — drain-once semantics. Matches
    /// Swift `EstateDreamingReader.drainDreamingWindow()`.
    fn drain_dreaming_window(&self) -> Vec<Vec<String>> {
        self.coordinator
            .drain_dreaming_items(&self.handle, self.now_epoch_secs)
            .unwrap_or_default()
    }

    fn existing_tunnels(&self) -> Vec<TunnelLink> {
        self.tunnels.clone()
    }

    /// All non-retired dreamed tunnels for OMEGA retire evaluation (T13 / ADR-021 Phase 7).
    ///
    /// Returns the snapshot taken at reader construction via
    /// `coordinator.all_active_tunnels` filtered to `is_dreamed() == true`.
    /// Matches the Swift `EstateDreamingReader.dreamedActiveTunnels()` which
    /// calls `kit.allActiveTunnels(in:handle)` then filters in-process.
    fn dreamed_active_tunnels(&self) -> Vec<DreamingTunnelItem> {
        self.dreamed_active.clone()
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

    // T8-RDR-1: fresh estate has no dreaming-queue jobs →
    // drain_dreaming_window returns empty.
    #[test]
    fn t8_rdr1_drain_returns_empty_on_fresh_estate() {
        let (coord, handle) = make_coordinator_and_handle();
        let reader = EstateDreamingReader::new(&coord, &handle, "2000-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z", 1_000_000.0)
            .expect("new");
        let windows = reader.drain_dreaming_window();
        assert!(windows.is_empty(), "fresh estate has no dreaming-queue jobs");
    }

    // T8-RDR-2: second drain returns empty (drain-once semantics — consumed
    // jobs do not reappear).
    #[test]
    fn t8_rdr2_second_drain_returns_empty() {
        let (coord, handle) = make_coordinator_and_handle();
        let reader = EstateDreamingReader::new(&coord, &handle, "2000-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z", 1_000_000.0)
            .expect("new");
        let first = reader.drain_dreaming_window();
        assert!(first.is_empty(), "first drain: empty on fresh estate");
        let second = reader.drain_dreaming_window();
        assert!(second.is_empty(), "second drain: empty (drain-once semantics)");
    }

    // T8-RDR-3: traces snapshot is correct — empty for a fresh estate.
    #[test]
    fn t8_rdr3_traces_empty_on_fresh_estate() {
        let (coord, handle) = make_coordinator_and_handle();
        let reader = EstateDreamingReader::new(&coord, &handle, "2000-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z", 1_000_000.0)
            .expect("new");
        let traces = reader.recent_recall_traces();
        assert!(traces.is_empty());
    }

    // T8-RDR-4: tunnels snapshot is correct — empty for a fresh estate.
    #[test]
    fn t8_rdr4_tunnels_empty_on_fresh_estate() {
        let (coord, handle) = make_coordinator_and_handle();
        let reader = EstateDreamingReader::new(&coord, &handle, "2000-01-01T00:00:00.000Z", "2099-01-01T00:00:00.000Z", 1_000_000.0)
            .expect("new");
        let tunnels = reader.existing_tunnels();
        assert!(tunnels.is_empty());
    }
}
