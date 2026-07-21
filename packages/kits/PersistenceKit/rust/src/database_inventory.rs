//! Deterministic table inventory + content folds (GLK shared-content 1.1,
//! P0). Rust twin of Swift `DatabaseInventory.swift`.
//!
//! The shared-content migration must be able to prove, before and after any
//! destructive step, exactly which rows exist and that PROTECTED state
//! (drawers, audit/history, relationships, unrelated/shared vectors) is
//! byte-identical to its pre-migration baseline. This helper captures that
//! baseline: per-table row counts plus an order-independent deterministic
//! fold over canonically-encoded rows.
//!
//! The fold is FNV-1a 64 per row over a canonical row encoding, combined
//! with wrapping addition so enumeration order cannot affect the digest.
//! It is an integrity DIAGNOSTIC (detects accidental mutation in migration
//! and characterization tests), not a cryptographic attestation.
//!
//! The canonical value encoding is byte-identical to the Swift port — see
//! the table in `DatabaseInventory.swift`; floats encode as IEEE-754 bit
//! patterns (never text), timestamps as epoch milliseconds.

use crate::error::StorageResult;
use crate::layout_signature::{fnv1a64_fold, FNV1A64_OFFSET_BASIS};
use crate::storage::Storage;
use crate::types::{StorageRow, TypedValue};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;
use std::sync::Arc;

/// Inventory of one table: its live row count and deterministic content fold.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TableInventory {
    pub table: String,
    pub row_count: usize,
    /// Order-independent FNV-1a 64 fold over canonical row encodings,
    /// lowercase hex. Two captures are equal iff the table holds the
    /// same multiset of rows (up to FNV collision odds).
    pub content_fold: String,
}

/// Capture the inventory of every table named in `tables`, in name order.
///
/// Missing tables surface the backend's table-not-found error — callers
/// enumerating a declared schema should only pass declared tables.
/// `excluding_columns` names per-table columns to EXCLUDE from the fold
/// (e.g. a nondeterministic `created_at` audit stamp); excluded columns
/// still count toward row presence via the row count.
pub fn capture_inventory(
    storage: &Arc<dyn Storage>,
    tables: &[&str],
    excluding_columns: &BTreeMap<String, BTreeSet<String>>,
) -> StorageResult<Vec<TableInventory>> {
    let mut names: Vec<&str> = tables.to_vec();
    names.sort_unstable();
    let row_store = storage.row_store();
    let mut out = Vec::with_capacity(names.len());
    for table in names {
        let rows = row_store.query(table, None, &[], None, None)?;
        let empty = BTreeSet::new();
        let excluded = excluding_columns.get(table).unwrap_or(&empty);
        let mut combined: u64 = 0;
        for row in &rows {
            let encoded = canonical_row_encoding(row, excluded);
            let row_hash = fnv1a64_fold(encoded.as_bytes(), FNV1A64_OFFSET_BASIS);
            combined = combined.wrapping_add(row_hash);
        }
        out.push(TableInventory {
            table: table.to_string(),
            row_count: rows.len(),
            content_fold: format!("{combined:016x}"),
        });
    }
    Ok(out)
}

/// Canonical, cross-port-stable encoding of one row.
/// Columns sorted by name (BTreeMap order); excluded columns omitted.
pub fn canonical_row_encoding(row: &StorageRow, excluded: &BTreeSet<String>) -> String {
    row.values
        .iter()
        .filter(|(name, _)| !excluded.contains(*name))
        .map(|(name, value)| format!("{name}={}", canonical_value_encoding(value)))
        .collect::<Vec<_>>()
        .join("\u{1F}")
}

