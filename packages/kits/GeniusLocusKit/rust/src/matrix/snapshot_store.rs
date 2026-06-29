//! MatrixSnapshotStore: persistence-kit-backed `matrix_snapshot` table.
//! Rust mirror of Swift's `MatrixSnapshotStore`.
//!
//! On-disk persistence for the matrix tier (F, C, O, T population statistics)
//! plus its companion calibration registry, kept as a SQLite TABLE in the
//! estate's own storage — never memory-only, never a sidecar file.
//!
//! Before this store, the only persistence option was a length-prefixed sidecar
//! FILE (`MatrixPersistenceMode::Snapshotted`), and the launch path ignored it:
//! `rebuild_derived_accelerators` ALWAYS did a full rebuild from the whole audit
//! log on every cold start. On a 40k-drawer estate that full fold is a
//! multi-minute single-threaded pass that starves the resident. This store
//! closes that gap the spec way: the tier is persisted to disk at an HLC
//! watermark and, on launch, LOADED and folded forward over only the audit tail
//! (`MatrixTier::incremental_update`) — proven cell-for-cell equal to a
//! from-scratch rebuild by the conformance test. A full rebuild is the
//! cold-start / schema-mismatch fallback only.
//!
//! Schema (one row per estate):
//!   matrix_snapshot (
//!     estate_id      TEXT NOT NULL,    -- estate UUID; one snapshot per estate
//!     schema_version INTEGER NOT NULL, -- MatrixSnapshot format gate (cheap read)
//!     snapshot       BLOB NOT NULL,    -- length-prefixed MatrixSnapshot bytes
//!     last_hlc       TEXT NOT NULL,    -- F/O/C cursor watermark (human-readable)
//!     updated_at     TIMESTAMP NOT NULL, -- TEXT ISO8601 at SQLite layer; never REAL
//!     ext            JSON              -- forward-compat slot (ADR-012); nullable
//!   )  PRIMARY KEY (estate_id)
//!
//! `schema_version` is its own column so a format change can be detected with one
//! cheap query and the row rejected without deserializing the blob. NOT
//! append-only: a save UPSERTs the estate's single row. Layering: GLK composition
//! layer, depends only on persistence-kit; the blob bytes are produced by
//! `matrix::persistence::{encode,decode}_snapshot` (same wire format as the
//! sidecar mode), interpreted nowhere here.

use std::sync::Arc;

use persistence_kit::{
    Column, ColumnDeclaration, SchemaDeclaration, Storage, StoragePredicate, StorageResult,
    StorageRow, TableDeclaration, TypedValue,
};

use super::persistence::{decode_snapshot, encode_snapshot, MatrixSnapshot};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// This store persists and returns a length-prefixed MatrixSnapshot blob.
// It computes nothing — no folds, no rebuilds. The matrix math lives in
// matrix.rs / substrate-ml.
// ─────────────────────────────────────────────────────────────────

/// SQLite-backed persistence for an estate's matrix tier snapshot.
///
/// One row per estate. `upsert` writes/replaces it; `load` reads and decodes the
/// snapshot (rejecting a schema-version mismatch by returning `None` so the
/// caller falls back to a full rebuild); `delete_all` wipes every row.
pub struct MatrixSnapshotStore {
    storage: Arc<dyn Storage>,
}

impl MatrixSnapshotStore {
    /// Additive schema declaration for the matrix-snapshot table, under its own
    /// kitID so it migrates independently of the GLK composite — the same pattern
    /// CorpusKit's CorpusProviderCountsStore / RemovedSourceStore use. Not
    /// append-only: a save UPSERTs the estate's row.
    pub fn schema_declaration() -> SchemaDeclaration {
        SchemaDeclaration::new(
            "GeniusLocusKitMatrix",
            1,
            vec![TableDeclaration::new(
                "matrix_snapshot",
                vec![
                    ColumnDeclaration::text("estate_id"),
                    // INTEGER format gate — NOT a Bool flag.
                    ColumnDeclaration::int("schema_version"),
                    // BLOB: the length-prefixed MatrixSnapshot bytes.
                    ColumnDeclaration::blob("snapshot"),
                    // The F/O/C cursor, human-readable; diagnostics surface.
                    ColumnDeclaration::text("last_hlc"),
                    // TIMESTAMP maps to TEXT ISO8601 (schema invariant) — never REAL.
                    ColumnDeclaration::timestamp("updated_at"),
                    // ADR-012 forward-compat slot; nullable JSON; omitted on upsert in 1.0.
                    ColumnDeclaration::json("ext").nullable(),
                ],
                vec!["estate_id".to_string()],
            )],
        )
    }

