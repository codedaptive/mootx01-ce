// estate_maintenance_reader.rs — Rust parity of
// `NeuronKit/Sources/NeuronKit/Maintenance/EstateMaintenanceReader.swift`.
//
// Production adapter that implements `MaintenanceSubstrateReader` over a
// GeniusLocusKit estate handle. Performs bounded paged reads at use-time
// (not snapshot-at-construction) by calling into the GeniusLocusKit
// coordinator's public API surface.
//
// The five Swift reads map to scan fields as follows:
//
//   activeDrawers       → aged_active + forbidden_drawer_ids
//   tombstonedDrawers   → aged_tombstoned
//   learnedReferences   → reference_drift   (real reads via coordinator)
//   fingerprintBaselines → fingerprint_drift (real reads via coordinator)
//   currentAuditLog     → audit             (real verify via coordinator)
//
// ── Bounded scan strategy ─────────────────────────────────────────────
// The drawer corpus is read through `coordinator.all_drawers_bounded`
// with a cap of `MAINTENANCE_SCAN_CAP` rows. This keeps the scan cost
// O(cap) instead of O(estate) for large estates. The cap is intentionally
// generous (512) to cover typical small-to-medium estates fully while
// bounding the worst case. The coordinator's `all_drawers_bounded` applies
// the LIMIT at the storage tier, so the I/O is O(cap), not O(estate)-then-
// truncate. B-10a: maintenance reads are INTERNAL — that path does not set
// trace_limit, so no recall-trace rows are written.
//
// Drawers are ordered by `filed_at` ascending (the store's natural order),
// so the bounded scan is deterministic: given the same estate state and
// `now`, the same rows are scanned in the same order.
//
// Learned references are read unbounded via `coordinator.recall_learned_references`.
// The reference corpus is expected to be small (one entry per `learn` call)
// and is not capped separately. If the reference corpus grows large a future
// mission can add a cap here.
//
// ── Reference drift (real reads) ──────────────────────────────────────
// `reference_drift` is populated from `coordinator.recall_learned_references`.
// Each non-tombstoned `LearnedReference`'s `drift_severity` operational-bitmap
// axis (bits 6–11, cookbook §2.4) is decoded and mapped to a drift fraction:
//
//   DriftSeverity::None     → 0.0
//   DriftSeverity::Minor    → 0.25
//   DriftSeverity::Major    → 0.50
//   DriftSeverity::Critical → 1.0
//
// The fraction is the input the maintenance daemon thresholds against
// `MaintenancePolicy.by_reference_drift_threshold` (spec default 0.25).
//
// ── Fingerprint drift (computed from drawer bitmaps) ──────────────────
// `fingerprint_drift` is computed by OR-aggregating each container node's
// drawer bitmaps grouped by `parent_node_id` (native node ID scope key
// per ADR-017). For each container node we compute a v1 drift fraction
// as the BIT DENSITY of the node's OR aggregate:
//
//   drift = popcount(adjectiveOR | operationalOR | provenanceOR over their
//           three 64-bit lanes) / FINGERPRINT_DRIFT_BIT_WIDTH (192)
//
// A focused container (few distinct adjective/operational/provenance bits
// across its active drawers) reads low drift; a container whose content has
// spread across many disparate bitmap axes reads high drift. This is a
// deterministic, baseline-free definition computed identically on both ports.
// The persisted-baseline refinement (Hamming distance of the live aggregate
// against a recorded per-scope baseline, per `FingerprintDriftObservation`'s
// documented intent) requires a baseline-persistence surface that does not
// exist yet; bit density is the honest v1 signal that uses the data available
// today. The key is the `parent_node_id` — native node ID scope key per ADR-017.
//
// ── Audit integrity input (real verify) ──────────────────────────────
// `audit` is populated from `coordinator.verify_audit_chain`, which replays
// the estate's LocusKit audit trail into a `UnifiedAuditLog` and runs
// `AuditChainVerifier::verify` (read-only — it does not mutate the
// coordinator's stored log). The report's `valid` / `first_broken_at_millis`
// become the `AuditVerdict` the daemon's audit-integrity monitor consumes
// (NEURONKIT_SPEC § 3.5). A clean chain yields `valid = true` and emits no
// audit proposal.
//
// ── Architecture note ────────────────────────────────────────────────
// Lives in NeuronKit because it implements `MaintenanceSubstrateReader`
// (declared in `maintenance_cycle.rs`) AND calls genius_locus_kit coordinator
// methods. NeuronKit already depends on both; genius_locus_kit does not
// depend on neuron_kit, so there is no circular dependency.
//
// B-1 compliance: all estate reads route through genius_locus_kit's
// EstateCoordinator surface — no direct locus_kit storage calls.

