//! Snapshot registry and attestation primitives (ADR-017 §15).
//!
//! A snapshot is a registry row recording WHEN (an HLC), plus
//! attestation rows recording WHAT the Merkle roots were at that HLC.
//! The registry is a PersistenceKit primitive: it knows nothing about
//! wings, drawers, or estates. Upper kits supply the subject_kind
//! and subject_id semantics.

use crate::error::StorageResult;
use crate::predicate::{OrderClause, StoragePredicate};
use crate::row_store::RowStore;
use crate::schema::{ColumnDeclaration, TableDeclaration};
use crate::types::{Column, StorageRow, TypedValue};
use std::collections::BTreeMap;
use substrate_types::hlc::HLC;

// MARK: - Types

/// Opaque identifier for a snapshot. String-typed for cross-backend
/// portability (SQLite TEXT PK, PostgreSQL TEXT PK, InMemory dict key).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SnapshotId {
    pub raw_value: String,
}

impl SnapshotId {
    pub fn new(raw_value: impl Into<String>) -> Self {
        SnapshotId {
            raw_value: raw_value.into(),
        }
    }

    /// Mint a new snapshot id from a UUID.
    pub fn mint() -> Self {
        SnapshotId {
            raw_value: uuid::Uuid::new_v4().to_string(),
        }
    }
}

impl std::fmt::Display for SnapshotId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.raw_value)
    }
}

/// A row in the `snapshot_registry` table.
#[derive(Debug, Clone, PartialEq)]
pub struct SnapshotRecord {
    pub snapshot_id: SnapshotId,
    pub hlc: HLC,
    pub label: Option<String>,
    /// Wall-clock creation time as seconds since Unix epoch.
    pub created_at: i64,
}

/// A row in the `snapshot_attestations` table.
#[derive(Debug, Clone, PartialEq)]
pub struct SnapshotAttestation {
    pub snapshot_id: SnapshotId,
    pub subject_kind: String,
    pub subject_id: String,
    pub merkle_root: String,
    /// HMAC key version if this attestation is commitment-bearing (§17).
    pub key_version: Option<i64>,
}

// MARK: - Schema declarations

/// Table name constants for snapshot tables.
pub const SNAPSHOT_REGISTRY_TABLE: &str = "snapshot_registry";
pub const SNAPSHOT_ATTESTATIONS_TABLE: &str = "snapshot_attestations";

/// Schema declarations for snapshot registry and attestations tables.
/// Kits include these in their SchemaDeclaration.tables array.
pub fn registry_table_declaration() -> TableDeclaration {
    TableDeclaration::new(
        SNAPSHOT_REGISTRY_TABLE,
        vec![
            ColumnDeclaration::text("snapshot_id"),
            ColumnDeclaration::hlc("hlc"),
            ColumnDeclaration::text("label").nullable(),
            ColumnDeclaration::timestamp("created_at"),
        ],
        vec!["snapshot_id".to_string()],
    )
}

pub fn attestations_table_declaration() -> TableDeclaration {
    TableDeclaration::new(
        SNAPSHOT_ATTESTATIONS_TABLE,
        vec![
            ColumnDeclaration::text("snapshot_id"),
            ColumnDeclaration::text("subject_kind"),
            ColumnDeclaration::text("subject_id"),
            ColumnDeclaration::text("merkle_root"),
            ColumnDeclaration::int("key_version").nullable(),
        ],
        vec![
            "snapshot_id".to_string(),
            "subject_kind".to_string(),
            "subject_id".to_string(),
        ],
    )
}

// MARK: - CRUD operations

/// Create a new snapshot: mint a SnapshotId, record the current HLC,
/// and write attestation rows for each supplied root.
pub fn create_snapshot(
    row_store: &dyn RowStore,
    hlc: HLC,
    label: Option<&str>,
    created_at: i64,
    attestations: &[SnapshotAttestation],
) -> StorageResult<SnapshotRecord> {
    let id = SnapshotId::mint();

    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert("snapshot_id".to_string(), TypedValue::Text(id.raw_value.clone()));
    values.insert("hlc".to_string(), TypedValue::Hlc(hlc));
    values.insert(
        "label".to_string(),
        label.map(|l| TypedValue::Text(l.to_string())).unwrap_or(TypedValue::Null),
    );
    values.insert("created_at".to_string(), TypedValue::Timestamp(created_at));

    row_store.insert(SNAPSHOT_REGISTRY_TABLE, values)?;

    for att in attestations {
        let att_with_id = SnapshotAttestation {
            snapshot_id: id.clone(),
            subject_kind: att.subject_kind.clone(),
            subject_id: att.subject_id.clone(),
            merkle_root: att.merkle_root.clone(),
            key_version: att.key_version,
        };
        insert_attestation(row_store, &att_with_id)?;
    }

    Ok(SnapshotRecord {
        snapshot_id: id,
        hlc,
        label: label.map(|l| l.to_string()),
        created_at,
    })
}

