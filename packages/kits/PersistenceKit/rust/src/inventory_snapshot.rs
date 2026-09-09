//! Strict, bounded capture of the Locus inventory tables.
//!
//! This is intentionally a persistence primitive rather than an ARIA state
//! identity. It returns a consistent copy of `drawers` and `nodes`, or fails
//! without returning a partial snapshot. The callers own filtering,
//! authorization, and cryptographic identity construction.

use std::collections::BTreeMap;

use crate::error::StorageError;
use crate::types::{ColumnType, StorageRow, TypedValue};
use crate::SchemaDeclaration;

pub const INVENTORY_SNAPSHOT_DRAWERS_TABLE: &str = "drawers";
pub const INVENTORY_SNAPSHOT_NODES_TABLE: &str = "nodes";
pub const INVENTORY_SNAPSHOT_MAX_ROWS_PER_TABLE: usize = 250_000;
pub const INVENTORY_SNAPSHOT_MAX_SERIALIZED_BYTES: usize = 128 * 1024 * 1024;

/// Hard limits applied while each backend reads or copies the inventory.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InventorySnapshotLimits {
    max_rows_per_table: usize,
    max_serialized_bytes: usize,
}

impl InventorySnapshotLimits {
    pub const PRODUCTION: Self = Self {
        max_rows_per_table: INVENTORY_SNAPSHOT_MAX_ROWS_PER_TABLE,
        max_serialized_bytes: INVENTORY_SNAPSHOT_MAX_SERIALIZED_BYTES,
    };

    pub const fn production() -> Self {
        Self::PRODUCTION
    }

    /// Construct limits that can only tighten the production ceiling.
    pub fn new(
        max_rows_per_table: usize,
        max_serialized_bytes: usize,
    ) -> InventorySnapshotResult<Self> {
        if max_rows_per_table > INVENTORY_SNAPSHOT_MAX_ROWS_PER_TABLE {
            return Err(InventorySnapshotError::LimitExceedsProduction {
                limit: "max_rows_per_table".to_owned(),
                requested: max_rows_per_table,
                maximum: INVENTORY_SNAPSHOT_MAX_ROWS_PER_TABLE,
            });
        }
        if max_serialized_bytes > INVENTORY_SNAPSHOT_MAX_SERIALIZED_BYTES {
            return Err(InventorySnapshotError::LimitExceedsProduction {
                limit: "max_serialized_bytes".to_owned(),
                requested: max_serialized_bytes,
                maximum: INVENTORY_SNAPSHOT_MAX_SERIALIZED_BYTES,
            });
        }
        Ok(Self {
            max_rows_per_table,
            max_serialized_bytes,
        })
    }

    pub const fn max_rows_per_table(self) -> usize {
        self.max_rows_per_table
    }

    pub const fn max_serialized_bytes(self) -> usize {
        self.max_serialized_bytes
    }
}

impl Default for InventorySnapshotLimits {
    fn default() -> Self {
        Self::PRODUCTION
    }
}

/// Immutable-at-capture copy of the drawers and node rows.
#[derive(Debug, Clone)]
pub struct InventorySnapshot {
    pub drawers: Vec<StorageRow>,
    pub nodes: Vec<StorageRow>,
    serialized_row_bytes: usize,
}

impl InventorySnapshot {
    pub fn serialized_row_bytes(&self) -> usize {
        self.serialized_row_bytes
    }
}

/// Snapshot capture failed before a usable result was produced.
#[derive(Debug, Clone, PartialEq)]
pub enum InventorySnapshotError {
    Storage(StorageError),
    LimitExceedsProduction {
        limit: String,
        requested: usize,
        maximum: usize,
    },
    RowLimitExceeded { table: String, limit: usize },
    ByteLimitExceeded { limit: usize },
}

impl From<StorageError> for InventorySnapshotError {
    fn from(error: StorageError) -> Self {
        Self::Storage(error)
    }
}

impl std::fmt::Display for InventorySnapshotError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Storage(error) => write!(f, "inventory snapshot storage error: {error}"),
            Self::LimitExceedsProduction {
                limit,
                requested,
                maximum,
            } => write!(
                f,
                "inventory snapshot {limit} exceeds production ceiling: {requested} > {maximum}"
            ),
            Self::RowLimitExceeded { table, limit } => {
                write!(f, "inventory snapshot row limit exceeded for {table}: {limit}")
            }
            Self::ByteLimitExceeded { limit } => {
                write!(f, "inventory snapshot serialized byte limit exceeded: {limit}")
            }
        }
    }
}

impl std::error::Error for InventorySnapshotError {}

pub type InventorySnapshotResult<T> = Result<T, InventorySnapshotError>;

/// Backend-local accumulator. It makes the byte check before retaining a row,
/// so an error drops the entire in-progress snapshot.
pub(crate) struct InventorySnapshotBuilder {
    limits: InventorySnapshotLimits,
    drawers: Vec<StorageRow>,
    nodes: Vec<StorageRow>,
    serialized_row_bytes: usize,
}

