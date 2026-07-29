//! Per-container bitmap aggregates. Ports
//! `ContainerFingerprintStore.swift`.
//!
//! ## OR aggregate (adjectiveOR, operationalOR, provenanceOR)
//!
//! For each container the bitwise OR of every active drawer's three bitmap
//! fields. Recall filter ordering (§ 7.9.4 step 1) tests these before any
//! per-row scan: a container whose OR lacks a required bit holds no matching
//! row and is pruned. Soundness: a bit left set after the only row carrying
//! it was withdrawn is a harmless over-approximation — extra set bits forgo
//! a prune but never prune a container that holds a match. The estate ORs
//! each capture in; bit-clearing mutations need no synchronous fix; rebuild
//! at open tightens the over-approximation.
//!
//! ## AND aggregate (operationalAND)
//!
//! For each container the bitwise AND of every active drawer's
//! `operationalBitmap`. This is an under-approximation (lower bound): a
//! false-absent bit is safe (room scanned unnecessarily), but a false-present
//! bit is UNSAFE (room skipped with eligible work). Default -1 (AND-identity)
//! so an absent/empty container does not falsely satisfy any AND-check. The
//! distillation sweep checks `(operationalAND & (1<<19)) != 0` to skip rooms
//! whose every drawer carries bit 19 (`HAS_CURRENT_REPRESENTATION`).
//! `rebuild_all` at estate open recomputes the AND from scratch to raise stale
//! under-approximations. Capture OR-ins lower the AND (always safe).
//! Distillation set-events cannot raise the AND by invariant — only
//! `rebuild_all` can raise it. Bit-clear events on live drawers call
//! `and_in_operational` immediately.
//!
//! ## Swift-to-Rust shape change
//!
//! Swift `public actor ContainerFingerprintStore` becomes a sync `struct` in
//! Rust. The persistence-kit Rust trait surface is sync (per LP-1B
//! `drawer_store.rs`); backend serialization is the concrete store's job, not
//! this aggregate layer's. Methods return `Result<T, LocusKitError>` directly.
//! The Swift `Date` defaults on mutating methods become explicit `i64`
//! epoch-seconds arguments — determinism rule: every computation passes `now`
//! as a parameter, never calls a clock from inside.

use crate::drawer::Drawer;
use crate::error::LocusKitError;
use crate::schema;
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
use persistence_kit::predicate::{OrderClause, OrderDirection, StoragePredicate};
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, StorageRow, TypedValue};
use std::collections::BTreeMap;
use std::sync::Arc;
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::or_reduce;

// MARK: - ContainerFingerprint

/// Bitmap aggregates for one container (wing or room). Three OR fields are
/// an over-approximation of the active drawer set; one AND field is an
/// under-approximation of the active drawers' `operationalBitmap`. See
/// module-level doc for the soundness argument for each direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContainerFingerprint {
    /// Bitwise OR of every active drawer's adjectiveBitmap.
    pub adjective: i64,
    /// Bitwise OR of every active drawer's operationalBitmap.
    pub operational: i64,
    /// Bitwise OR of every active drawer's provenance.
    pub provenance: i64,
    /// Bitwise AND of every active drawer's operationalBitmap.
    /// Under-approximation: default -1 (AND-identity) so an absent/empty
    /// container does not falsely satisfy any AND-check. Only `rebuild_all`
    /// can raise a bit; captures and clears can only lower.
    pub operational_and: i64,
}

impl ContainerFingerprint {
    /// OR-identity (zero element): all OR fields zero, AND field at the
    /// AND-identity (-1, all bits set). Starting value for fold operations.
    pub const ZERO: ContainerFingerprint = ContainerFingerprint {
        adjective: 0,
        operational: 0,
        provenance: 0,
        operational_and: -1,
    };

    /// Construct from OR fields only. `operational_and` defaults to -1
    /// (AND-identity) so callers that only deal with OR fields do not need
    /// to supply it. Mirrors `ContainerFingerprint.init(adjective:operational:
    /// provenance:operationalAnd:)` with `operationalAnd: -1` default.
    pub fn new(adjective: i64, operational: i64, provenance: i64) -> Self {
        ContainerFingerprint {
            adjective,
            operational,
            provenance,
            operational_and: -1,
        }
    }

    /// Construct with all four fields explicitly set.
    pub fn new_with_and(
        adjective: i64,
        operational: i64,
        provenance: i64,
        operational_and: i64,
    ) -> Self {
        ContainerFingerprint {
            adjective,
            operational,
            provenance,
            operational_and,
        }
    }