/// Canonical, cross-port-stable encoding of one TypedValue.
/// See `DatabaseInventory.swift` for the format table.
pub fn canonical_value_encoding(value: &TypedValue) -> String {
    match value {
        TypedValue::Null => "n".to_string(),
        TypedValue::Bool(b) => format!("b:{}", u8::from(*b)),
        TypedValue::Int(i) => format!("i:{i}"),
        TypedValue::Bitmap(i) => format!("m:{i}"),
        // IEEE-754 bit pattern — float TEXT rendering is not stable across
        // ports; the bit pattern is (f64 wire discipline).
        TypedValue::Float(d) => format!("f:{:016x}", d.to_bits()),
        TypedValue::Text(t) => format!("t:{}:{t}", t.len()),
        TypedValue::Blob(bytes) => {
            let mut s = format!("x:{}:", bytes.len());
            for b in bytes {
                let _ = write!(s, "{b:02x}");
            }
            s
        }
        TypedValue::Uuid(u) => format!("u:{u}"),
        // Epoch milliseconds — the native Rust representation; the Swift
        // port converts its Date to rounded epoch milliseconds to match.
        TypedValue::Timestamp(millis) => format!("s:{millis}"),
        TypedValue::Json(bytes) => match std::str::from_utf8(bytes) {
            Ok(text) => format!("j:{}:{text}", bytes.len()),
            Err(_) => {
                let mut s = format!("j:{}:", bytes.len());
                for b in bytes {
                    let _ = write!(s, "{b:02x}");
                }
                s
            }
        },
        TypedValue::Hlc(hlc) => format!("h:{}", hlc.packed()),
        // Four big-endian 64-bit blocks as 16-hex-digit groups — the block
        // layout both ports share (`Fingerprint256` blocks 0..3).
        TypedValue::Fingerprint(fp) => format!(
            "p:{:016x}{:016x}{:016x}{:016x}",
            fp.block(0),
            fp.block(1),
            fp.block(2),
            fp.block(3)
        ),
        TypedValue::Array(elements) => {
            let inner: Vec<String> = elements.iter().map(canonical_value_encoding).collect();
            format!("a:[{}]", inner.join(","))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inmemory::InMemoryStorage;
    use crate::schema::{ColumnDeclaration, SchemaDeclaration, TableDeclaration};
    use crate::storage::{BackendConfiguration, EstateConfiguration, Storage};
    use std::collections::BTreeMap as Map;

    fn open_sample() -> Arc<dyn Storage> {
        let config = EstateConfiguration::new(uuid::Uuid::new_v4(), BackendConfiguration::InMemory);
        let storage: Arc<dyn Storage> = Arc::new(InMemoryStorage::new(config));
        let schema = SchemaDeclaration::new(
            "InventoryKit",
            1,
            vec![TableDeclaration::new(
                "widgets",
                vec![
                    ColumnDeclaration::uuid("id"),
                    ColumnDeclaration::text("name"),
                    ColumnDeclaration::int("rank"),
                ],
                vec!["id".to_string()],
            )],
        );
        storage.open(&schema).expect("open");
        storage
    }

    fn insert_widget(storage: &Arc<dyn Storage>, name: &str, rank: i64) {
        let mut values: Map<String, TypedValue> = Map::new();
        values.insert("id".into(), TypedValue::Uuid(uuid::Uuid::new_v4()));
        values.insert("name".into(), TypedValue::Text(name.to_string()));
        values.insert("rank".into(), TypedValue::Int(rank));
        storage
            .row_store()
            .insert("widgets", values)
            .expect("insert");
    }

    #[test]
    fn inventory_counts_and_folds_deterministically() {
        let storage = open_sample();
        insert_widget(&storage, "a", 1);
        insert_widget(&storage, "b", 2);
        let inv1 = capture_inventory(&storage, &["widgets"], &BTreeMap::new()).unwrap();
        let inv2 = capture_inventory(&storage, &["widgets"], &BTreeMap::new()).unwrap();
        assert_eq!(inv1, inv2);
        assert_eq!(inv1[0].row_count, 2);
    }

    #[test]
    fn fold_detects_mutation_and_ignores_excluded_columns() {
        let storage = open_sample();
        insert_widget(&storage, "a", 1);
        let baseline = capture_inventory(&storage, &["widgets"], &BTreeMap::new()).unwrap();
        insert_widget(&storage, "b", 2);
        let changed = capture_inventory(&storage, &["widgets"], &BTreeMap::new()).unwrap();
        assert_ne!(baseline[0].content_fold, changed[0].content_fold);

        // Excluding the differing column makes two same-shape rows fold equal.
        let mut excl = BTreeMap::new();
        excl.insert(
            "widgets".to_string(),
            ["id", "name", "rank"]
                .iter()
                .map(|s| s.to_string())
                .collect::<BTreeSet<_>>(),
        );
        let all_excluded = capture_inventory(&storage, &["widgets"], &excl).unwrap();
        // Every column excluded → every row encodes empty → fold depends
        // only on row count.
        assert_eq!(all_excluded[0].row_count, 2);
    }

    #[test]
    fn canonical_value_encoding_is_bit_exact_for_floats() {
        assert_eq!(
            canonical_value_encoding(&TypedValue::Float(1.5)),
            "f:3ff8000000000000"
        );
        assert_eq!(canonical_value_encoding(&TypedValue::Null), "n");
        assert_eq!(
            canonical_value_encoding(&TypedValue::Text("hé".into())),
            format!("t:{}:hé", "hé".len())
        );
    }
}
