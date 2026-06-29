//! Bundle materializer. Ports `BundleMaterializer.swift`.
//!
//! Recomputes the bundle-algebra count-vector aggregates from drawers.
//! This is the first real caller of `count_fold_256` and the consumer
//! side of the drawer-to-fingerprint derivation. It materializes
//! Bundle A, the active centroid, per room and rolls it up to the
//! wing.
//!
//! Bundle A cannot be maintained incrementally — active membership
//! changes and the fold does not subtract — so it is recomputed:
//! gather the active drawers under a node, derive their fingerprints,
//! and fold them into a count-vector. The per-row fingerprints are
//! computed on demand here and discarded; only the aggregate is
//! stored. In the running system this recompute is a Dreaming tick
//! (temporal compression / cognition bundle export); the materializer
//! is the operation that tick invokes.
//!
//! ## Swift-to-Rust shape changes
//!
//! - Swift `materializeRoom(wing:room:now:)` reaches into
//!   `DrawerStore.drawersIn(wing:room:)` to fetch the active set. The
//!   Rust `DrawerStore` trait carries `drawers_in_wing` and
//!   `drawers_in_wing_room` on all concrete stores (`InMemoryDrawerStore`,
//!   `SqliteDrawerStore`, `PostgresDrawerStore`). The Rust signature
//!   accepts the active drawer slice directly so callers compose
//!   `materialize_room(wing, room, &store.drawers_in_wing_room(wing, room)?, now)`.
//! - Swift's default kernel `PortableKernel.kernelForCurrentPlatform()`
//!   is replaced by `substrate_kernel::kernel::ScalarKernel` — the
//!   scalar reference is the cross-leg bit-identity baseline; SIMD
//!   backends compose against the same `SubstrateKernel` trait so a
//!   caller wanting acceleration substitutes a different kernel
//!   value.
//! - The Swift `@discardableResult` annotation has no Rust equivalent;
//!   callers ignore the return with `let _ = …` when the side-effect
//!   alone is wanted.

use crate::drawer::Drawer;
use crate::drawer_fingerprint::EstateFingerprintFamilies;
use crate::error::LocusKitError;
use crate::node_bundle_store::{BundleKind, NodeBundleStore};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_kernel::kernel::SubstrateKernel;
use substrate_types::count_vector::CountVector256;

/// Recomputes Bundle A from a node's active drawer set.
///
/// Borrowed dependencies (the bundle store and the fingerprint
/// families) live in the caller's context; the materializer holds
/// references so a Dreaming tick can construct a fresh materializer
/// per pass without ownership churn. The kernel is held by value so
/// callers can swap in a SIMD backend without rebuilding the
/// materializer.
pub struct BundleMaterializer<'a, K: SubstrateKernel> {
    bundles: &'a NodeBundleStore,
    families: &'a EstateFingerprintFamilies,
    kernel: K,
}

impl<'a, K: SubstrateKernel> BundleMaterializer<'a, K> {
    /// Build a materializer over an existing bundle store and the
    /// estate's hyperplane families.
    pub fn new(
        bundles: &'a NodeBundleStore,
        families: &'a EstateFingerprintFamilies,
        kernel: K,
    ) -> Self {
        BundleMaterializer {
            bundles,
            families,
            kernel,
        }
    }

    /// Recompute Bundle A for one room: fold the supplied active
    /// drawer set into a count-vector and store it. Returns the
    /// resulting count-vector so callers can pipe it forward (e.g.
    /// into a roll-up) without a round-trip read.
    ///
    /// Bundle A is the "active centroid" per cookbook §11.5: a fold
    /// over the room's Cluster A drawers (Active, Pending, Contested,
    /// Accepted). Callers MUST filter to `State::is_cluster_a` before
    /// passing `active_drawers` — the fetch returns ALL non-tombstoned
    /// rows including Superseded/Withdrawn/Decayed/Expired/Rejected,
    /// and feeding those into Bundle A folds the wrong population into
    /// the active centroid. The Swift mirror (`BundleMaterializer.
    /// materializeRoom`) applies this filter internally for caller
    /// convenience; the Rust API pushes the responsibility outward.
    pub fn materialize_room(
        &self,
        wing: &str,
        room: &str,
        active_drawers: &[&Drawer],
        now: i64,
    ) -> Result<CountVector256, LocusKitError> {
        let fingerprints: Vec<_> = active_drawers
            .iter()
            .map(|d| self.families.fingerprint(d))
            .collect();
        let cv = self.kernel.count_fold_256(&fingerprints);
        self.bundles
            .put(wing, room, BundleKind::ActiveA, &cv, now)?;
        Ok(cv)
    }

