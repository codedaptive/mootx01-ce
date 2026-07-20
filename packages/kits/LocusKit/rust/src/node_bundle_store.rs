//! Per-node bundle-algebra count-vector store. Ports
//! `NodeBundleStore.swift`.
//!
//! Persistence for the bundle-algebra count-vector aggregates: one row
//! per (wing, room, bundleKind) in the `node_bundles` table. The
//! per-row drawer fingerprint is never stored; only these aggregates
//! are. The store
//! reads and writes the count-vector; the `BundleMaterializer` computes
//! it from the active drawer set.
//!
//! Bundle layout per spec § 11.6:
//!
//! - `BundleKind::ActiveA` (column value `"A"`) — the active centroid,
//!   the fold of the node's currently active members. Cannot be
//!   maintained incrementally because the count-vector fold does not
//!   subtract; recomputed wholesale.
//! - `BundleKind::DepartedB` (column value `"B"`) — the departed
//!   accumulator, eager-folded at departure time.
//!
//! ## Wire encoding
//!
//! `counts` is stored as a 1024-byte BLOB: 256 little-endian `u32`
//! values, exactly mirroring the Swift `encodeCounts` byte order. `n`
//! is stored in its own column so the BLOB layout is positional and
//! self-describing.
//!
//! ## Swift-to-Rust shape changes
//!
//! - Swift `public actor NodeBundleStore` → Rust sync `struct`. The
//!   persistence-kit Rust trait surface is sync; backend serialization is
//!   the concrete store's job. Matches the LP-1C
//!   `ContainerFingerprintStore` precedent.
//! - Swift `Date now` defaults → Rust `now: i64` epoch-seconds
//!   parameter, threading the deterministic-clock rule explicitly.
//! - Swift `precondition(data.count == 256 * 4, ...)` becomes a typed
//!   `LocusKitError::InvalidContent` so corrupt rows surface a clear
//!   validation error rather than panicking the substrate.

use crate::error::LocusKitError;
use crate::schema;
use persistence_kit::predicate::{OrderClause, OrderDirection, StoragePredicate};
use persistence_kit::storage::Storage;
use persistence_kit::types::{Column, StorageRow, TypedValue};
use std::collections::BTreeMap;
use std::sync::Arc;
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
use substrate_types::count_vector::CountVector256;

const TABLE: &str = "node_bundles";

/// Which bundle a row holds. `ActiveA` is the active centroid; the
/// active fold of currently-live members. `DepartedB` is the departed
/// accumulator, eager-folded at departure time. The string values map
/// to the SQLite `bundleKind` column verbatim (`"A"` / `"B"`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BundleKind {
    ActiveA,
    DepartedB,
}

impl BundleKind {
    /// SQLite column value for this kind. Mirrors the Swift `rawValue`
    /// for `BundleKind: String`.
    pub fn as_str(self) -> &'static str {
        match self {
            BundleKind::ActiveA => "A",
            BundleKind::DepartedB => "B",
        }
    }

    /// Parse the column value back into a `BundleKind`. Returns `None`
    /// for any other string so callers can surface the corrupt-row
    /// case rather than silently coercing.
    ///
    /// Named `from_str` by cross-leg convention (mirrors Swift `init(rawValue:)`).
    /// Returns `Option<BundleKind>` rather than `Result<_, _>`, so this
    /// does not implement `std::str::FromStr` (different return type).
    /// The `#[allow]` suppresses the lint that warns about the similar name.
    #[allow(clippy::should_implement_trait)]
    pub fn from_str(s: &str) -> Option<BundleKind> {
        match s {
            "A" => Some(BundleKind::ActiveA),
            "B" => Some(BundleKind::DepartedB),
            _ => None,
        }
    }
}

/// One (room, bundle) entry returned by [`NodeBundleStore::rooms`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoomBundle {
    pub room: String,
    pub bundle: CountVector256,
}

/// The per-node count-vector store.
pub struct NodeBundleStore {
    storage: Arc<dyn Storage>,
}