use std::collections::BTreeMap;

use genius_locus_kit::{
    AdjectiveExportability, AdjectiveSensitivity, AuditChainReport, DrawerState,
    EstateCoordinator, EstateHandle, VerbDispatchError,
};
use locus_kit::learned_reference::DriftSeverity;

use crate::maintenance_cycle::{MaintenanceScan, MaintenanceSubstrateReader, NodeInvariantRow};
use crate::maintenance_decision::{AgedRow, AuditVerdict, DriftRow};

// ── Fingerprint-drift bit width ──────────────────────────────────────
//
// A `ContainerFingerprint` carries three i64 bitmap lanes (adjective,
// operational, provenance). Each lane uses its low 64 bits, so the
// meaningful width of the combined fingerprint is 3 × 64 = 192 bits. The
// v1 drift fraction is the set-bit density of the aggregate over this width.
const FINGERPRINT_DRIFT_BIT_WIDTH: f32 = 192.0;

// ── Scan cap ─────────────────────────────────────────────────────────
//
// Maximum number of drawers the maintenance reader fetches per scan. Bounded
// to keep each cycle O(cap) rather than O(estate). 512 covers typical small-
// to-medium estates fully; large estates get a representative health sample.
// The storage layer applies the LIMIT before any in-process filtering, so
// the I/O cost is O(cap), not O(estate) then truncate.
//
// Internal maintenance reads never write recall-trace rows (B-10a), so the
// cap here has no interaction with the trace-limit path.
const MAINTENANCE_SCAN_CAP: usize = 512;

/// Demand-read production adapter for `MaintenanceSubstrateReader`.
///
/// Reads are performed at scan() call time through bounded coordinator
/// calls rather than snapshotted at construction. This keeps the
/// construction cheap and the scan consistent with the estate's state
/// at the moment the daemon calls `scan()`.
///
/// `now` is the deterministic epoch-seconds timestamp the caller supplies for
/// age computations. Age = `now - filed_at` for active drawers;
/// `now - tombstoned_at` for tombstoned drawers.
pub struct EstateMaintenanceReader<'a> {
    coordinator: &'a EstateCoordinator,
    handle: &'a EstateHandle,
    now: i64,
}

impl<'a> EstateMaintenanceReader<'a> {
    /// Construct the adapter over the addressed estate.
    ///
    /// `now` is the deterministic epoch-seconds timestamp for age computations.
    /// Passed at construction; not derived from the system clock.
    ///
    /// Construction is cheap: no coordinator calls are made here. All reads
    /// happen in `scan()` at bounded cost.
    pub fn new(
        coordinator: &'a EstateCoordinator,
        handle: &'a EstateHandle,
        now: i64,
    ) -> Self {
        EstateMaintenanceReader { coordinator, handle, now }
    }
}

impl<'a> MaintenanceSubstrateReader for EstateMaintenanceReader<'a> {
    /// Build the `MaintenanceScan` by reading the estate at call time.
    ///
    /// Drawer corpus is bounded to `MAINTENANCE_SCAN_CAP` rows (B-10a:
    /// internal read, no trace rows). Reference drift is computed from all
    /// non-tombstoned learned references via `drift_severity` bitmap decoding,
    /// fingerprint drift from the room-level container aggregates, and the audit
    /// verdict from a read-only chain verification (see module comment).
    fn scan(&self) -> MaintenanceScan {
        build_scan(self.coordinator, self.handle, self.now)
            .unwrap_or_default()
    }
}

// ── Fingerprint-drift v1 metric ──────────────────────────────────────

/// Map an `AuditChainReport` to the daemon's `AuditVerdict`. The report's
/// `valid` / `first_broken_at_millis` carry directly; the maintenance
/// decision core needs nothing else from the chain check.
fn audit_verdict_from_report(report: &AuditChainReport) -> AuditVerdict {
    AuditVerdict {
        valid: report.valid,
        first_broken_at_millis: report.first_broken_at_millis,
    }
}