    pub fn new(storage: Arc<dyn Storage>) -> Self {
        MatrixSnapshotStore { storage }
    }

    /// Insert or replace the matrix snapshot for an estate. Keyed by `estate_id`:
    /// a save replaces the prior snapshot in place. `now_secs` is the caller's
    /// clock (determinism — the engine never reads the wall clock).
    pub fn upsert(
        &self,
        estate_id: &str,
        snapshot: &MatrixSnapshot,
        now_secs: i64,
    ) -> StorageResult<()> {
        let blob = encode_snapshot(snapshot);
        let mut values: std::collections::BTreeMap<String, TypedValue> =
            std::collections::BTreeMap::new();
        values.insert("estate_id".into(), TypedValue::Text(estate_id.to_string()));
        values.insert(
            "schema_version".into(),
            TypedValue::Int(snapshot.schema_version as i64),
        );
        values.insert("snapshot".into(), TypedValue::Blob(blob));
        values.insert(
            "last_hlc".into(),
            TypedValue::Text(encode_hlc(&snapshot.tier.last_hlc)),
        );
        values.insert("updated_at".into(), TypedValue::Timestamp(now_secs));
        self.storage
            .row_store()
            .upsert("matrix_snapshot", values, &["estate_id".to_string()])?;
        Ok(())
    }

    /// Load and decode the matrix snapshot for an estate, or `None` if none
    /// exists, the persisted format does not match the current schema version, or
    /// the blob fails to decode. A mismatch/decode failure returns `None` (not an
    /// error): the snapshot is a rebuildable cache, so the caller falls back to a
    /// full rebuild — never fabricate a partial tier.
    pub fn load(&self, estate_id: &str) -> StorageResult<Option<MatrixSnapshot>> {
        let predicate = StoragePredicate::Eq(
            Column::new("matrix_snapshot", "estate_id"),
            TypedValue::Text(estate_id.to_string()),
        );
        let rows: Vec<StorageRow> =
            self.storage
                .row_store()
                .query("matrix_snapshot", Some(&predicate), &[], Some(1), None)?;
        let Some(row) = rows.first() else {
            return Ok(None);
        };
        // Cheap gate first: reject a foreign schema version without decoding the
        // (potentially large) blob.
        match row.get("schema_version") {
            Some(TypedValue::Int(v)) if *v as i32 == MatrixSnapshot::CURRENT_SCHEMA_VERSION => {}
            _ => return Ok(None),
        }
        let blob = match row.get("snapshot") {
            Some(TypedValue::Blob(b)) => b,
            _ => return Ok(None),
        };
        match decode_snapshot(blob) {
            // Defence in depth: the blob carries its own schema_version; if it
            // disagrees with the current format, treat as stale and rebuild.
            Ok(snap) if snap.schema_version == MatrixSnapshot::CURRENT_SCHEMA_VERSION => {
                Ok(Some(snap))
            }
            _ => Ok(None),
        }
    }

    /// Delete every matrix snapshot row. Mirrors the other stores' `delete_all`
    /// for teardown paths that wipe an estate's derived state.
    pub fn delete_all(&self) -> StorageResult<()> {
        self.storage
            .row_store()
            .delete("matrix_snapshot", &StoragePredicate::IsTrue)?;
        Ok(())
    }
}

/// Render an HLC to the `last_hlc` diagnostics column. The authoritative cursor
/// lives inside the blob (`tier.last_hlc`); this is a human-readable mirror.
fn encode_hlc(hlc: &substrate_types::hlc::HLC) -> String {
    format!("{}.{}.{}", hlc.physical_time, hlc.logical_count, hlc.node_id)
}
