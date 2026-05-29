//! SyncRecord wire format.
//!
//! SyncRecord wraps a PersistenceKit TableChange with sync metadata
//! (schema version, kit id, HLC). The receiver decodes, validates
//! schema and kit, and applies the change through its local
//! PersistenceKit. Schema or kit mismatch causes the record to be
//! rejected (queued for retry post-app-update).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use persistence_kit::{StorageEvent, TypedValue};
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
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLC;
use uuid::Uuid;

/// Codable mirror of PersistenceKit::StorageEvent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SyncEventKind {
    Insert,
    Update,
    Delete,
}

impl From<StorageEvent> for SyncEventKind {
    fn from(e: StorageEvent) -> Self {
        match e {
            StorageEvent::Insert => SyncEventKind::Insert,
            StorageEvent::Update => SyncEventKind::Update,
            StorageEvent::Delete => SyncEventKind::Delete,
        }
    }
}

impl From<SyncEventKind> for StorageEvent {
    fn from(e: SyncEventKind) -> Self {
        match e {
            SyncEventKind::Insert => StorageEvent::Insert,
            SyncEventKind::Update => StorageEvent::Update,
            SyncEventKind::Delete => StorageEvent::Delete,
        }
    }
}

/// Codable wrapper for HLC. Stable across encoders.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PackedHLC {
    pub physical_time: i64,
    pub logical_count: i32,
    pub node_id: i32,
}

impl From<HLC> for PackedHLC {
    fn from(h: HLC) -> Self {
        PackedHLC {
            physical_time: h.physical_time,
            logical_count: h.logical_count,
            node_id: h.node_id,
        }
    }
}

impl From<PackedHLC> for HLC {
    fn from(p: PackedHLC) -> Self {
        HLC {
            physical_time: p.physical_time,
            logical_count: p.logical_count,
            node_id: p.node_id,
        }
    }
}

/// Codable wrapper for Fingerprint256. Stable across encoders.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct FingerprintWire {
    pub block0: u64,
    pub block1: u64,
    pub block2: u64,
    pub block3: u64,
}

impl From<Fingerprint256> for FingerprintWire {
    fn from(f: Fingerprint256) -> Self {
        FingerprintWire {
            block0: f.block0,
            block1: f.block1,
            block2: f.block2,
            block3: f.block3,
        }
    }
}

impl From<FingerprintWire> for Fingerprint256 {
    fn from(w: FingerprintWire) -> Self {
        Fingerprint256::new(w.block0, w.block1, w.block2, w.block3)
    }
}

/// One TypedValue case, encoded with a discriminator. Mirrors
/// Swift's SyncValueBox.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", content = "payload", rename_all = "lowercase")]
pub enum SyncValueBox {
    Null,
    Bool(bool),
    Int(i64),
    Bitmap(i64),
    Float(f64),
    Text(String),
    Blob(Vec<u8>),
    Uuid(Uuid),
    /// Unix epoch seconds.
    Timestamp(i64),
    Json(Vec<u8>),
    Hlc(PackedHLC),
    Fingerprint(FingerprintWire),
    Array(Vec<SyncValueBox>),
}

impl From<TypedValue> for SyncValueBox {
    fn from(v: TypedValue) -> Self {
        match v {
            TypedValue::Null => SyncValueBox::Null,
            TypedValue::Bool(b) => SyncValueBox::Bool(b),
            TypedValue::Int(i) => SyncValueBox::Int(i),
            TypedValue::Bitmap(i) => SyncValueBox::Bitmap(i),
            TypedValue::Float(f) => SyncValueBox::Float(f),
            TypedValue::Text(s) => SyncValueBox::Text(s),
            TypedValue::Blob(b) => SyncValueBox::Blob(b),
            TypedValue::Uuid(u) => SyncValueBox::Uuid(u),
            TypedValue::Timestamp(t) => SyncValueBox::Timestamp(t),
            TypedValue::Json(b) => SyncValueBox::Json(b),
            TypedValue::Hlc(h) => SyncValueBox::Hlc(PackedHLC::from(h)),
            TypedValue::Fingerprint(f) => SyncValueBox::Fingerprint(FingerprintWire::from(f)),
            TypedValue::Array(arr) => {
                SyncValueBox::Array(arr.into_iter().map(SyncValueBox::from).collect())
            }
        }
    }
}

impl From<SyncValueBox> for TypedValue {
    fn from(b: SyncValueBox) -> Self {
        match b {
            SyncValueBox::Null => TypedValue::Null,
            SyncValueBox::Bool(b) => TypedValue::Bool(b),
            SyncValueBox::Int(i) => TypedValue::Int(i),
            SyncValueBox::Bitmap(i) => TypedValue::Bitmap(i),
            SyncValueBox::Float(f) => TypedValue::Float(f),
            SyncValueBox::Text(s) => TypedValue::Text(s),
            SyncValueBox::Blob(b) => TypedValue::Blob(b),
            SyncValueBox::Uuid(u) => TypedValue::Uuid(u),
            SyncValueBox::Timestamp(t) => TypedValue::Timestamp(t),
            SyncValueBox::Json(b) => TypedValue::Json(b),
            SyncValueBox::Hlc(h) => TypedValue::Hlc(HLC::from(h)),
            SyncValueBox::Fingerprint(w) => TypedValue::Fingerprint(Fingerprint256::from(w)),
            SyncValueBox::Array(arr) => {
                TypedValue::Array(arr.into_iter().map(TypedValue::from).collect())
            }
        }
    }
}

/// Codable wrapper for a row's values map.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncValueMap {
    pub entries: BTreeMap<String, SyncValueBox>,
}

impl SyncValueMap {
    pub fn from_typed(raw: BTreeMap<String, TypedValue>) -> Self {
        let entries = raw.into_iter().map(|(k, v)| (k, SyncValueBox::from(v))).collect();
        SyncValueMap { entries }
    }

    pub fn into_typed(self) -> BTreeMap<String, TypedValue> {
        self.entries
            .into_iter()
            .map(|(k, v)| (k, TypedValue::from(v)))
            .collect()
    }
}

/// One sync record, the unit of replication.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncRecord {
    pub table: String,
    pub event: SyncEventKind,
    pub row_key: Uuid,
    pub values: Option<SyncValueMap>,
    pub hlc: PackedHLC,
    pub schema_version: i32,
    pub kit_id: String,
}

impl SyncRecord {
    pub fn new(
        table: impl Into<String>,
        event: SyncEventKind,
        row_key: Uuid,
        values: Option<SyncValueMap>,
        hlc: HLC,
        schema_version: i32,
        kit_id: impl Into<String>,
    ) -> Self {
        SyncRecord {
            table: table.into(),
            event,
            row_key,
            values,
            hlc: PackedHLC::from(hlc),
            schema_version,
            kit_id: kit_id.into(),
        }
    }
}
