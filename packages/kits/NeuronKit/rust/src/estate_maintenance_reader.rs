// estate_maintenance_reader.rs — Rust parity of
// `NeuronKit/Sources/NeuronKit/Maintenance/EstateMaintenanceReader.swift`.
//
// Production adapter that implements `MaintenanceSubstrateReader` over a
// GeniusLocusKit estate handle. Unlike the Swift struct that performs
// five async reads on demand, the Rust version pre-fetches all drawers at
// construction time and builds the `MaintenanceScan` from the snapshot.
//
// The five Swift reads map to scan fields as follows:
//
//   activeDrawers       → aged_active + forbidden_drawer_ids
//   tombstonedDrawers   → aged_tombstoned
//   learnedReferences   → reference_drift (v1: [])
//   fingerprintBaselines → fingerprint_drift (v1: [])
//   currentAuditLog     → audit (v1: None)
//
// ── v1 stubs ─────────────────────────────────────────────────────────
// `reference_drift` and `fingerprint_drift` are `[]` in v1. `audit` is
// `None`, so the daemon skips the audit-integrity check this cycle. Both
// gaps mirror the Swift v1 stubs and are safe: no proposals are emitted for
// these categories until the follow-on missions add the full computation.
//
// ── State and exportability decoding ─────────────────────────────────
// The Rust `Drawer` type's `state()` and `exportability()` accessors are
// pending in `drawer_operational.rs` (adjectives.rs module note). This
// adapter decodes the bits directly from `adjective_bitmap` using the
// `DrawerState::from_raw` and `AdjectiveExportability::from_raw` functions,
// which are implemented and correct. This is the established pattern for
// callers that need these axes before the accessor lands.
//
// ── Architecture note ────────────────────────────────────────────────
// Lives in NeuronKit because it implements `MaintenanceSubstrateReader`
// (declared in `maintenance_cycle.rs`) AND calls genius_locus_kit coordinator
// methods. NeuronKit already depends on both; genius_locus_kit does not
// depend on neuron_kit, so there is no circular dependency.
//
// B-1 compliance: all estate reads route through genius_locus_kit's
// EstateCoordinator surface — no direct locus_kit storage calls.

use genius_locus_kit::{
    AdjectiveExportability, AdjectiveSensitivity, Drawer, DrawerState, EstateCoordinator,
    EstateHandle, VerbDispatchError,
};

use crate::maintenance_cycle::{MaintenanceScan, MaintenanceSubstrateReader};
use crate::maintenance_decision::AgedRow;

/// Snapshot-based production adapter for `MaintenanceSubstrateReader`.
///
/// Reads are snapshotted from the estate at construction via
/// `EstateMaintenanceReader::new`. The `scan()` method returns the
/// pre-computed scan from those snapshots, so no coordinator call is needed
/// after construction. This matches the Rust `MaintenanceSubstrateReader`
/// trait contract (sync, single `scan()` call).
///
/// `now` is the deterministic epoch-seconds timestamp the caller supplies for
/// age computations. Age = `now - filed_at` for active drawers;
/// `now - tombstoned_at` for tombstoned drawers.
pub struct EstateMaintenanceReader {
    scan: MaintenanceScan,
}

impl EstateMaintenanceReader {
    /// Construct the adapter by snapshotting the drawer corpus from the
    /// addressed estate through the GeniusLocusKit coordinator surface.
    ///
    /// `now` is the deterministic epoch-seconds timestamp for age computations.
    /// Passed at construction; not derived from the system clock.
    ///
    /// All reads go through `coordinator.all_drawers` — B-1 compliant.
    pub fn new(
        coordinator: &EstateCoordinator,
        handle: &EstateHandle,
        now: i64,
    ) -> Result<Self, VerbDispatchError> {
        let drawers = coordinator.all_drawers(handle)?;
        let scan = build_scan(&drawers, now);
        Ok(EstateMaintenanceReader { scan })
    }
}

impl MaintenanceSubstrateReader for EstateMaintenanceReader {
    /// Return the pre-computed `MaintenanceScan` built at construction.
    fn scan(&self) -> MaintenanceScan {
        self.scan.clone()
    }
}

// ── Scan builder ─────────────────────────────────────────────────────

