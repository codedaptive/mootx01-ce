//! Per-container OR-reduction aggregates. Ports
//! `ContainerFingerprintStore.swift`.
//!
//! The per-container pruning aggregates of spec § 11.5: for each
//! container (wing, then room) the bitwise OR of every active drawer's
//! three bitmap fields. Recall filter ordering (§ 7.9.4 step 1) tests
//! these before any per-row scan, so a container whose OR lacks a bit
//! that the chain requires set holds no matching row and is pruned.
//!
//! ## Soundness
//!
//! Two properties of OR. First, the aggregate must cover every active
//! row, or a required bit living only in an omitted row would be
//! absent and the container falsely pruned; the Estate backfills on
//! open and ORs each capture in, so the aggregate always covers the
//! active set. Second, a bit left set after the only row carrying it
//! was withdrawn makes the aggregate an over-approximation, which is
//! harmless: extra set bits only forgo a prune, they never prune a
//! container that still holds a match. Bit-clearing mutations
//! therefore need no synchronous fix; a periodic rebuild tightens the
//! aggregate when it is worth doing.
//!
//! ## Swift-to-Rust shape change
//!
//! Swift `public actor ContainerFingerprintStore` becomes a sync
//! `struct` in Rust. The persistence-kit Rust trait surface is sync (per
//! LP-1B `drawer_store.rs`); backend serialization is the concrete
//! store's job, not this aggregate layer's. Methods return
//! `Result<T, LocusKitError>` directly. The Swift `Date` defaults on
//! mutating methods become explicit `i64` epoch-seconds arguments —
//! determinism rule: every computation passes `now` as a parameter,
//! never calls a clock from inside.

use crate::drawer::Drawer;
use crate::error::LocusKitError;
use crate::schema;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_lib::fingerprint256::Fingerprint256;
use substrate_lib::or_reduce;
use std::sync::Arc;
use persistence_kit::predicate::{OrderClause, OrderDirection, StoragePredicate};
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, StorageRow, TypedValue};
use std::collections::BTreeMap;

// MARK: - ContainerFingerprint

/// The OR of the three bitmap fields over some set of drawers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContainerFingerprint {
    pub adjective: i64,
    pub operational: i64,
    pub provenance: i64,
}

impl ContainerFingerprint {
    /// Zero element of the monoid — the identity for the OR merge.
    pub const ZERO: ContainerFingerprint = ContainerFingerprint {
        adjective: 0,
        operational: 0,
        provenance: 0,
    };

    pub fn new(adjective: i64, operational: i64, provenance: i64) -> Self {
        ContainerFingerprint { adjective, operational, provenance }
    }

    /// The OR of two container fingerprints, used to roll rooms up to
    /// a wing and to fold a new row in.
    ///
    /// M1/M5: routes the per-column bitwise OR through
    /// `substrate_lib::or_reduce` at canonical Fingerprint256 width.
    /// Each ContainerFingerprint packs as blocks 0 (adjective), 1
    /// (operational), 2 (provenance), block 3 reserved zero;
    /// or_reduce::reduce ORs the two carrier fingerprints; we unpack
    /// the three blocks back to i64 columns at the boundary. Bit-
    /// identical to the prior `self.X | other.X` implementation.
    pub fn merging(&self, other: ContainerFingerprint) -> ContainerFingerprint {
        let lhs = Fingerprint256::new(
            self.adjective as u64,
            self.operational as u64,
            self.provenance as u64,
            0,
        );
        let rhs = Fingerprint256::new(
            other.adjective as u64,
            other.operational as u64,
            other.provenance as u64,
            0,
        );
        let merged = or_reduce::reduce([lhs, rhs]);
        ContainerFingerprint {
            adjective: merged.block0 as i64,
            operational: merged.block1 as i64,
            provenance: merged.block2 as i64,
        }
    }
}

// MARK: - ContainerFingerprintStore

const TABLE: &str = "container_fingerprints";

/// One entry as enumerated by `room_level_entries`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoomLevelEntry {
    pub wing: String,
    pub room: String,
    pub fingerprint: ContainerFingerprint,
}

/// The aggregate store. Holds an `Arc<dyn Storage>` and reads / writes
/// rows in the `container_fingerprints` table.
pub struct ContainerFingerprintStore {
    storage: Arc<dyn Storage>,
}

impl ContainerFingerprintStore {
    /// The room-key used for a wing-level roll-up row, matching the
    /// node_bundles convention.
    pub const WING_ROLLUP_ROOM: &'static str = "";