    /// Roll Bundle A up to the wing by merging its already-
    /// materialized room bundles. By the count-vector's associativity
    /// this equals the direct fold of every active drawer in the wing,
    /// so callers may materialize rooms in any order and roll up
    /// afterward. Returns the wing-level count-vector.
    pub fn roll_up_wing(&self, wing: &str, now: i64) -> Result<CountVector256, LocusKitError> {
        let rooms = self.bundles.rooms(wing, BundleKind::ActiveA)?;
        let mut acc = CountVector256::zero();
        for entry in &rooms {
            acc.merge(&entry.bundle);
        }
        self.bundles.put(
            wing,
            NodeBundleStore::WING_ROLLUP_ROOM,
            BundleKind::ActiveA,
            &acc,
            now,
        )?;
        Ok(acc)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::drawer::Drawer;
    use persistence_kit::inmemory::InMemoryStorage;
    use std::sync::Arc;
    use substrate_kernel::kernel::ScalarKernel;
    use uuid::Uuid;

    fn drawer_at(id: &str, wing: &str, room: &str) -> Drawer {
        // The fingerprint derivation reads adjective / operational /
        // provenance / udc / wikidata_qid / lineage_id; each drawer has
        // a distinct id and `Drawer::new` assigns a fresh random
        // lineage_id, so each test drawer gets a distinct fingerprint.
        let mut d = Drawer::new(id, "content", "test-parent", "alice", 0, "test-v1");
        // ADR-017: wing/room are resolved from node tree, not stored on Drawer.
        // The bundle materializer tests only need distinct drawers with different
        // parent_node_ids; the actual wing/room names are irrelevant here.
        d.parent_node_id = format!("node-{}-{}", wing, room);
        d
    }

    fn make_materializer<'a>(
        bundles: &'a NodeBundleStore,
        families: &'a EstateFingerprintFamilies,
    ) -> BundleMaterializer<'a, ScalarKernel> {
        BundleMaterializer::new(bundles, families, ScalarKernel::new())
    }

    #[test]
    fn materialize_room_folds_active_drawers_into_count_vector() {
        let estate_uuid = Uuid::new_v4();
        let storage = Arc::new(InMemoryStorage::with_estate(estate_uuid));
        let bundles = NodeBundleStore::new(storage).unwrap();
        let families = EstateFingerprintFamilies::new(estate_uuid.to_string());
        let m = make_materializer(&bundles, &families);

        let d1 = drawer_at("d1", "w", "r");
        let d2 = drawer_at("d2", "w", "r");
        let active = [&d1, &d2];

        let cv = m.materialize_room("w", "r", &active, 100).unwrap();
        assert_eq!(cv.n(), 2);

        // The fold equals the direct kernel application; the stored
        // row equals the returned count-vector.
        let kernel = ScalarKernel::new();
        let fps: Vec<_> = active.iter().map(|d| families.fingerprint(d)).collect();
        let direct = kernel.count_fold_256(&fps);
        assert_eq!(cv, direct);

        let stored = bundles.get("w", "r", BundleKind::ActiveA).unwrap().unwrap();
        assert_eq!(stored, cv);
    }

    #[test]
    fn materialize_room_with_empty_set_writes_zero_vector() {
        let estate_uuid = Uuid::new_v4();
        let storage = Arc::new(InMemoryStorage::with_estate(estate_uuid));
        let bundles = NodeBundleStore::new(storage).unwrap();
        let families = EstateFingerprintFamilies::new(estate_uuid.to_string());
        let m = make_materializer(&bundles, &families);

        let cv = m.materialize_room("w", "r", &[], 10).unwrap();
        assert_eq!(cv.n(), 0);
        assert_eq!(cv, CountVector256::zero());

        let stored = bundles.get("w", "r", BundleKind::ActiveA).unwrap().unwrap();
        assert_eq!(stored, CountVector256::zero());
    }

    #[test]
    fn roll_up_wing_merges_room_bundles_by_associativity() {
        let estate_uuid = Uuid::new_v4();
        let storage = Arc::new(InMemoryStorage::with_estate(estate_uuid));
        let bundles = NodeBundleStore::new(storage).unwrap();
        let families = EstateFingerprintFamilies::new(estate_uuid.to_string());
        let m = make_materializer(&bundles, &families);

        let d1 = drawer_at("d1", "w", "rA");
        let d2 = drawer_at("d2", "w", "rB");
        let d3 = drawer_at("d3", "w", "rB");
        m.materialize_room("w", "rA", &[&d1], 1).unwrap();
        m.materialize_room("w", "rB", &[&d2, &d3], 2).unwrap();
        let rollup = m.roll_up_wing("w", 3).unwrap();

        // Rolling up equals the direct fold of every active drawer in
        // the wing (count-vector associativity).
        let kernel = ScalarKernel::new();
        let all_fps: Vec<_> = [&d1, &d2, &d3]
            .iter()
            .map(|d| families.fingerprint(d))
            .collect();
        let direct = kernel.count_fold_256(&all_fps);
        assert_eq!(rollup, direct);
        assert_eq!(rollup.n(), 3);

        // The roll-up is stored under the wing-rollup room key.
        let stored = bundles
            .get("w", NodeBundleStore::WING_ROLLUP_ROOM, BundleKind::ActiveA)
            .unwrap()
            .unwrap();
        assert_eq!(stored, rollup);
    }

    #[test]
    fn roll_up_wing_with_no_rooms_is_zero_vector() {
        let estate_uuid = Uuid::new_v4();
        let storage = Arc::new(InMemoryStorage::with_estate(estate_uuid));
        let bundles = NodeBundleStore::new(storage).unwrap();
        let families = EstateFingerprintFamilies::new(estate_uuid.to_string());
        let m = make_materializer(&bundles, &families);

        let cv = m.roll_up_wing("w-empty", 1).unwrap();
        assert_eq!(cv, CountVector256::zero());
    }

    #[test]
    fn materialize_room_is_last_write_wins() {
        let estate_uuid = Uuid::new_v4();
        let storage = Arc::new(InMemoryStorage::with_estate(estate_uuid));
        let bundles = NodeBundleStore::new(storage).unwrap();
        let families = EstateFingerprintFamilies::new(estate_uuid.to_string());
        let m = make_materializer(&bundles, &families);

        let d1 = drawer_at("d1", "w", "r");
        let d2 = drawer_at("d2", "w", "r");
        // First write: two drawers.
        let _ = m.materialize_room("w", "r", &[&d1, &d2], 1).unwrap();
        // Second write: one drawer (membership shrunk).
        let cv2 = m.materialize_room("w", "r", &[&d1], 2).unwrap();

        assert_eq!(cv2.n(), 1);
        let stored = bundles.get("w", "r", BundleKind::ActiveA).unwrap().unwrap();
        assert_eq!(stored, cv2);
    }
}