impl InventorySnapshotBuilder {
    pub(crate) fn new(
        limits: InventorySnapshotLimits,
        drawer_count: usize,
        node_count: usize,
    ) -> InventorySnapshotResult<Self> {
        enforce_row_limit(INVENTORY_SNAPSHOT_DRAWERS_TABLE, drawer_count, limits)?;
        enforce_row_limit(INVENTORY_SNAPSHOT_NODES_TABLE, node_count, limits)?;
        Ok(Self {
            limits,
            drawers: Vec::with_capacity(drawer_count),
            nodes: Vec::with_capacity(node_count),
            serialized_row_bytes: 0,
        })
    }

    pub(crate) fn push_drawer(&mut self, row: StorageRow) -> InventorySnapshotResult<()> {
        self.push(INVENTORY_SNAPSHOT_DRAWERS_TABLE, row)
    }

    pub(crate) fn push_node(&mut self, row: StorageRow) -> InventorySnapshotResult<()> {
        self.push(INVENTORY_SNAPSHOT_NODES_TABLE, row)
    }

    /// Account against a borrowed stored row before cloning its values into
    /// the retained snapshot.
    pub(crate) fn copy_drawer_values(
        &mut self,
        values: &BTreeMap<String, TypedValue>,
    ) -> InventorySnapshotResult<()> {
        self.copy_values(INVENTORY_SNAPSHOT_DRAWERS_TABLE, values)
    }

    pub(crate) fn copy_node_values(
        &mut self,
        values: &BTreeMap<String, TypedValue>,
    ) -> InventorySnapshotResult<()> {
        self.copy_values(INVENTORY_SNAPSHOT_NODES_TABLE, values)
    }

    fn push(&mut self, table: &str, row: StorageRow) -> InventorySnapshotResult<()> {
        let row_bytes = serialized_storage_row_bytes(&row);
        self.reserve(table, row_bytes)?;
        match table {
            INVENTORY_SNAPSHOT_DRAWERS_TABLE => self.drawers.push(row),
            INVENTORY_SNAPSHOT_NODES_TABLE => self.nodes.push(row),
            _ => unreachable!("inventory snapshot only admits drawers and nodes"),
        }
        Ok(())
    }

    fn copy_values(
        &mut self,
        table: &str,
        values: &BTreeMap<String, TypedValue>,
    ) -> InventorySnapshotResult<()> {
        self.reserve(table, serialized_storage_values_bytes(values))?;
        match table {
            INVENTORY_SNAPSHOT_DRAWERS_TABLE => self.drawers.push(StorageRow::new(values.clone())),
            INVENTORY_SNAPSHOT_NODES_TABLE => self.nodes.push(StorageRow::new(values.clone())),
            _ => unreachable!("inventory snapshot only admits drawers and nodes"),
        }
        Ok(())
    }

    fn reserve(&mut self, _table: &str, row_bytes: usize) -> InventorySnapshotResult<()> {
        let total = self.serialized_row_bytes.checked_add(row_bytes).ok_or(
            InventorySnapshotError::ByteLimitExceeded {
                limit: self.limits.max_serialized_bytes,
            },
        )?;
        if total > self.limits.max_serialized_bytes {
            return Err(InventorySnapshotError::ByteLimitExceeded {
                limit: self.limits.max_serialized_bytes,
            });
        }
        self.serialized_row_bytes = total;
        Ok(())
    }

    pub(crate) fn finish(self) -> InventorySnapshot {
        InventorySnapshot {
            drawers: self.drawers,
            nodes: self.nodes,
            serialized_row_bytes: self.serialized_row_bytes,
        }
    }
}

pub(crate) fn enforce_row_limit(
    table: &str,
    count: usize,
    limits: InventorySnapshotLimits,
) -> InventorySnapshotResult<()> {
    if count > limits.max_rows_per_table {
        return Err(InventorySnapshotError::RowLimitExceeded {
            table: table.to_owned(),
            limit: limits.max_rows_per_table,
        });
    }
    Ok(())
}

/// Count the canonical serialized row representation without allocating that
/// representation. This deliberately does not invoke DatabaseInventory or its
/// FNV diagnostic fold; the bytes are only a retained-copy budget.
pub(crate) fn serialized_storage_row_bytes(row: &StorageRow) -> usize {
    serialized_storage_values_bytes(&row.values)
}

pub(crate) fn serialized_storage_values_bytes(
    values: &BTreeMap<String, TypedValue>,
) -> usize {
    let mut total = 0usize;
    for (index, (name, value)) in values.iter().enumerate() {
        if index != 0 {
            total = total.saturating_add('\u{1f}'.len_utf8());
        }
        total = total
            .saturating_add(name.len())
            .saturating_add(1)
            .saturating_add(serialized_typed_value_bytes(value));
    }
    total
}