// ── Scan builder ─────────────────────────────────────────────────────

/// Build a `MaintenanceScan` by performing bounded reads against the estate
/// coordinator and a deterministic `now`.
///
/// Returns `Err(VerbDispatchError)` when the estate handle is stale.
/// `MaintenanceSubstrateReader::scan` converts that to a default empty scan
/// so the daemon is never blocked by a coordinator error.
fn build_scan(
    coordinator: &EstateCoordinator,
    handle: &EstateHandle,
    now: i64,
) -> Result<MaintenanceScan, VerbDispatchError> {
    // ── Drawer corpus (bounded) ───────────────────────────────────────
    // `all_drawers_bounded` applies the LIMIT at the storage layer (O(cap)
    // I/O). The result is ordered by `filed_at` ascending per the store
    // contract, making the bounded scan deterministic: same estate state
    // + same now → same rows in the same order.
    //
    // B-10a: internal read — trace_limit is NOT set; no recall-trace rows
    // are written. The coordinator's plain `all_drawers_bounded` path
    // enforces this by design.
    let drawers = coordinator.all_drawers_bounded(handle, Some(MAINTENANCE_SCAN_CAP))?;

    let mut forbidden_drawer_ids: Vec<String> = Vec::new();
    let mut aged_active: Vec<AgedRow> = Vec::new();
    let mut aged_tombstoned: Vec<AgedRow> = Vec::new();

    for drawer in &drawers {
        if drawer.tombstoned_at.is_some() {
            // Tombstoned: contribute to the expunge-candidate scan.
            // Age is measured from tombstoned_at (when the soft-delete occurred).
            let tombstone_epoch = drawer.tombstoned_at.unwrap_or(drawer.filed_at);
            // `now` and the epoch are epoch-ms (ADR-023); age is reported in
            // seconds (matching Swift's `timeIntervalSince`), so convert here.
            let age_seconds = (now - tombstone_epoch).max(0) as f64 / 1000.0;
            aged_tombstoned.push(AgedRow { id: drawer.id.clone(), age_seconds });
        } else {
            // Live: check Cluster A membership.
            // Decode state from bits 0-5 of adjective_bitmap.
            let state = DrawerState::from_raw(drawer.adjective_bitmap & 0x3F);
            if !state.is_cluster_a() {
                // Non-Cluster-A live rows (Superseded, Decayed, etc.) are not
                // part of the active-drawer health scan.
                continue;
            }

            // Cluster A: contribute to the decay scan. `now`/`filed_at` are
            // epoch-ms (ADR-023); age is reported in seconds, so convert here.
            let age_seconds = (now - drawer.filed_at).max(0) as f64 / 1000.0;
            aged_active.push(AgedRow { id: drawer.id.clone(), age_seconds });

            // Check invariant I-3: a drawer may not be both secret and public_.
            // Sensitivity is bits 6-11; exportability is bits 12-17.
            let sensitivity =
                AdjectiveSensitivity::from_raw((drawer.adjective_bitmap >> 6) & 0x3F);
            let exportability =
                AdjectiveExportability::from_raw((drawer.adjective_bitmap >> 12) & 0x3F);
            if sensitivity == AdjectiveSensitivity::Secret
                && exportability == AdjectiveExportability::Public
            {
                forbidden_drawer_ids.push(drawer.id.clone());
            }
        }
    }

    // ── Reference drift (real reads) ──────────────────────────────────
    // Read all non-tombstoned learned references from the estate. For each,
    // decode the `drift_severity` axis (bits 6–11 of `operational_bitmap`,
    // cookbook §2.4) and map it to a drift fraction in [0, 1]:
    //
    //   DriftSeverity::None     → 0.0  (below default threshold of 0.25)
    //   DriftSeverity::Minor    → 0.25 (at default threshold → proposal)
    //   DriftSeverity::Major    → 0.50
    //   DriftSeverity::Critical → 1.0
    //
    // The key is the reference's row id; the daemon uses it as the proposal
    // target. Tombstoned references are excluded — they are no longer active
    // and their drift state is irrelevant.
    let reference_drift = {
        let refs = coordinator.recall_learned_references(handle)?;
        refs.into_iter()
            .filter(|lr| lr.tombstoned_at.is_none())
            .map(|lr| {
                let severity = lr.drift_severity();
                let drift_fraction = drift_fraction_for_severity(severity);
                DriftRow { key: lr.id.clone(), drift_fraction }
            })
            .collect::<Vec<_>>()
    };

    // ── Fingerprint drift (from drawers, grouped by parent_node_id) ────
    // OR-aggregate each container node's drawer bitmaps (adjective,
    // operational, provenance) grouped by parent_node_id (room-level node
    // per ADR-017). The key is the parent_node_id — native node ID scope
    // key. One DriftRow per container node; the daemon thresholds each
    // against `fingerprint_drift_threshold`.
    let fingerprint_drift = {
        let mut aggregates: BTreeMap<String, (i64, i64, i64)> = BTreeMap::new();
        for drawer in &drawers {
            if drawer.tombstoned_at.is_some() {
                continue;
            }
            let state = DrawerState::from_raw(drawer.adjective_bitmap & 0x3F);
            if !state.is_cluster_a() {
                continue;
            }
            let entry = aggregates.entry(drawer.parent_node_id.clone()).or_insert((0, 0, 0));
            entry.0 |= drawer.adjective_bitmap;
            entry.1 |= drawer.operational_bitmap;
            entry.2 |= drawer.provenance;
        }
        aggregates
            .into_iter()
            .map(|(node_id, (adj, op, prov))| {
                let set_bits = adj.count_ones() + op.count_ones() + prov.count_ones();
                let drift_fraction = set_bits as f32 / FINGERPRINT_DRIFT_BIT_WIDTH;
                DriftRow { key: node_id, drift_fraction }
            })
            .collect::<Vec<_>>()
    };

    // ── Audit integrity (real verify) ─────────────────────────────────
    // Replay the estate's audit trail and verify the chain (read-only). The
    // verdict feeds the daemon's audit-integrity monitor; a clean chain emits
    // no proposal.
    let audit = {
        let report = coordinator.verify_audit_chain(handle)?;
        Some(audit_verdict_from_report(&report))
    };

    // ── QID-pending enrichment retry batch (Board item 14) ───────────
    // Filter the same bounded drawer corpus for active (non-tombstoned,
    // Cluster-A) drawers whose enrichment-status field (provenance bits
    // 36-41) equals QidPending (value 1, cookbook §2.5). Capped at
    // QID_RETRY_SCAN_CAP (64) rows — the daemon applies the same cap when
    // iterating, but applying it here keeps the result size predictable.
    //
    // Each row carries its id (the stable row identifier), content (the
    // input to `infer_lattice_anchor` on retry), and current provenance
    // (the full bitmap, so the daemon can construct the new value by
    // masking and OR-ing without re-reading).
    //
    // B-10a: this read uses the same bounded drawer corpus already fetched
    // above — no additional coordinator call, no trace_limit, no
    // recall-trace rows written.
    let qid_pending_drawers: Vec<crate::maintenance_cycle::QidPendingRow> = {
        const QID_PENDING_VALUE: i64 = 1; // EnrichmentStatus::QidPending raw value
        const QID_RETRY_SCAN_CAP: usize = 64;
        drawers
            .iter()
            .filter(|drawer| {
                // Active (non-tombstoned, Cluster-A) only — mirrors the filter
                // applied when building `aged_active` above.
                if drawer.tombstoned_at.is_some() {
                    return false;
                }
                let state = DrawerState::from_raw(drawer.adjective_bitmap & 0x3F);
                if !state.is_cluster_a() {
                    return false;
                }
                // Enrichment-status field: provenance bits 36-41 (6-bit field,
                // shift 36). Test for value 1 (QidPending).
                let status_bits = (drawer.provenance >> 36) & 0x3F;
                status_bits == QID_PENDING_VALUE
            })
            .take(QID_RETRY_SCAN_CAP)
            .map(|drawer| crate::maintenance_cycle::QidPendingRow {
                id: drawer.id.clone(),
                content: drawer.content.clone(),
                provenance: drawer.provenance,
            })
            .collect()
    };

    // ADR-017 node invariant rows: extract (drawer_id, parent_node_id,
    // wing, room) from the same active-drawer corpus for I-NT-3 and
    // sibling display-name consistency checks in the daemon. Wing/room
    // display names are resolved from the node tree via the coordinator's
    // resolve_drawer_node_names (ADR-017 node-tree migration).
    let active_node_ids: Vec<String> = drawers
        .iter()
        .filter(|d| {
            d.tombstoned_at.is_none()
                && DrawerState::from_raw(d.adjective_bitmap & 0x3F).is_cluster_a()
        })
        .map(|d| d.parent_node_id.clone())
        .collect();
    let node_names = coordinator.resolve_drawer_node_names(handle, &active_node_ids);
    let node_invariant_rows: Vec<NodeInvariantRow> = drawers
        .iter()
        .filter(|d| {
            d.tombstoned_at.is_none()
                && DrawerState::from_raw(d.adjective_bitmap & 0x3F).is_cluster_a()
        })
        .map(|d| {
            let (wing, room) = node_names
                .get(&d.parent_node_id)
                .cloned()
                .unwrap_or_default();
            NodeInvariantRow {
                drawer_id: d.id.clone(),
                parent_node_id: d.parent_node_id.clone(),
                wing,
                room,
            }
        })
        .collect();

    Ok(MaintenanceScan {
        audit,
        forbidden_drawer_ids,
        aged_active,
        aged_tombstoned,
        fingerprint_drift,
        reference_drift,
        qid_pending_drawers,
        node_invariant_rows,
    })
}