    /// Open the store over a `Storage` handle. The handle is expected
    /// to be already opened by the caller (typically the Estate that
    /// owns it). For convenience this constructor calls `open` against
    /// the LocusKit schema, matching the Swift initializer's
    /// `try await storage.open(schema: LocusKitSchema.schema)` line.
    /// The Swift signature is `async throws`; the Rust port returns
    /// directly because the trait surface is sync.
    pub fn new(storage: Arc<dyn Storage>) -> Result<Self, LocusKitError> {
        storage
            .open(&schema::schema())
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        Ok(ContainerFingerprintStore { storage })
    }

    // -----------------------------------------------------------------
    // Read
    // -----------------------------------------------------------------

    /// The OR fingerprint for a container, or `None` if it has none
    /// yet. A `None` result means the caller must scan: an absent
    /// aggregate is not an empty one, and pruning against it would be
    /// unsound.
    pub fn get(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Option<ContainerFingerprint>, LocusKitError> {
        let row_store = self.storage.row_store();
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Eq(Column::new(TABLE, "wing"), TypedValue::Text(wing.to_string())),
            StoragePredicate::Eq(Column::new(TABLE, "room"), TypedValue::Text(room.to_string())),
        ]);
        let rows = row_store
            .query(TABLE, Some(&predicate), &[], Some(1), None)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        Ok(rows.first().map(fingerprint_from_row))
    }

    /// Every room-level container (room non-empty) with its OR
    /// fingerprint. Recall enumerates these to decide which containers
    /// to scan. The maintenance contract — backfill on open plus an
    /// OR-in per capture — keeps this set covering every active
    /// container, so enumerating it never misses a container that
    /// holds a match.
    pub fn room_level_entries(&self) -> Result<Vec<RoomLevelEntry>, LocusKitError> {
        let row_store = self.storage.row_store();
        let predicate = StoragePredicate::Not(Box::new(StoragePredicate::Eq(
            Column::new(TABLE, "room"),
            TypedValue::Text(Self::WING_ROLLUP_ROOM.to_string()),
        )));
        let order = [OrderClause::new(
            Column::new(TABLE, "wing"),
            OrderDirection::Ascending,
        )];
        let rows = row_store
            .query(TABLE, Some(&predicate), &order, None, None)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        Ok(rows
            .iter()
            .map(|row| RoomLevelEntry {
                wing: string_value_of(row.get("wing")),
                room: string_value_of(row.get("room")),
                fingerprint: fingerprint_from_row(row),
            })
            .collect())
    }

    // -----------------------------------------------------------------
    // Incremental maintenance
    // -----------------------------------------------------------------

    /// OR one drawer's bitmaps into its room-level and wing-level rows.
    /// Called on every capture.
    pub fn or_in(
        &self,
        wing: &str,
        room: &str,
        adjective: i64,
        operational: i64,
        provenance: i64,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let delta = ContainerFingerprint::new(adjective, operational, provenance);
        self.or_into(wing, room, delta, now)?;
        self.or_into(wing, Self::WING_ROLLUP_ROOM, delta, now)
    }

    fn or_into(
        &self,
        wing: &str,
        room: &str,
        delta: ContainerFingerprint,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let current = self.get(wing, room)?.unwrap_or(ContainerFingerprint::ZERO);
        let merged = current.merging(delta);
        self.put(wing, room, merged, now)
    }

    // -----------------------------------------------------------------
    // Rebuild (tightening after bit-clearing mutations)
    // -----------------------------------------------------------------

    /// Recompute a room's OR from its active drawers and replace the
    /// stored row. Use after withdrawals or expunges, or to backfill.
    pub fn rebuild_room(
        &self,
        wing: &str,
        room: &str,
        active_drawers: &[Drawer],
        now: i64,
    ) -> Result<ContainerFingerprint, LocusKitError> {
        let mut acc = ContainerFingerprint::ZERO;
        for d in active_drawers {
            acc = acc.merging(ContainerFingerprint::new(
                d.adjective_bitmap,
                d.operational_bitmap,
                d.provenance,
            ));
        }
        self.put(wing, room, acc, now)?;
        Ok(acc)
    }

    /// Recompute a wing-level row as the OR of its room-level rows.
    pub fn roll_up_wing(
        &self,
        wing: &str,
        now: i64,
    ) -> Result<ContainerFingerprint, LocusKitError> {
        let row_store = self.storage.row_store();
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Eq(Column::new(TABLE, "wing"), TypedValue::Text(wing.to_string())),
            StoragePredicate::Not(Box::new(StoragePredicate::Eq(
                Column::new(TABLE, "room"),
                TypedValue::Text(Self::WING_ROLLUP_ROOM.to_string()),
            ))),
        ]);
        let rows = row_store
            .query(TABLE, Some(&predicate), &[], None, None)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        let mut acc = ContainerFingerprint::ZERO;
        for row in &rows {
            acc = acc.merging(fingerprint_from_row(row));
        }
        self.put(wing, Self::WING_ROLLUP_ROOM, acc, now)?;
        Ok(acc)
    }

    /// Rebuild every container from the full active drawer set, so the
    /// aggregate covers all active rows. Called on open to make an
    /// existing estate's aggregate complete and therefore sound.
    pub fn rebuild_all(
        &self,
        active_drawers: &[Drawer],
        now: i64,
    ) -> Result<(), LocusKitError> {
        // Group by (wing, room).
        let mut by_container: BTreeMap<String, BTreeMap<String, Vec<&Drawer>>> = BTreeMap::new();
        for d in active_drawers {
            by_container
                .entry(d.wing.clone())
                .or_default()
                .entry(d.room.clone())
                .or_default()
                .push(d);
        }
        for (wing, rooms) in &by_container {
            for (room, drawers) in rooms {
                // Collect owned drawers for rebuild_room's slice argument.
                let owned: Vec<Drawer> = drawers.iter().map(|d| (*d).clone()).collect();
                self.rebuild_room(wing, room, &owned, now)?;
            }
            self.roll_up_wing(wing, now)?;
        }
        Ok(())
    }

    // -----------------------------------------------------------------
    // Write
    // -----------------------------------------------------------------

    fn put(
        &self,
        wing: &str,
        room: &str,
        fp: ContainerFingerprint,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let row_store = self.storage.row_store();
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("wing".to_string(), TypedValue::Text(wing.to_string()));
        values.insert("room".to_string(), TypedValue::Text(room.to_string()));
        values.insert("adjectiveOR".to_string(), TypedValue::Bitmap(fp.adjective));
        values.insert(
            "operationalOR".to_string(),
            TypedValue::Bitmap(fp.operational),
        );
        values.insert("provenanceOR".to_string(), TypedValue::Bitmap(fp.provenance));
        values.insert("updatedAt".to_string(), TypedValue::Timestamp(now));
        row_store
            .upsert(
                TABLE,
                values,
                &["wing".to_string(), "room".to_string()],
            )
            .map(|_| ())
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))
    }
}