fn serialized_typed_value_bytes(value: &TypedValue) -> usize {
    match value {
        TypedValue::Null => 1,
        TypedValue::Bool(_) => 3,
        TypedValue::Int(value) => 2 + signed_decimal_bytes(*value),
        TypedValue::Bitmap(value) => 2 + signed_decimal_bytes(*value),
        TypedValue::Float(_) => 18,
        TypedValue::Text(value) => 3 + decimal_bytes(value.len() as u64) + value.len(),
        TypedValue::Blob(value) => 3usize
            .saturating_add(decimal_bytes(value.len() as u64))
            .saturating_add(value.len().saturating_mul(2)),
        TypedValue::Uuid(_) => 38,
        TypedValue::Timestamp(value) => 2 + signed_decimal_bytes(*value),
        TypedValue::Json(value) => {
            let payload_bytes = if std::str::from_utf8(value).is_ok() {
                value.len()
            } else {
                value.len().saturating_mul(2)
            };
            3usize
                .saturating_add(decimal_bytes(value.len() as u64))
                .saturating_add(payload_bytes)
        }
        TypedValue::Hlc(value) => 2 + decimal_bytes(value.packed()),
        TypedValue::Fingerprint(_) => 66,
        TypedValue::Array(values) => {
            let payload = values.iter().enumerate().fold(0usize, |total, (index, value)| {
                total
                    .saturating_add(usize::from(index != 0))
                    .saturating_add(serialized_typed_value_bytes(value))
            });
            4usize.saturating_add(payload)
        }
    }
}

fn signed_decimal_bytes(value: i64) -> usize {
    if value < 0 {
        1 + decimal_bytes(value.unsigned_abs())
    } else {
        decimal_bytes(value as u64)
    }
}

fn decimal_bytes(mut value: u64) -> usize {
    let mut bytes = 1;
    while value >= 10 {
        value /= 10;
        bytes += 1;
    }
    bytes
}

/// Ordered declared columns for one inventory table. Snapshot reads use this
/// list rather than `SELECT *`, so their preflight and retained copy cover the
/// same explicit storage surface.
pub(crate) fn inventory_snapshot_columns(
    schema: Option<&SchemaDeclaration>,
    table: &str,
) -> InventorySnapshotResult<Vec<(String, ColumnType)>> {
    let declaration = schema
        .and_then(|schema| schema.tables.iter().find(|candidate| candidate.name == table))
        .ok_or_else(|| StorageError::InvalidConfiguration {
            reason: format!("inventory snapshot requires declared {table} table"),
        })?;
    let mut columns: Vec<(String, ColumnType)> = declaration
        .columns
        .iter()
        .map(|column| (column.name.clone(), column.column_type))
        .collect();
    columns.extend(
        declaration
            .generated_columns
            .iter()
            .map(|column| (column.name.clone(), column.column_type)),
    );
    Ok(columns)
}

#[cfg(test)]
mod canonical_length_tests {
    use super::*;

    #[test]
    fn array_framing_has_four_bytes_for_empty_and_nested_values() {
        assert_eq!(serialized_typed_value_bytes(&TypedValue::Array(vec![])), 4);
        assert_eq!(
            serialized_storage_values_bytes(&BTreeMap::from([(
                "a".to_owned(),
                TypedValue::Array(vec![]),
            )])),
            6,
            "a=a:[]"
        );
        assert_eq!(
            serialized_typed_value_bytes(&TypedValue::Array(vec![TypedValue::Array(vec![])])),
            8
        );
        assert_eq!(
            serialized_storage_values_bytes(&BTreeMap::from([(
                "a".to_owned(),
                TypedValue::Array(vec![TypedValue::Array(vec![])]),
            )])),
            10,
            "a=a:[a:[]]"
        );
    }

    #[test]
    fn exact_typed_blob_and_nested_array_boundary_is_accepted_then_rejected() {
        let row = StorageRow::new(BTreeMap::from([
            ("b".to_owned(), TypedValue::Blob(vec![0x00, 0xff])),
            ("j".to_owned(), TypedValue::Json(br#"{"ok":true}"#.to_vec())),
            (
                "a".to_owned(),
                TypedValue::Array(vec![TypedValue::Array(vec![]), TypedValue::Int(-7)]),
            ),
        ]));
        assert_eq!(serialized_typed_value_bytes(&TypedValue::Blob(vec![0x00, 0xff])), 8);
        let exact = serialized_storage_row_bytes(&row);
        let mut exact_builder = InventorySnapshotBuilder::new(
            InventorySnapshotLimits::new(1, exact).unwrap(),
            1,
            0,
        )
        .unwrap();
        exact_builder.push_drawer(row.clone()).unwrap();
        assert_eq!(exact_builder.finish().serialized_row_bytes(), exact);

        let mut one_byte_short = InventorySnapshotBuilder::new(
            InventorySnapshotLimits::new(1, exact - 1).unwrap(),
            1,
            0,
        )
        .unwrap();
        assert!(matches!(
            one_byte_short.push_drawer(row),
            Err(InventorySnapshotError::ByteLimitExceeded { limit }) if limit == exact - 1
        ));
    }
}
