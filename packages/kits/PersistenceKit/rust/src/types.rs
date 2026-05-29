//! Core typed value carrier.
//!
//! Every value crossing the kit boundary is wrapped in TypedValue;
//! backends pattern-match on the variant and emit backend-native
//! wire format. The variant set is closed.

use std::collections::BTreeMap;
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
use substrate_lib::hlc::HLC;

/// Stable row identifier. Mirrors Swift's `RowKey = UUID`.
pub type RowKey = uuid::Uuid;

/// Mirror of Swift's `TypedValue` enum.
#[derive(Debug, Clone, PartialEq)]
pub enum TypedValue {
    Null,
    Bool(bool),
    Int(i64),
    Bitmap(i64),
    Float(f64),
    Text(String),
    Blob(Vec<u8>),
    Uuid(uuid::Uuid),
    Timestamp(i64),
    Json(Vec<u8>),
    Hlc(HLC),
    Fingerprint(Fingerprint256),
    Array(Vec<TypedValue>),
}

impl TypedValue {
    pub fn type_description(&self) -> &'static str {
        match self {
            TypedValue::Null => "null",
            TypedValue::Bool(_) => "bool",
            TypedValue::Int(_) => "int",
            TypedValue::Bitmap(_) => "bitmap",
            TypedValue::Float(_) => "float",
            TypedValue::Text(_) => "text",
            TypedValue::Blob(_) => "blob",
            TypedValue::Uuid(_) => "uuid",
            TypedValue::Timestamp(_) => "timestamp",
            TypedValue::Json(_) => "json",
            TypedValue::Hlc(_) => "hlc",
            TypedValue::Fingerprint(_) => "fingerprint",
            TypedValue::Array(_) => "array",
        }
    }

    pub fn is_null(&self) -> bool {
        matches!(self, TypedValue::Null)
    }
}

impl Eq for TypedValue {}

impl std::hash::Hash for TypedValue {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            TypedValue::Null => {}
            TypedValue::Bool(b) => b.hash(state),
            TypedValue::Int(i) => i.hash(state),
            TypedValue::Bitmap(i) => i.hash(state),
            TypedValue::Float(f) => f.to_bits().hash(state),
            TypedValue::Text(s) => s.hash(state),
            TypedValue::Blob(b) => b.hash(state),
            TypedValue::Uuid(u) => u.hash(state),
            TypedValue::Timestamp(t) => t.hash(state),
            TypedValue::Json(b) => b.hash(state),
            TypedValue::Hlc(h) => {
                h.physical_time.hash(state);
                h.logical_count.hash(state);
                h.node_id.hash(state);
            }
            TypedValue::Fingerprint(f) => {
                f.block0.hash(state);
                f.block1.hash(state);
                f.block2.hash(state);
                f.block3.hash(state);
            }
            TypedValue::Array(v) => v.hash(state),
        }
    }
}

/// Column reference: (table, name) pair used in predicates and
/// queries. Mirrors Swift's `Column`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Column {
    pub table: String,
    pub name: String,
}

impl Column {
    pub fn new(table: impl Into<String>, name: impl Into<String>) -> Self {
        Column {
            table: table.into(),
            name: name.into(),
        }
    }
}

/// Mirror of Swift's `ColumnType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ColumnType {
    Uuid,
    Bitmap,
    Text,
    Timestamp,
    Float,
    Int,
    Bool,
    Blob,
    Json,
    Hlc,
    Fingerprint,
}

/// One row, keyed by column name. Mirrors Swift's `StorageRow`.
#[derive(Debug, Clone, Default)]
pub struct StorageRow {
    pub values: BTreeMap<String, TypedValue>,
}

impl StorageRow {
    pub fn new(values: BTreeMap<String, TypedValue>) -> Self {
        StorageRow { values }
    }

    pub fn from_pairs(pairs: impl IntoIterator<Item = (impl Into<String>, TypedValue)>) -> Self {
        StorageRow {
            values: pairs
                .into_iter()
                .map(|(k, v)| (k.into(), v))
                .collect(),
        }
    }

    pub fn get(&self, column: &str) -> Option<&TypedValue> {
        self.values.get(column)
    }
}

/// Row handle returned from insert / upsert. Mirrors Swift's
/// `RowHandle`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RowHandle {
    pub table: String,
    pub key: RowKey,
}

impl RowHandle {
    pub fn new(table: impl Into<String>, key: RowKey) -> Self {
        RowHandle {
            table: table.into(),
            key,
        }
    }
}