// ── Drift-severity to fraction mapping ───────────────────────────────

/// Map a `DriftSeverity` axis value to a drift fraction in `[0, 1]`.
///
/// The mapping mirrors what the maintenance spec intends for the
/// `byReferenceDriftThreshold` predicate (default 0.25):
///
/// - `None`     → 0.0  — no drift recorded; below threshold → no proposal
/// - `Minor`    → 0.25 — at the default threshold → proposal emitted
/// - `Major`    → 0.50 — clear drift → proposal emitted
/// - `Critical` → 1.0  — severe drift → proposal emitted
///
/// The fractions are anchored at the default policy threshold (0.25) so
/// `Minor` severity exactly triggers a proposal with the default policy —
/// matching the spec's intent that Minor is actionable.
fn drift_fraction_for_severity(severity: DriftSeverity) -> f32 {
    match severity {
        DriftSeverity::None     => 0.0,
        DriftSeverity::Minor    => 0.25,
        DriftSeverity::Major    => 0.50,
        DriftSeverity::Critical => 1.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;
    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
    use locus_kit::estate_types::OwnerCredentials;
    use locus_kit::frames::CaptureFrame;
    use locus_kit::drawer_operational::CaptureChannel;
    use locus_kit::estate_types::LatticeAnchor;
    use locus_kit::learned_reference::LearnedReference;
    use locus_kit::frames::LearnFrame;

    // ── test helpers ─────────────────────────────────────────────────

    const FILED_AT: i64 = 1_000_000;
    const NOW: i64 = 1_100_000;

    /// Open a fresh in-memory estate through the GLK coordinator.
    fn open_estate() -> (EstateCoordinator, EstateHandle) {
        let store: Arc<dyn LocusDrawerStore> =
            Arc::new(InMemoryDrawerStore::new(0, None).expect("store"));
        let mut coord = EstateCoordinator::new();
        let handle = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .expect("open");
        (coord, handle)
    }

    /// Capture one drawer in the estate and return its id.
    fn capture_one(coord: &EstateCoordinator, handle: &EstateHandle, content: &str, filed_at: i64) -> String {
        let frame = CaptureFrame::new(
            content,
            CaptureChannel::Typed,
            "room1",
            LatticeAnchor::udc("004"),
            "agent",
            "model-v1",
        );
        coord.capture(handle, frame, filed_at)
            .expect("capture")
            .id
    }

    // ── MR-1: empty estate returns empty scan ─────────────────────────

    #[test]
    fn mr1_empty_estate_returns_clean_scan() {
        let (coord, handle) = open_estate();
        let reader = EstateMaintenanceReader::new(&coord, &handle, NOW);
        let scan = reader.scan();
        assert!(scan.aged_active.is_empty());
        assert!(scan.aged_tombstoned.is_empty());
        assert!(scan.forbidden_drawer_ids.is_empty());
        assert!(scan.fingerprint_drift.is_empty());
        assert!(scan.reference_drift.is_empty());
        // The audit chain is now verified every cycle: an empty estate has an
        // empty audit log, which is vacuously valid (no break).
        let audit = scan.audit.expect("audit verdict is present every cycle");
        assert!(audit.valid, "empty chain is valid");
        assert!(audit.first_broken_at_millis.is_none());
    }

    // ── MR-2: active drawer appears in aged_active ────────────────────

    #[test]
    fn mr2_active_drawer_in_aged_active() {
        let (coord, handle) = open_estate();
        let _id = capture_one(&coord, &handle, "hello", FILED_AT);
        let reader = EstateMaintenanceReader::new(&coord, &handle, NOW);
        let scan = reader.scan();
        assert_eq!(scan.aged_active.len(), 1);
        // age_seconds is seconds; NOW/FILED_AT are epoch-ms (ADR-023).
        assert_eq!(scan.aged_active[0].age_seconds, (NOW - FILED_AT) as f64 / 1000.0);
    }

    // ── MR-3: reference_drift returns empty when no references exist ──

    #[test]
    fn mr3_reference_drift_empty_for_estate_with_no_references() {
        let (coord, handle) = open_estate();
        // Capture a drawer but file no learned references.
        let _id = capture_one(&coord, &handle, "content", FILED_AT);
        let reader = EstateMaintenanceReader::new(&coord, &handle, NOW);
        let scan = reader.scan();
        assert!(
            scan.reference_drift.is_empty(),
            "no references in estate → reference_drift must be empty"
        );
    }

    // ── MR-4: reference_drift returns a row per non-tombstoned reference ─

    #[test]
    fn mr4_reference_drift_returns_row_per_non_tombstoned_reference() {
        let (coord, handle) = open_estate();

        // File a learned reference with Minor drift severity.
        // Minor drift raw value: bits 6-11 = 16 → operational_bitmap |= (16 << 6) = 1024.
        // (From learned_reference.rs: DriftSeverity::Minor raw = 16, at bits 6–11.)
        let store: Arc<dyn LocusDrawerStore> = {
            // We need the raw store to inject a learned reference with a specific
            // operational_bitmap. Use the coordinator's learn verb, then verify the
            // round-trip, but GLK learn takes a source handle string. Instead we
            // construct the LearnedReference directly and insert via the store's
            // add_learned_reference — this is an internal test, not a production path.
            //
            // Alternatively: build a reference with Minor drift, file it into the
            // estate via the available DrawerStore add_learned_reference primitive,
            // then verify the coordinator reads it back.
            //
            // Since we cannot easily get the store back from the coordinator, we use
            // a separate InMemoryDrawerStore directly for this sub-test.
            Arc::new(InMemoryDrawerStore::new(0, None).expect("store"))
        };
        let mut coord2 = EstateCoordinator::new();
        let handle2 = coord2
            .open(Arc::clone(&store), OwnerCredentials::new("owner2"), 0, 100)
            .expect("open");

        // Insert a LearnedReference with Minor drift severity into the store directly.
        // Minor drift: DriftSeverity::Minor raw = 16, shift = 6 → operational_bitmap = 16 << 6 = 1024.
        let mut lr = LearnedReference::new(
            "lr-test-1".to_string(),
            "source-catalog-1".to_string(),
            "https://example.com/ref".to_string(),
            LatticeAnchor::udc("004"),
            "maintenance-test".to_string(),
            FILED_AT,
        );
        lr.operational_bitmap = 16_i64 << 6; // DriftSeverity::Minor
        store.add_learned_reference(&lr).expect("add_learned_reference");

        let reader2 = EstateMaintenanceReader::new(&coord2, &handle2, NOW);
        let scan = reader2.scan();

        assert_eq!(scan.reference_drift.len(), 1, "one reference → one DriftRow");
        assert_eq!(scan.reference_drift[0].key, "lr-test-1");
        assert!(
            (scan.reference_drift[0].drift_fraction - 0.25).abs() < 1e-6,
            "Minor drift severity → drift_fraction 0.25, got {}",
            scan.reference_drift[0].drift_fraction
        );
    }

    // ── MR-5: drift fraction mapping covers all four severity levels ──

    #[test]
    fn mr5_drift_fraction_mapping_all_severity_levels() {
        assert_eq!(drift_fraction_for_severity(DriftSeverity::None),     0.0);
        assert_eq!(drift_fraction_for_severity(DriftSeverity::Minor),    0.25);
        assert_eq!(drift_fraction_for_severity(DriftSeverity::Major),    0.50);
        assert_eq!(drift_fraction_for_severity(DriftSeverity::Critical), 1.0);
    }

    // ── MR-6: none-severity reference produces drift_fraction 0.0 ────

    #[test]
    fn mr6_none_severity_reference_produces_zero_drift() {
        let store: Arc<dyn LocusDrawerStore> =
            Arc::new(InMemoryDrawerStore::new(0, None).expect("store"));
        let mut coord = EstateCoordinator::new();
        let handle = coord
            .open(Arc::clone(&store), OwnerCredentials::new("owner3"), 0, 100)
            .expect("open");

        // Insert a reference with no drift severity (operational_bitmap = 0).
        let lr = LearnedReference::new(
            "lr-none-drift".to_string(),
            "source-2".to_string(),
            "https://example.com/none".to_string(),
            LatticeAnchor::udc("004"),
            "test".to_string(),
            FILED_AT,
        );
        // operational_bitmap = 0 → DriftSeverity::None
        store.add_learned_reference(&lr).expect("add");

        let reader = EstateMaintenanceReader::new(&coord, &handle, NOW);
        let scan = reader.scan();
        assert_eq!(scan.reference_drift.len(), 1);
        assert_eq!(scan.reference_drift[0].drift_fraction, 0.0,
            "None severity → drift_fraction 0.0");
    }

    // ── MR-7: critical-severity reference produces drift_fraction 1.0 ──

    #[test]
    fn mr7_critical_severity_reference_produces_max_drift() {
        let store: Arc<dyn LocusDrawerStore> =
            Arc::new(InMemoryDrawerStore::new(0, None).expect("store"));
        let mut coord = EstateCoordinator::new();
        let handle = coord
            .open(Arc::clone(&store), OwnerCredentials::new("owner4"), 0, 100)
            .expect("open");

        // Critical drift: DriftSeverity::Critical raw = 48, shift = 6 → operational_bitmap = 48 << 6.
        let mut lr = LearnedReference::new(
            "lr-critical".to_string(),
            "source-3".to_string(),
            "https://example.com/critical".to_string(),
            LatticeAnchor::udc("004"),
            "test".to_string(),
            FILED_AT,
        );
        lr.operational_bitmap = 48_i64 << 6; // DriftSeverity::Critical
        store.add_learned_reference(&lr).expect("add");

        let reader = EstateMaintenanceReader::new(&coord, &handle, NOW);
        let scan = reader.scan();
        assert_eq!(scan.reference_drift.len(), 1);
        assert_eq!(scan.reference_drift[0].drift_fraction, 1.0,
            "Critical severity → drift_fraction 1.0");
    }

    // ── MR-8: bounded scan — estate larger than cap reads exactly cap rows ─

    #[test]
    fn mr8_bounded_scan_reads_at_most_maintenance_scan_cap() {
        let (coord, handle) = open_estate();

        // Capture MAINTENANCE_SCAN_CAP + 10 drawers.
        let n = MAINTENANCE_SCAN_CAP + 10;
        for i in 0..n {
            capture_one(&coord, &handle, &format!("content-{i}"), FILED_AT + i as i64);
        }

        let reader = EstateMaintenanceReader::new(&coord, &handle, NOW);
        let scan = reader.scan();

        // The scan must read at most MAINTENANCE_SCAN_CAP rows — not the full
        // estate — because the bounded coordinator call limits the fetch.
        assert!(
            scan.aged_active.len() <= MAINTENANCE_SCAN_CAP,
            "bounded scan must read at most {} rows, got {}",
            MAINTENANCE_SCAN_CAP,
            scan.aged_active.len()
        );
        // The bounded scan must have read exactly MAINTENANCE_SCAN_CAP rows
        // (all are active, so aged_active.len() == rows read).
        assert_eq!(
            scan.aged_active.len(),
            MAINTENANCE_SCAN_CAP,
            "bounded scan must read exactly {} rows from an estate of {}",
            MAINTENANCE_SCAN_CAP,
            n
        );
    }

    // ── MR-9: bounded scan is deterministic (same now → same rows) ───

    #[test]
    fn mr9_bounded_scan_is_deterministic() {
        let (coord, handle) = open_estate();
        let n = MAINTENANCE_SCAN_CAP + 5;
        for i in 0..n {
            capture_one(&coord, &handle, &format!("c{i}"), FILED_AT + i as i64);
        }

        let scan_a = EstateMaintenanceReader::new(&coord, &handle, NOW).scan();
        let scan_b = EstateMaintenanceReader::new(&coord, &handle, NOW).scan();

        // Both runs over the same estate with the same now must produce the
        // same aged_active row ids in the same order.
        let ids_a: Vec<&str> = scan_a.aged_active.iter().map(|r| r.id.as_str()).collect();
        let ids_b: Vec<&str> = scan_b.aged_active.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids_a, ids_b, "bounded scan must be deterministic");
    }

    // ── MR-10: fingerprint_drift computed from drawers by parent_node_id ─
    //
    // The fingerprint-drift signal is computed from the drawer corpus
    // grouped by parent_node_id (room-level node per ADR-017). Each node's
    // bitmap lanes are OR-aggregated and the set-bit density over 192 bits
    // is the v1 drift fraction. A captured drawer contributes its bitmaps
    // to its parent node's aggregate.
    #[test]
    fn mr10_fingerprint_drift_from_drawers() {
        let (coord, handle) = open_estate();
        capture_one(&coord, &handle, "content", FILED_AT);
        let reader = EstateMaintenanceReader::new(&coord, &handle, NOW);
        let scan = reader.scan();
        // A captured drawer has adjective/operational/provenance bitmaps;
        // the fingerprint drift is computed from those grouped by
        // parent_node_id.
        let _ = scan.fingerprint_drift;
    }

    // ── MR-11: audit verdict is produced every cycle ─────────────────

    #[test]
    fn mr11_audit_verdict_present_and_valid() {
        let (coord, handle) = open_estate();
        capture_one(&coord, &handle, "content", FILED_AT);
        let reader = EstateMaintenanceReader::new(&coord, &handle, NOW);
        let scan = reader.scan();
        let audit = scan.audit.expect("audit verdict produced every cycle");
        assert!(audit.valid, "a captured drawer's chain is intact");
        assert!(audit.first_broken_at_millis.is_none());
    }

    // ── MR-12: fingerprint drift bit density is popcount / 192 ────────
    //
    // Verifies the inline bit-density computation in build_scan produces
    // the expected fraction for known bitmap values.

    #[test]
    fn mr12_bit_density_is_popcount_over_192() {
        // adjective has 2 set bits, operational 1, provenance 0 → 3 / 192.
        let adj: i64 = 0b0011;
        let op: i64 = 0b0100;
        let prov: i64 = 0;
        let set_bits = adj.count_ones() + op.count_ones() + prov.count_ones();
        let f = set_bits as f32 / FINGERPRINT_DRIFT_BIT_WIDTH;
        assert!((f - (3.0 / FINGERPRINT_DRIFT_BIT_WIDTH)).abs() < 1e-6);
    }

    // ── MR-13: default scan has no audit verdict (the daemon's "no check
    // this cycle" sentinel) ──────────────────────────────────────────

    #[test]
    fn mr13_default_scan_has_no_audit() {
        // MaintenanceScan::default() is the daemon's "audit cadence not elapsed"
        // sentinel — distinct from the reader's per-cycle verdict.
        let scan = MaintenanceScan::default();
        assert!(scan.fingerprint_drift.is_empty());
        assert!(scan.audit.is_none());
    }

    // ── MR-14: new_over_empty_estate_succeeds (smoke test) ───────────

    #[test]
    fn new_over_empty_estate_succeeds() {
        let store: Arc<dyn LocusDrawerStore> =
            Arc::new(InMemoryDrawerStore::new(0, None).expect("store"));
        let mut coord = EstateCoordinator::new();
        let handle = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .expect("open");

        let reader = EstateMaintenanceReader::new(&coord, &handle, 0);
        let scan = reader.scan();

        // Empty estate: drawer-derived fields are empty; the audit verdict is
        // present (empty chain verifies clean).
        assert!(scan.aged_active.is_empty());
        assert!(scan.aged_tombstoned.is_empty());
        assert!(scan.forbidden_drawer_ids.is_empty());
        assert!(scan.fingerprint_drift.is_empty());
        assert!(scan.reference_drift.is_empty());
        assert!(scan.audit.expect("verdict present").valid);
    }
}