/// Build a `MaintenanceScan` from a drawer snapshot and a deterministic `now`.
///
/// Active drawers (non-tombstoned + Cluster A) contribute to `aged_active`
/// and to `forbidden_drawer_ids` (I-3: secret AND public). Tombstoned drawers
/// contribute to `aged_tombstoned`. v1 stubs: `fingerprint_drift = []`,
/// `reference_drift = []`, `audit = None`.
fn build_scan(drawers: &[Drawer], now: i64) -> MaintenanceScan {
    let mut forbidden_drawer_ids: Vec<String> = Vec::new();
    let mut aged_active: Vec<AgedRow> = Vec::new();
    let mut aged_tombstoned: Vec<AgedRow> = Vec::new();

    for drawer in drawers {
        if drawer.tombstoned_at.is_some() {
            // Tombstoned: contribute to the expunge-candidate scan.
            // Age is measured from tombstoned_at (when the soft-delete occurred).
            let tombstone_epoch = drawer.tombstoned_at.unwrap_or(drawer.filed_at);
            let age_seconds = (now - tombstone_epoch).max(0) as f64;
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

            // Cluster A: contribute to the decay scan.
            let age_seconds = (now - drawer.filed_at).max(0) as f64;
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

    MaintenanceScan {
        // v1: no audit check — the Rust port defers audit-chain verification
        // integration to a follow-on mission. `audit: None` means the daemon
        // skips the audit-integrity monitor this cycle.
        audit: None,
        forbidden_drawer_ids,
        aged_active,
        aged_tombstoned,
        // v1: fingerprint baselines require ContainerFingerprintStore read
        // path (follow-on mission).
        fingerprint_drift: vec![],
        // v1: learned-reference drift requires DrawerStore::all_learned_references
        // (follow-on mission to add the full-corpus scan to LocusKit).
        reference_drift: vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tests mirror the dreaming reader's pattern: test the `build_scan`
    // helper directly with hand-crafted Drawer objects. This avoids
    // needing a full coordinator + estate for unit-level assertions; the
    // coordinator path is exercised by the GLK integration tests and by
    // the empty-estate smoke test below.

    const FILED_AT: i64 = 1_000_000;
    const NOW: i64 = 1_100_000;

    fn make_drawer(id: &str, filed_at: i64) -> Drawer {
        Drawer::new(id, format!("content-{id}"), "wing1", "room1", "agent", filed_at, "model-v1")
    }

    fn make_tombstoned(id: &str, filed_at: i64, tombstoned_at: i64) -> Drawer {
        let mut d = make_drawer(id, filed_at);
        d.tombstoned_at = Some(tombstoned_at);
        d
    }

    // ── build_scan unit tests ─────────────────────────────────────────

    #[test]
    fn active_drawer_in_aged_active() {
        let drawers = vec![make_drawer("a", FILED_AT)];
        let scan = build_scan(&drawers, NOW);
        assert_eq!(scan.aged_active.len(), 1);
        assert_eq!(scan.aged_active[0].id, "a");
        assert_eq!(scan.aged_active[0].age_seconds, (NOW - FILED_AT) as f64);
    }

    #[test]
    fn tombstoned_drawer_in_aged_tombstoned_not_active() {
        // tombstoned_at = FILED_AT + 500, so age from tombstone = 100_000 - 500 seconds
        let drawers = vec![make_tombstoned("b", FILED_AT, FILED_AT + 500)];
        let scan = build_scan(&drawers, NOW);
        assert!(scan.aged_active.is_empty(), "tombstoned row must not appear in aged_active");
        assert_eq!(scan.aged_tombstoned.len(), 1);
        assert_eq!(scan.aged_tombstoned[0].id, "b");
        assert_eq!(scan.aged_tombstoned[0].age_seconds, (NOW - FILED_AT - 500) as f64);
    }

    #[test]
    fn forbidden_combination_detected() {
        // InMemoryDrawerStore rejects secret+public at write time (I-22 gate).
        // Test build_scan directly to exercise the detection path for rows that
        // may arrive via migration or exist in older databases.
        //
        // sensitivity = Secret: bits 6–11, raw value 48 (0b110000) → bitmap |= (48 << 6)
        // exportability = Public: bits 12–17, raw value 32 (0b100000) → bitmap |= (32 << 12)
        let mut drawer = make_drawer("c", FILED_AT);
        drawer.adjective_bitmap = (48_i64 << 6) | (32_i64 << 12);
        let scan = build_scan(&[drawer], NOW);
        assert!(scan.forbidden_drawer_ids.contains(&"c".to_string()));
    }

    #[test]
    fn normal_drawer_not_in_forbidden() {
        let scan = build_scan(&[make_drawer("d", FILED_AT)], NOW);
        assert!(!scan.forbidden_drawer_ids.contains(&"d".to_string()));
    }

    #[test]
    fn v1_stubs_are_empty() {
        let scan = build_scan(&[], 0);
        assert!(scan.fingerprint_drift.is_empty(), "v1: no fingerprint drift");
        assert!(scan.reference_drift.is_empty(), "v1: no reference drift");
        assert!(scan.audit.is_none(), "v1: no audit verdict");
    }

    // ── EstateMaintenanceReader::new smoke test ───────────────────────

    #[test]
    fn new_over_empty_estate_succeeds() {
        use std::sync::Arc;
        use locus_kit::drawer_store::DrawerStore as LocusDrawerStore;
        use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;
        use locus_kit::estate_types::OwnerCredentials;

        let store: Arc<dyn LocusDrawerStore> =
            Arc::new(InMemoryDrawerStore::new(0, None).expect("store"));
        let mut coord = EstateCoordinator::new();
        let handle = coord
            .open(store, OwnerCredentials::new("owner"), 0, 100)
            .expect("open");

        let reader = EstateMaintenanceReader::new(&coord, &handle, 0).expect("reader");
        let scan = reader.scan();

        // Empty estate: all scan fields should be their zero/empty defaults.
        assert!(scan.aged_active.is_empty());
        assert!(scan.aged_tombstoned.is_empty());
        assert!(scan.forbidden_drawer_ids.is_empty());
        assert!(scan.fingerprint_drift.is_empty());
        assert!(scan.reference_drift.is_empty());
        assert!(scan.audit.is_none());
    }
}
