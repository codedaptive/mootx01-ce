// estate_maintenance_reader.rs — Rust parity of
// `NeuronKit/Sources/NeuronKit/Maintenance/EstateMaintenanceReader.swift`.
//
// Production adapter that implements `MaintenanceSubstrateReader` over a
// synchronous `DrawerStore` reference. Unlike the Swift struct that performs
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
// `State::from_raw` and `AdjectiveExportability::from_raw` functions,
// which are implemented and correct. This is the established pattern for
// callers that need these axes before the accessor lands.
//
// ── Architecture note ────────────────────────────────────────────────
// Lives in NeuronKit because it implements `MaintenanceSubstrateReader`
// (declared in `maintenance_cycle.rs`) AND calls locus-kit DrawerStore
// methods. NeuronKit already depends on both; locus-kit does not depend
// on neuron-kit, so there is no circular dependency.

use locus_kit::adjectives::{AdjectiveExportability, AdjectiveSensitivity, State};
use locus_kit::drawer::Drawer;
use locus_kit::drawer_store::DrawerStore;
use locus_kit::error::LocusKitError;

use crate::maintenance_cycle::{MaintenanceScan, MaintenanceSubstrateReader};
use crate::maintenance_decision::AgedRow;

/// Snapshot-based production adapter for `MaintenanceSubstrateReader`.
///
/// Reads are snapshotted from the store at construction via
/// `EstateMaintenanceReader::new`. The `scan()` method returns the
/// pre-computed scan from those snapshots, so no store call is needed
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
    /// Construct the adapter by snapshotting the drawer corpus from `store`.
    ///
    /// `now` is the deterministic epoch-seconds timestamp for age computations.
    /// Passed at construction; not derived from the system clock.
    pub fn new<S: DrawerStore>(store: &S, now: i64) -> Result<Self, LocusKitError> {
        let drawers = store.all_drawers()?;
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
            let state = State::from_raw(drawer.adjective_bitmap & 0x3F);
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

    use locus_kit::drawer_store_inmemory::InMemoryDrawerStore;

    fn make_store() -> InMemoryDrawerStore {
        InMemoryDrawerStore::new(0, None).expect("store")
    }

    // Use UUID-formatted IDs — InMemoryDrawerStore rejects non-UUID ids.
    const ID_A: &str = "00000000-0000-0000-0000-000000000001";
    const ID_B: &str = "00000000-0000-0000-0000-000000000002";
    const ID_C: &str = "00000000-0000-0000-0000-000000000003";
    const ID_D: &str = "00000000-0000-0000-0000-000000000004";

    fn make_drawer(id: &str, filed_at: i64) -> Drawer {
        Drawer::new(id, format!("content-{id}"), "wing1", "room1", "agent", filed_at, "model-v1")
    }

    fn make_tombstoned_drawer(id: &str, filed_at: i64, tombstoned_at: i64) -> Drawer {
        let mut d = make_drawer(id, filed_at);
        d.tombstoned_at = Some(tombstoned_at);
        d
    }

    #[test]
    fn active_drawers_appear_in_aged_active() {
        let store = make_store();
        let drawer = make_drawer(ID_A, 1_000_000);
        store.add_drawer(&drawer, drawer.filed_at).expect("add");

        let reader = EstateMaintenanceReader::new(&store, 1_100_000).expect("reader");
        let scan = reader.scan();

        assert_eq!(scan.aged_active.len(), 1, "expected one active drawer");
        assert_eq!(scan.aged_active[0].id, ID_A);
        // Age = 1_100_000 - 1_000_000 = 100_000 seconds.
        assert_eq!(scan.aged_active[0].age_seconds, 100_000.0);
    }

    #[test]
    fn tombstoned_drawers_appear_in_aged_tombstoned() {
        let store = make_store();
        // filed at 1_000_000, tombstoned at 1_050_000
        let drawer = make_tombstoned_drawer(ID_B, 1_000_000, 1_050_000);
        store.add_drawer(&drawer, drawer.filed_at).expect("add");

        let reader = EstateMaintenanceReader::new(&store, 1_100_000).expect("reader");
        let scan = reader.scan();

        assert!(scan.aged_active.is_empty(), "tombstoned drawer must not be in aged_active");
        assert_eq!(scan.aged_tombstoned.len(), 1);
        assert_eq!(scan.aged_tombstoned[0].id, ID_B);
        // Age measured from tombstoned_at: 1_100_000 - 1_050_000 = 50_000 seconds.
        assert_eq!(scan.aged_tombstoned[0].age_seconds, 50_000.0);
    }

    #[test]
    fn forbidden_combination_detected() {
        // InMemoryDrawerStore rejects the secret+public combination at write time
        // (invariant I-22 gate). Test `build_scan` directly with a manually crafted
        // Drawer so we can exercise the detection logic for rows that may exist
        // in older databases or arrive via migration.
        let mut drawer = make_drawer(ID_C, 1_000_000);
        // Set sensitivity = Secret (bits 6-11, raw 48 = 0b110000 << 6 = 3072)
        // Set exportability = Public (bits 12-17, raw 32 = 0b100000 << 12 = 131072)
        // adjective_bitmap = 3072 | 131072 = 134144
        drawer.adjective_bitmap = (48_i64 << 6) | (32_i64 << 12);

        let scan = super::build_scan(&[drawer], 1_100_000);

        assert!(
            scan.forbidden_drawer_ids.contains(&ID_C.to_string()),
            "expected {ID_C} in forbidden_drawer_ids"
        );
    }

    #[test]
    fn normal_drawer_not_in_forbidden() {
        let store = make_store();
        let drawer = make_drawer(ID_D, 1_000_000);
        store.add_drawer(&drawer, drawer.filed_at).expect("add");

        let reader = EstateMaintenanceReader::new(&store, 1_100_000).expect("reader");
        let scan = reader.scan();

        assert!(
            !scan.forbidden_drawer_ids.contains(&ID_D.to_string()),
            "normal drawer must not be in forbidden_drawer_ids"
        );
    }

    #[test]
    fn v1_stubs_are_empty() {
        let store = make_store();
        let reader = EstateMaintenanceReader::new(&store, 0).expect("reader");
        let scan = reader.scan();
        assert!(scan.fingerprint_drift.is_empty(), "v1: no fingerprint drift");
        assert!(scan.reference_drift.is_empty(), "v1: no reference drift");
        assert!(scan.audit.is_none(), "v1: no audit verdict");
    }
}