// MARK: - Row decoding helpers

fn fingerprint_from_row(row: &StorageRow) -> ContainerFingerprint {
    ContainerFingerprint {
        adjective: i64_value_of(row.get("adjectiveOR")),
        operational: i64_value_of(row.get("operationalOR")),
        provenance: i64_value_of(row.get("provenanceOR")),
    }
}

fn i64_value_of(v: Option<&TypedValue>) -> i64 {
    match v {
        Some(TypedValue::Bitmap(i)) => *i,
        Some(TypedValue::Int(i)) => *i,
        _ => 0,
    }
}

fn string_value_of(v: Option<&TypedValue>) -> String {
    match v {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => String::new(),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use persistence_kit::inmemory::InMemoryStorage;
    use uuid::Uuid;

    fn open_store() -> ContainerFingerprintStore {
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        ContainerFingerprintStore::new(storage).unwrap()
    }

    fn drawer_with(wing: &str, room: &str, adj: i64, op: i64, prov: i64) -> Drawer {
        let mut d = Drawer::new("d", "c", wing, room, "alice", 0, "test-v1");
        d.adjective_bitmap = adj;
        d.operational_bitmap = op;
        d.provenance = prov;
        d
    }

    // --- ContainerFingerprint algebra ---

    #[test]
    fn merging_is_componentwise_or() {
        let a = ContainerFingerprint::new(0b0001, 0b0010, 0b0100);
        let b = ContainerFingerprint::new(0b1000, 0b1000, 0b1000);
        let m = a.merging(b);
        assert_eq!(m.adjective, 0b1001);
        assert_eq!(m.operational, 0b1010);
        assert_eq!(m.provenance, 0b1100);
    }

    #[test]
    fn zero_is_identity_for_merge() {
        let a = ContainerFingerprint::new(0xFF, 0xAB, 0x42);
        assert_eq!(a.merging(ContainerFingerprint::ZERO), a);
        assert_eq!(ContainerFingerprint::ZERO.merging(a), a);
    }

    // --- get / or_in maintenance ---

    #[test]
    fn get_on_unknown_container_returns_none() {
        let store = open_store();
        assert_eq!(store.get("study", "notes").unwrap(), None);
    }

    #[test]
    fn or_in_creates_room_and_wing_rollup_rows() {
        let store = open_store();
        store
            .or_in("study", "notes", 0b001, 0b010, 0b100, 100)
            .unwrap();

        let room_fp = store.get("study", "notes").unwrap().unwrap();
        assert_eq!(room_fp.adjective, 0b001);
        assert_eq!(room_fp.operational, 0b010);
        assert_eq!(room_fp.provenance, 0b100);

        let wing_fp = store.get("study", "").unwrap().unwrap();
        // Wing-rollup row carries the same OR after a single or_in.
        assert_eq!(wing_fp, room_fp);
    }

    #[test]
    fn or_in_is_monotone_over_repeated_calls() {
        let store = open_store();
        store.or_in("w", "r", 0b001, 0, 0, 1).unwrap();
        store.or_in("w", "r", 0b010, 0, 0, 2).unwrap();
        store.or_in("w", "r", 0b100, 0, 0, 3).unwrap();
        let fp = store.get("w", "r").unwrap().unwrap();
        assert_eq!(fp.adjective, 0b111);
    }

    // --- room_level_entries excludes the wing-rollup row ---

    #[test]
    fn room_level_entries_excludes_rollup_rows() {
        let store = open_store();
        store.or_in("w1", "rA", 0b001, 0, 0, 1).unwrap();
        store.or_in("w1", "rB", 0b010, 0, 0, 2).unwrap();
        store.or_in("w2", "rC", 0b100, 0, 0, 3).unwrap();

        let entries = store.room_level_entries().unwrap();
        assert_eq!(entries.len(), 3);
        // None of the returned entries are the rollup row (room == "").
        for e in &entries {
            assert_ne!(e.room, ContainerFingerprintStore::WING_ROLLUP_ROOM);
        }
        // Sorted by wing ascending: w1, w1, w2.
        assert_eq!(entries[0].wing, "w1");
        assert_eq!(entries[1].wing, "w1");
        assert_eq!(entries[2].wing, "w2");
    }

    // --- rebuild_room tightens after bit-clearing ---

    #[test]
    fn rebuild_room_replaces_with_active_set_or() {
        let store = open_store();
        // Pretend the aggregate has stale bits.
        store.or_in("w", "r", 0xFF, 0xFF, 0xFF, 1).unwrap();
        // Now the actual active set carries only 0b0001 in adjective.
        let actives = [drawer_with("w", "r", 0b0001, 0, 0)];
        let acc = store.rebuild_room("w", "r", &actives, 2).unwrap();
        assert_eq!(acc.adjective, 0b0001);
        assert_eq!(acc.operational, 0);
        assert_eq!(acc.provenance, 0);
        // The stored row matches the recomputed value.
        let stored = store.get("w", "r").unwrap().unwrap();
        assert_eq!(stored, acc);
    }

    // --- roll_up_wing reconstructs the wing OR ---

    #[test]
    fn roll_up_wing_ors_room_level_rows() {
        let store = open_store();
        store.or_in("w", "rA", 0b0001, 0, 0, 1).unwrap();
        store.or_in("w", "rB", 0b0010, 0, 0, 2).unwrap();
        // Corrupt the wing-rollup row deliberately to verify roll_up_wing
        // recomputes it from the room-level rows.
        store.or_in("w", "", 0xF0, 0, 0, 3).unwrap();
        let rollup = store.roll_up_wing("w", 4).unwrap();
        assert_eq!(rollup.adjective, 0b0011);
        assert_eq!(rollup.operational, 0);
        assert_eq!(rollup.provenance, 0);
    }

    // --- rebuild_all covers every container ---

    #[test]
    fn rebuild_all_covers_every_container_and_rolls_up_wings() {
        let store = open_store();
        let actives = vec![
            drawer_with("w1", "rA", 0b0001, 0, 0),
            drawer_with("w1", "rB", 0b0010, 0, 0),
            drawer_with("w2", "rC", 0b0100, 0, 0),
        ];
        store.rebuild_all(&actives, 10).unwrap();

        // Each room-level row carries the OR of its drawers.
        assert_eq!(
            store.get("w1", "rA").unwrap().unwrap().adjective,
            0b0001
        );
        assert_eq!(
            store.get("w1", "rB").unwrap().unwrap().adjective,
            0b0010
        );
        assert_eq!(
            store.get("w2", "rC").unwrap().unwrap().adjective,
            0b0100
        );
        // Wing rollups OR the room-level rows.
        assert_eq!(store.get("w1", "").unwrap().unwrap().adjective, 0b0011);
        assert_eq!(store.get("w2", "").unwrap().unwrap().adjective, 0b0100);
    }
}