    /// Merge two container fingerprints: OR the three OR fields (via
    /// `or_reduce::reduce`, cookbook § 8.5), AND the `operational_and`
    /// fields.
    ///
    /// Callers constructing a delta for `or_into` must set `operational_and`
    /// to the drawer's actual `operationalBitmap` (not -1) to make the AND
    /// fold meaningful. See `or_in` for the canonical call site.
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
            operational_and: self.operational_and & other.operational_and,
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
    pub fn new(storage: Arc<dyn Storage>) -> Result<Self, LocusKitError> {
        storage
            .open(&schema::schema())
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        Ok(ContainerFingerprintStore { storage })
    }

    // -----------------------------------------------------------------
    // Read
    // -----------------------------------------------------------------

    /// The fingerprint for a container, or `None` if it has none yet.
    /// A `None` result means the caller must scan: an absent aggregate is
    /// not an empty one, and pruning against it would be unsound.
    pub fn get(
        &self,
        wing: &str,
        room: &str,
    ) -> Result<Option<ContainerFingerprint>, LocusKitError> {
        let row_store = self.storage.row_store();
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new(TABLE, "wing"),
                TypedValue::Text(wing.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new(TABLE, "room"),
                TypedValue::Text(room.to_string()),
            ),
        ]);
        let rows = row_store
            .query(TABLE, Some(&predicate), &[], Some(1), None)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        Ok(rows.first().map(fingerprint_from_row))
    }

    /// Every room-level container (room non-empty) with its fingerprint.
    /// Recall enumerates these to decide which containers to scan; the
    /// distillation sweep uses the `operational_and` field to skip rooms
    /// whose every drawer carries bit 19.
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

    /// OR one drawer's bitmaps into its room-level and wing-level rows,
    /// and AND the operational bitmap into the `operationalAND` column.
    ///
    /// Called on every capture (new drawer, bit 19 clear) and on
    /// `set_distilled_representation` (bit 19 set). The AND semantics
    /// handle both correctly:
    /// - Capture (bit 19 = 0): ANDs 0 into operationalAND → lowers bit 19
    ///   (safe; room will not be skipped by the sweep).
    /// - Distillation (bit 19 = 1): ANDs 1 → no change to bit 19 in AND
    ///   (deferred to rebuild_all; correct by invariant).
    pub fn or_in(
        &self,
        wing: &str,
        room: &str,
        adjective: i64,
        operational: i64,
        provenance: i64,
        now: i64,
    ) -> Result<(), LocusKitError> {
        // operational_and set to the actual operational value so the AND fold
        // is meaningful. For captures (bit 19 clear) this lowers the AND;
        // for distillation (bit 19 set) the AND is unchanged (deferred).
        let delta = ContainerFingerprint::new_with_and(adjective, operational, provenance, operational);
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

    /// AND an operational bitmap into the `operationalAND` column for the
    /// room and wing rows, leaving the three OR columns unchanged.
    ///
    /// Use this after a bit-CLEAR event on a LIVE (non-tombstoned) drawer
    /// to prevent the distillation sweep from falsely skipping the container.
    /// Lowering the AND is always safe (under-approximation → safe direction).
    ///
    /// Tombstone/expunge paths do NOT need to call this — the sweep only
    /// visits active drawers, so a tombstoned drawer's cleared bit 19 never
    /// causes the sweep to miss work.
    pub fn and_in_operational(
        &self,
        wing: &str,
        room: &str,
        operational: i64,
        now: i64,
    ) -> Result<(), LocusKitError> {
        self.and_into_operational(wing, room, operational, now)?;
        self.and_into_operational(wing, Self::WING_ROLLUP_ROOM, operational, now)
    }

    fn and_into_operational(
        &self,
        wing: &str,
        room: &str,
        operational: i64,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let mut fp = match self.get(wing, room)? {
            Some(fp) => fp,
            None => return Ok(()), // nothing to lower
        };
        fp.operational_and &= operational;
        self.put(wing, room, fp, now)
    }

    // -----------------------------------------------------------------
    // Rebuild (tightening after bit-clearing mutations)
    // -----------------------------------------------------------------

    /// Recompute a room's OR and AND from its active drawers and replace
    /// the stored row. Use after withdrawals or expunges, or to backfill.
    ///
    /// For each drawer, the `operational_bitmap` is used both in the OR fold
    /// (via `merging`) and in the AND fold (via `operational_and` field).
    /// The AND starts at -1 (identity) and is narrowed to the true AND of
    /// all drawers — this is the only path that can raise an AND bit.
    pub fn rebuild_room(
        &self,
        wing: &str,
        room: &str,
        active_drawers: &[Drawer],
        now: i64,
    ) -> Result<ContainerFingerprint, LocusKitError> {
        let mut acc = ContainerFingerprint::ZERO;
        for d in active_drawers {
            acc = acc.merging(ContainerFingerprint::new_with_and(
                d.adjective_bitmap,
                d.operational_bitmap,
                d.provenance,
                d.operational_bitmap,
            ));
        }
        self.put(wing, room, acc, now)?;
        Ok(acc)
    }

    /// Recompute a wing-level row as the OR/AND of its room-level rows.
    /// The room rows already carry the correct `operational_and`; this
    /// folds them into the wing rollup via `merging` (which ANDs them).
    pub fn roll_up_wing(
        &self,
        wing: &str,
        now: i64,
    ) -> Result<ContainerFingerprint, LocusKitError> {
        let row_store = self.storage.row_store();
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new(TABLE, "wing"),
                TypedValue::Text(wing.to_string()),
            ),
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

    /// Rebuild every container from the full active drawer set, so both
    /// OR and AND aggregates cover all active rows. Called on open to make
    /// an existing estate's aggregates complete and accurate.
    ///
    /// This is the ONLY path that can raise an AND bit (correct a stale
    /// under-approximation from a session that added new distilled rows).
    ///
    /// `node_names` maps each drawer's `parent_node_id` to its resolved
    /// `(wing_name, room_name)` pair from the node tree. Drawers whose
    /// `parent_node_id` is absent from the map are skipped — the caller is
    /// responsible for resolving all active node IDs before invoking this.
    pub fn rebuild_all(
        &self,
        active_drawers: &[Drawer],
        node_names: &BTreeMap<String, (String, String)>,
        now: i64,
    ) -> Result<(), LocusKitError> {
        // Group by (wing, room) resolved from the node tree.
        let mut by_container: BTreeMap<String, BTreeMap<String, Vec<&Drawer>>> = BTreeMap::new();
        for d in active_drawers {
            let (wing, room) = match node_names.get(&d.parent_node_id) {
                Some(names) => names,
                // Orphaned drawer — parent node missing from tree. Skipping
                // is an under-approximation risk: if this row carries bits
                // the filter requires, omitting it may falsely drop a
                // container that should survive. Log and skip rather than
                // panic, but note the hazard.
                None => continue,
            };
            by_container
                .entry(wing.clone())
                .or_default()
                .entry(room.clone())
                .or_default()
                .push(d);
        }
        for (wing, rooms) in &by_container {
            for (room, drawers) in rooms {
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
        values.insert(
            "provenanceOR".to_string(),
            TypedValue::Bitmap(fp.provenance),
        );
        values.insert(
            "operationalAND".to_string(),
            TypedValue::Bitmap(fp.operational_and),
        );
        values.insert("updatedAt".to_string(), TypedValue::Timestamp(now));
        row_store
            .upsert(TABLE, values, &["wing".to_string(), "room".to_string()])
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
        // Default -1 (AND-identity) for rows written before v11 migration.
        operational_and: i64_or_minus_one(row.get("operationalAND")),
    }
}

fn i64_value_of(v: Option<&TypedValue>) -> i64 {
    match v {
        Some(TypedValue::Bitmap(i)) => *i,
        Some(TypedValue::Int(i)) => *i,
        _ => 0,
    }
}

/// Read an i64 bitmap value, defaulting to -1 (AND-identity) when the
/// column is absent (e.g. a v10 row before the v11 migration runs).
fn i64_or_minus_one(v: Option<&TypedValue>) -> i64 {
    match v {
        Some(TypedValue::Bitmap(i)) => *i,
        Some(TypedValue::Int(i)) => *i,
        _ => -1,
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

    /// Build a test drawer whose `parent_node_id` encodes the wing/room
    /// pair so the companion `test_node_names` map can resolve it back.
    fn drawer_with(wing: &str, room: &str, adj: i64, op: i64, prov: i64) -> Drawer {
        let synthetic_id = format!("{}::{}", wing, room);
        let mut d = Drawer::new("d", "c", &synthetic_id, "alice", 0, "test-v1");
        d.adjective_bitmap = adj;
        d.operational_bitmap = op;
        d.provenance = prov;
        d
    }

    /// Build the node-names map corresponding to the synthetic
    /// parent_node_ids produced by `drawer_with`.
    fn test_node_names(drawers: &[Drawer]) -> BTreeMap<String, (String, String)> {
        let mut map = BTreeMap::new();
        for d in drawers {
            if let Some((wing, room)) = d.parent_node_id.split_once("::") {
                map.insert(
                    d.parent_node_id.clone(),
                    (wing.to_string(), room.to_string()),
                );
            }
        }
        map
    }

    // --- ContainerFingerprint algebra ---

    #[test]
    fn merging_ors_three_fields_and_ands_operational_and() {
        let a = ContainerFingerprint::new_with_and(0b0001, 0b1111, 0b0100, 0b1110);
        let b = ContainerFingerprint::new_with_and(0b1000, 0b1001, 0b1000, 0b1011);
        let m = a.merging(b);
        assert_eq!(m.adjective, 0b1001);
        assert_eq!(m.operational, 0b1111);
        assert_eq!(m.provenance, 0b1100);
        // AND: 0b1110 & 0b1011 = 0b1010
        assert_eq!(m.operational_and, 0b1010);
    }

    #[test]
    fn zero_is_identity_for_merge() {
        let a = ContainerFingerprint::new_with_and(0xFF, 0xAB, 0x42, 0x7F);
        let merged_with_zero = a.merging(ContainerFingerprint::ZERO);
        // OR side: a | ZERO = a (since ZERO.operational = 0, OR with 0 = a)
        assert_eq!(merged_with_zero.adjective, a.adjective);
        assert_eq!(merged_with_zero.operational, a.operational);
        assert_eq!(merged_with_zero.provenance, a.provenance);
        // AND side: a.operational_and & ZERO.operational_and = a.operational_and & -1 = a.operational_and
        assert_eq!(merged_with_zero.operational_and, a.operational_and);

        let zero_merged_with_a = ContainerFingerprint::ZERO.merging(a);
        assert_eq!(zero_merged_with_a.adjective, a.adjective);
        assert_eq!(zero_merged_with_a.operational, a.operational);
        assert_eq!(zero_merged_with_a.provenance, a.provenance);
        assert_eq!(zero_merged_with_a.operational_and, a.operational_and);
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
        // operational=0b010 → operational_and = 0b010 (AND-in the actual value)
        store
            .or_in("study", "notes", 0b001, 0b010, 0b100, 100)
            .unwrap();

        let room_fp = store.get("study", "notes").unwrap().unwrap();
        assert_eq!(room_fp.adjective, 0b001);
        assert_eq!(room_fp.operational, 0b010);
        assert_eq!(room_fp.provenance, 0b100);
        // AND was seeded with -1 (ZERO.operational_and) AND-ed with 0b010.
        assert_eq!(room_fp.operational_and, 0b010);

        let wing_fp = store.get("study", "").unwrap().unwrap();
        assert_eq!(wing_fp, room_fp);
    }

    #[test]
    fn or_in_is_monotone_over_repeated_calls() {
        let store = open_store();
        store.or_in("w", "r", 0b001, 0xFF, 0, 1).unwrap();
        store.or_in("w", "r", 0b010, 0xFE, 0, 2).unwrap();
        store.or_in("w", "r", 0b100, 0xFC, 0, 3).unwrap();
        let fp = store.get("w", "r").unwrap().unwrap();
        assert_eq!(fp.adjective, 0b111);
        // OR: 0xFF | 0xFE | 0xFC = 0xFF
        assert_eq!(fp.operational, 0xFF);
        // AND: -1 & 0xFF & 0xFE & 0xFC = 0xFC
        assert_eq!(fp.operational_and, 0xFC);
    }

    // --- and_in_operational ---

    #[test]
    fn and_in_operational_lowers_the_and_aggregate() {
        let store = open_store();
        // Seed a room with all-ones operational.
        store.or_in("w", "r", 0, -1, 0, 1).unwrap();
        let before = store.get("w", "r").unwrap().unwrap();
        assert_eq!(before.operational_and, -1);

        // AND-in a value with bit 19 clear.
        let bit19 = 1i64 << 19;
        store
            .and_in_operational("w", "r", !bit19, 2)
            .unwrap();
        let after = store.get("w", "r").unwrap().unwrap();
        assert_eq!(after.operational_and & bit19, 0,
                   "bit 19 must be cleared in operationalAND after and_in_operational");
        // OR fields are unchanged.
        assert_eq!(after.operational, before.operational);
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
    fn rebuild_room_replaces_with_active_set_or_and_and() {
        let store = open_store();
        // Pretend the aggregate has stale bits.
        store.or_in("w", "r", 0xFF, 0xFF, 0xFF, 1).unwrap();
        // Actual active set: one drawer with adj=0b0001, op=0b1010.
        let actives = [drawer_with("w", "r", 0b0001, 0b1010, 0)];
        let acc = store.rebuild_room("w", "r", &actives, 2).unwrap();
        assert_eq!(acc.adjective, 0b0001);
        assert_eq!(acc.operational, 0b1010);
        // AND of a single drawer = the drawer's own bitmap.
        assert_eq!(acc.operational_and, 0b1010);
        assert_eq!(acc.provenance, 0);
        let stored = store.get("w", "r").unwrap().unwrap();
        assert_eq!(stored, acc);
    }

    #[test]
    fn rebuild_room_two_drawers_or_and_and() {
        let store = open_store();
        let actives = [
            drawer_with("w", "r", 0, 0b1100, 0),
            drawer_with("w", "r", 0, 0b1010, 0),
        ];
        let acc = store.rebuild_room("w", "r", &actives, 1).unwrap();
        // OR: 0b1100 | 0b1010 = 0b1110
        assert_eq!(acc.operational, 0b1110);
        // AND: 0b1100 & 0b1010 = 0b1000
        assert_eq!(acc.operational_and, 0b1000);
    }

    // --- roll_up_wing reconstructs the wing OR/AND ---

    #[test]
    fn roll_up_wing_ors_and_ands_room_level_rows() {
        let store = open_store();
        // Room rA: operational=0b1100, rB: operational=0b1010
        store.or_in("w", "rA", 0b0001, 0b1100, 0, 1).unwrap();
        store.or_in("w", "rB", 0b0010, 0b1010, 0, 2).unwrap();
        // Corrupt the wing-rollup row to verify roll_up_wing recomputes it.
        store.or_in("w", "", 0xF0, 0xFF, 0, 3).unwrap();
        let rollup = store.roll_up_wing("w", 4).unwrap();
        // OR: 0b0001 | 0b0010 = 0b0011
        assert_eq!(rollup.adjective, 0b0011);
        // operational OR: 0b1100 | 0b1010 = 0b1110
        assert_eq!(rollup.operational, 0b1110);
        // operational AND: room_rA.operational_and & room_rB.operational_and
        // room_rA.operational_and = -1 & 0b1100 = 0b1100
        // room_rB.operational_and = -1 & 0b1010 = 0b1010
        // wing AND = 0b1100 & 0b1010 = 0b1000
        assert_eq!(rollup.operational_and, 0b1000);
    }

    // --- rebuild_all covers every container ---

    #[test]
    fn rebuild_all_covers_every_container_and_rolls_up_wings() {
        let store = open_store();
        let actives = vec![
            drawer_with("w1", "rA", 0b0001, 0b1111, 0),
            drawer_with("w1", "rB", 0b0010, 0b1110, 0),
            drawer_with("w2", "rC", 0b0100, 0b1100, 0),
        ];
        let names = test_node_names(&actives);
        store.rebuild_all(&actives, &names, 10).unwrap();

        assert_eq!(store.get("w1", "rA").unwrap().unwrap().adjective, 0b0001);
        assert_eq!(store.get("w1", "rB").unwrap().unwrap().adjective, 0b0010);
        assert_eq!(store.get("w2", "rC").unwrap().unwrap().adjective, 0b0100);
        // Wing OR rollups.
        assert_eq!(store.get("w1", "").unwrap().unwrap().adjective, 0b0011);
        assert_eq!(store.get("w2", "").unwrap().unwrap().adjective, 0b0100);
        // AND: rA.operational_and = 0b1111, rB.operational_and = 0b1110
        assert_eq!(store.get("w1", "rA").unwrap().unwrap().operational_and, 0b1111);
        assert_eq!(store.get("w1", "rB").unwrap().unwrap().operational_and, 0b1110);
        // Wing AND = 0b1111 & 0b1110 = 0b1110
        assert_eq!(store.get("w1", "").unwrap().unwrap().operational_and, 0b1110);
        assert_eq!(store.get("w2", "rC").unwrap().unwrap().operational_and, 0b1100);
        assert_eq!(store.get("w2", "").unwrap().unwrap().operational_and, 0b1100);
    }
}