impl NodeBundleStore {
    /// The room-key used for a wing-level roll-up row. Matches the
    /// `ContainerFingerprintStore::WING_ROLLUP_ROOM` convention so
    /// `rooms()` can exclude it consistently.
    pub const WING_ROLLUP_ROOM: &'static str = "";

    /// Open the store over a `Storage` handle. The Swift initializer
    /// is `async throws` and calls `try await storage.open(schema:)`;
    /// the Rust port is sync. The `open` call is idempotent so sharing
    /// the underlying storage with other LocusKit stores is safe.
    pub fn new(storage: Arc<dyn Storage>) -> Result<Self, LocusKitError> {
        storage
            .open(&schema::schema())
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        Ok(NodeBundleStore { storage })
    }

    // -------------------------------------------------------------
    // Wire encoding
    // -------------------------------------------------------------

    /// Encode a count-vector's 256 counts as little-endian `u32`,
    /// exactly 1024 bytes. `n` is stored in its own column, not here.
    pub fn encode_counts(cv: &CountVector256) -> Vec<u8> {
        let mut out = Vec::with_capacity(256 * 4);
        for &c in cv.counts().iter() {
            out.extend_from_slice(&c.to_le_bytes());
        }
        out
    }

    /// Decode 1024 little-endian `u32` bytes plus the member count `n`
    /// back into a count-vector. Returns
    /// `LocusKitError::InvalidContent` on length mismatch; the Swift
    /// port traps with `precondition` here, but a typed error surfaces
    /// the corrupt-row case without panicking the substrate.
    pub fn decode_counts(data: &[u8], n: u32) -> Result<CountVector256, LocusKitError> {
        if data.len() != 256 * 4 {
            return Err(LocusKitError::InvalidContent(format!(
                "node_bundles counts blob must be exactly 1024 bytes, got {}",
                data.len()
            )));
        }
        let mut counts = [0u32; 256];
        for (j, slot) in counts.iter_mut().enumerate() {
            let off = j * 4;
            *slot = u32::from_le_bytes([data[off], data[off + 1], data[off + 2], data[off + 3]]);
        }
        Ok(CountVector256::from_parts(counts, n))
    }

    // -------------------------------------------------------------
    // Read and write
    // -------------------------------------------------------------

    /// Write (insert or replace) a node's bundle. Last write wins,
    /// which is correct for Bundle A recompute and Bundle B updates.
    pub fn put(
        &self,
        wing: &str,
        room: &str,
        kind: BundleKind,
        cv: &CountVector256,
        now: i64,
    ) -> Result<(), LocusKitError> {
        let row_store = self.storage.row_store();
        let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
        values.insert("wing".to_string(), TypedValue::Text(wing.to_string()));
        values.insert("room".to_string(), TypedValue::Text(room.to_string()));
        values.insert(
            "bundleKind".to_string(),
            TypedValue::Text(kind.as_str().to_string()),
        );
        values.insert("n".to_string(), TypedValue::Int(i64::from(cv.n())));
        values.insert(
            "counts".to_string(),
            TypedValue::Blob(Self::encode_counts(cv)),
        );
        values.insert("updatedAt".to_string(), TypedValue::Timestamp(now));
        row_store
            .upsert(
                TABLE,
                values,
                &[
                    "wing".to_string(),
                    "room".to_string(),
                    "bundleKind".to_string(),
                ],
            )
            .map(|_| ())
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))
    }

    /// Read a node's bundle, or `None` if it has not been materialized.
    pub fn get(
        &self,
        wing: &str,
        room: &str,
        kind: BundleKind,
    ) -> Result<Option<CountVector256>, LocusKitError> {
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
            StoragePredicate::Eq(
                Column::new(TABLE, "bundleKind"),
                TypedValue::Text(kind.as_str().to_string()),
            ),
        ]);
        let rows = row_store
            .query(TABLE, Some(&predicate), &[], Some(1), None)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        match rows.first() {
            None => Ok(None),
            Some(row) => Ok(Some(Self::bundle_from_row(row)?)),
        }
    }

    /// All room-level bundles of one kind under a wing, excluding the
    /// wing-level roll-up row (`room == ""`). Used by the wing
    /// roll-up. Returned ordered by `room` ascending, matching Swift's
    /// `OrderClause(... .ascending)`.
    pub fn rooms(&self, wing: &str, kind: BundleKind) -> Result<Vec<RoomBundle>, LocusKitError> {
        let row_store = self.storage.row_store();
        let predicate = StoragePredicate::all(vec![
            StoragePredicate::Eq(
                Column::new(TABLE, "wing"),
                TypedValue::Text(wing.to_string()),
            ),
            StoragePredicate::Eq(
                Column::new(TABLE, "bundleKind"),
                TypedValue::Text(kind.as_str().to_string()),
            ),
            StoragePredicate::Not(Box::new(StoragePredicate::Eq(
                Column::new(TABLE, "room"),
                TypedValue::Text(Self::WING_ROLLUP_ROOM.to_string()),
            ))),
        ]);
        let order = [OrderClause::new(
            Column::new(TABLE, "room"),
            OrderDirection::Ascending,
        )];
        let rows = row_store
            .query(TABLE, Some(&predicate), &order, None, None)
            .map_err(|e| LocusKitError::DatabaseUnavailable(e.to_string()))?;
        let mut out = Vec::with_capacity(rows.len());
        for row in &rows {
            out.push(RoomBundle {
                room: string_value_of(row.get("room")),
                bundle: Self::bundle_from_row(row)?,
            });
        }
        Ok(out)
    }

    // -------------------------------------------------------------
    // Row decoding
    // -------------------------------------------------------------

    fn bundle_from_row(row: &StorageRow) -> Result<CountVector256, LocusKitError> {
        let n_raw = i64_value_of(row.get("n"));
        // SQLite stores n as INTEGER → truncate to u32, matching
        // Swift's `UInt32(truncatingIfNeeded:)`.
        let n = n_raw as u32;
        let blob = blob_value_of(row.get("counts"));
        Self::decode_counts(&blob, n)
    }
}