/// List all snapshots, ordered by HLC ascending.
pub fn list_snapshots(row_store: &dyn RowStore) -> StorageResult<Vec<SnapshotRecord>> {
    let rows = row_store.query(
        SNAPSHOT_REGISTRY_TABLE,
        None,
        &[OrderClause::ascending(Column::new(
            SNAPSHOT_REGISTRY_TABLE,
            "hlc",
        ))],
        None,
        None,
    )?;
    Ok(rows.iter().filter_map(decode_snapshot_record).collect())
}

/// Delete a snapshot and its attestations. Returns true if the
/// snapshot existed (and was deleted).
pub fn delete_snapshot(
    row_store: &dyn RowStore,
    snapshot_id: &SnapshotId,
) -> StorageResult<bool> {
    // Delete attestations first (child rows).
    row_store.delete(
        SNAPSHOT_ATTESTATIONS_TABLE,
        &StoragePredicate::Eq(
            Column::new(SNAPSHOT_ATTESTATIONS_TABLE, "snapshot_id"),
            TypedValue::Text(snapshot_id.raw_value.clone()),
        ),
    )?;
    // Delete registry row.
    let deleted = row_store.delete(
        SNAPSHOT_REGISTRY_TABLE,
        &StoragePredicate::Eq(
            Column::new(SNAPSHOT_REGISTRY_TABLE, "snapshot_id"),
            TypedValue::Text(snapshot_id.raw_value.clone()),
        ),
    )?;
    Ok(deleted > 0)
}

/// Read attestations for a given snapshot.
pub fn snapshot_attestations(
    row_store: &dyn RowStore,
    snapshot_id: &SnapshotId,
) -> StorageResult<Vec<SnapshotAttestation>> {
    let rows = row_store.query(
        SNAPSHOT_ATTESTATIONS_TABLE,
        Some(&StoragePredicate::Eq(
            Column::new(SNAPSHOT_ATTESTATIONS_TABLE, "snapshot_id"),
            TypedValue::Text(snapshot_id.raw_value.clone()),
        )),
        &[
            OrderClause::ascending(Column::new(SNAPSHOT_ATTESTATIONS_TABLE, "subject_kind")),
            OrderClause::ascending(Column::new(SNAPSHOT_ATTESTATIONS_TABLE, "subject_id")),
        ],
        None,
        None,
    )?;
    Ok(rows.iter().filter_map(decode_attestation).collect())
}

// MARK: - Internal helpers

fn insert_attestation(
    row_store: &dyn RowStore,
    attestation: &SnapshotAttestation,
) -> StorageResult<()> {
    let mut values: BTreeMap<String, TypedValue> = BTreeMap::new();
    values.insert(
        "snapshot_id".to_string(),
        TypedValue::Text(attestation.snapshot_id.raw_value.clone()),
    );
    values.insert(
        "subject_kind".to_string(),
        TypedValue::Text(attestation.subject_kind.clone()),
    );
    values.insert(
        "subject_id".to_string(),
        TypedValue::Text(attestation.subject_id.clone()),
    );
    values.insert(
        "merkle_root".to_string(),
        TypedValue::Text(attestation.merkle_root.clone()),
    );
    values.insert(
        "key_version".to_string(),
        attestation
            .key_version
            .map(TypedValue::Int)
            .unwrap_or(TypedValue::Null),
    );
    row_store.insert(SNAPSHOT_ATTESTATIONS_TABLE, values)?;
    Ok(())
}

fn decode_snapshot_record(row: &StorageRow) -> Option<SnapshotRecord> {
    let id = match row.get("snapshot_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let hlc = match row.get("hlc") {
        Some(TypedValue::Hlc(h)) => *h,
        // SQLite read-back returns Text for HLC columns; parse packed i64.
        Some(TypedValue::Text(s)) => {
            let packed: i64 = s.parse().ok()?;
            HLC::from_packed(packed as u64)
        }
        Some(TypedValue::Int(i)) => HLC::from_packed(*i as u64),
        _ => return None,
    };
    let created_at = match row.get("created_at") {
        Some(TypedValue::Timestamp(t)) => *t,
        Some(TypedValue::Int(i)) => *i,
        Some(TypedValue::Text(s)) => s.parse().ok()?,
        _ => return None,
    };
    let label = match row.get("label") {
        Some(TypedValue::Text(l)) => Some(l.clone()),
        _ => None,
    };
    Some(SnapshotRecord {
        snapshot_id: SnapshotId::new(id),
        hlc,
        label,
        created_at,
    })
}

fn decode_attestation(row: &StorageRow) -> Option<SnapshotAttestation> {
    let sid = match row.get("snapshot_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let kind = match row.get("subject_kind") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let sub_id = match row.get("subject_id") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let root = match row.get("merkle_root") {
        Some(TypedValue::Text(s)) => s.clone(),
        _ => return None,
    };
    let key_version = match row.get("key_version") {
        Some(TypedValue::Int(kv)) => Some(*kv),
        _ => None,
    };
    Some(SnapshotAttestation {
        snapshot_id: SnapshotId::new(sid),
        subject_kind: kind,
        subject_id: sub_id,
        merkle_root: root,
        key_version,
    })
}