// MARK: - TypedValue accessors

fn i64_value_of(v: Option<&TypedValue>) -> i64 {
    match v {
        Some(TypedValue::Int(i)) => *i,
        Some(TypedValue::Bitmap(i)) => *i,
        _ => 0,
    }
}

fn string_value_of(v: Option<&TypedValue>) -> String {
    match v {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => String::new(),
    }
}

fn blob_value_of(v: Option<&TypedValue>) -> Vec<u8> {
    match v {
        Some(TypedValue::Blob(b)) => b.clone(),
        _ => Vec::new(),
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

    fn open_store() -> NodeBundleStore {
        let storage = Arc::new(InMemoryStorage::with_estate(Uuid::new_v4()));
        NodeBundleStore::new(storage).unwrap()
    }

    fn cv_with(counts: &[(usize, u32)], n: u32) -> CountVector256 {
        let mut arr = [0u32; 256];
        for &(idx, c) in counts {
            arr[idx] = c;
        }
        CountVector256::from_parts(arr, n)
    }

    #[test]
    fn bundle_kind_round_trips_through_column_value() {
        assert_eq!(BundleKind::ActiveA.as_str(), "A");
        assert_eq!(BundleKind::DepartedB.as_str(), "B");
        assert_eq!(BundleKind::from_str("A"), Some(BundleKind::ActiveA));
        assert_eq!(BundleKind::from_str("B"), Some(BundleKind::DepartedB));
        assert_eq!(BundleKind::from_str("Z"), None);
    }

    #[test]
    fn encode_counts_is_exactly_1024_bytes_le() {
        let cv = cv_with(&[(0, 0x01020304)], 1);
        let bytes = NodeBundleStore::encode_counts(&cv);
        assert_eq!(bytes.len(), 256 * 4);
        // bit 0 → first four bytes little-endian
        assert_eq!(&bytes[0..4], &[0x04, 0x03, 0x02, 0x01]);
        // all other slots zero
        for j in 1..256 {
            assert_eq!(&bytes[j * 4..j * 4 + 4], &[0, 0, 0, 0]);
        }
    }

    #[test]
    fn decode_counts_round_trips_through_encode() {
        let cv = cv_with(&[(0, 1), (1, 2), (2, 3), (255, u32::MAX)], 17);
        let bytes = NodeBundleStore::encode_counts(&cv);
        let back = NodeBundleStore::decode_counts(&bytes, 17).unwrap();
        assert_eq!(back, cv);
    }

    #[test]
    fn decode_counts_rejects_short_blob() {
        let err = NodeBundleStore::decode_counts(&[0u8; 16], 0).unwrap_err();
        match err {
            LocusKitError::InvalidContent(msg) => assert!(msg.contains("1024")),
            other => panic!("unexpected error: {:?}", other),
        }
    }

    #[test]
    fn get_on_unknown_node_returns_none() {
        let s = open_store();
        assert_eq!(
            s.get("missing-wing", "missing-room", BundleKind::ActiveA)
                .unwrap(),
            None
        );
    }

    #[test]
    fn put_then_get_round_trips_the_count_vector() {
        let s = open_store();
        let cv = cv_with(&[(0, 5), (100, 7), (255, 11)], 13);
        s.put("w", "r", BundleKind::ActiveA, &cv, 100).unwrap();
        let back = s.get("w", "r", BundleKind::ActiveA).unwrap().unwrap();
        assert_eq!(back, cv);
    }

    #[test]
    fn put_is_last_write_wins() {
        let s = open_store();
        let cv1 = cv_with(&[(0, 1)], 1);
        let cv2 = cv_with(&[(0, 9), (1, 2)], 11);
        s.put("w", "r", BundleKind::ActiveA, &cv1, 1).unwrap();
        s.put("w", "r", BundleKind::ActiveA, &cv2, 2).unwrap();
        let back = s.get("w", "r", BundleKind::ActiveA).unwrap().unwrap();
        assert_eq!(back, cv2);
    }

    #[test]
    fn put_keys_on_bundle_kind() {
        let s = open_store();
        let cv_a = cv_with(&[(0, 1)], 1);
        let cv_b = cv_with(&[(1, 2)], 3);
        s.put("w", "r", BundleKind::ActiveA, &cv_a, 1).unwrap();
        s.put("w", "r", BundleKind::DepartedB, &cv_b, 2).unwrap();
        assert_eq!(s.get("w", "r", BundleKind::ActiveA).unwrap().unwrap(), cv_a);
        assert_eq!(
            s.get("w", "r", BundleKind::DepartedB).unwrap().unwrap(),
            cv_b
        );
    }

    #[test]
    fn rooms_excludes_wing_rollup_and_orders_by_room() {
        let s = open_store();
        s.put("w1", "rA", BundleKind::ActiveA, &cv_with(&[(0, 1)], 1), 1)
            .unwrap();
        s.put("w1", "rB", BundleKind::ActiveA, &cv_with(&[(1, 1)], 1), 2)
            .unwrap();
        // Wing-level roll-up row — must be excluded.
        s.put(
            "w1",
            NodeBundleStore::WING_ROLLUP_ROOM,
            BundleKind::ActiveA,
            &cv_with(&[(2, 1)], 1),
            3,
        )
        .unwrap();
        // Different wing — must be excluded.
        s.put("w2", "rC", BundleKind::ActiveA, &cv_with(&[(3, 1)], 1), 4)
            .unwrap();

        let rooms = s.rooms("w1", BundleKind::ActiveA).unwrap();
        assert_eq!(rooms.len(), 2);
        assert_eq!(rooms[0].room, "rA");
        assert_eq!(rooms[1].room, "rB");
    }

    #[test]
    fn rooms_filters_on_bundle_kind() {
        let s = open_store();
        s.put("w", "rA", BundleKind::ActiveA, &cv_with(&[(0, 1)], 1), 1)
            .unwrap();
        s.put("w", "rA", BundleKind::DepartedB, &cv_with(&[(1, 1)], 1), 2)
            .unwrap();
        s.put("w", "rB", BundleKind::DepartedB, &cv_with(&[(2, 1)], 1), 3)
            .unwrap();

        let active = s.rooms("w", BundleKind::ActiveA).unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].room, "rA");

        let departed = s.rooms("w", BundleKind::DepartedB).unwrap();
        assert_eq!(departed.len(), 2);
    }
}
