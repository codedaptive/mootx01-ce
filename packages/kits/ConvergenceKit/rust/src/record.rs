//! SyncRecord wire format.
//!
//! SyncRecord wraps a PersistenceKit TableChange with sync metadata
//! (schema version, kit id, HLC). The receiver decodes, validates
//! schema and kit, and applies the change through its local
//! PersistenceKit. Schema or kit mismatch is counted as a conflict
//! and the record is skipped; no retry queue is present.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use persistence_kit::{StorageEvent, TypedValue};
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
/// JSON contract: camelCase field names matching Swift's property names.
///
/// Ordering is lexicographic by (physical_time, logical_count, node_id) —
/// the same field order as the struct declaration, which matches the Swift
/// `Comparable` extension on `PackedHLC` (ColumnHLCMap.swift). `derive`
/// on a struct with all-Ord fields uses declaration order, so the ordering
/// is byte-identical to Swift's implementation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PackedHLC {
    pub physical_time: i64,
    pub logical_count: i32,
    /// Serializes as "nodeID" to match Swift's property name (not "nodeId").
    #[serde(rename = "nodeID")]
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

/// Maximum nesting depth for `SyncValueBox::Array` on both encode and decode.
///
/// WHY 3: LocusKit's actual usage is ≤2 (an array-of-scalars inside an
/// array-of-rows). 3 gives one level of headroom. Deeper nesting is either
/// adversarial inbound data or a local bug producing a hostile payload —
/// in both cases the record is rejected as a per-record conflict (Serialize
/// or Deserialize returns Err), never a crash or stack exhaustion
/// (CVK-WC5, Perkins defense-in-depth). serde_json has its own 128-level
/// recursion guard; our cap at 3 fires first for any realistic input.
const SYNC_VALUE_BOX_MAX_ARRAY_DEPTH: u8 = 3;

/// Private mirror of `SyncValueBox` carrying the serde derive attributes.
///
/// WHY a private mirror: `SyncValueBox` implements custom `Serialize` and
/// `Deserialize` (to enforce `SYNC_VALUE_BOX_MAX_ARRAY_DEPTH`). The mirror
/// carries the `#[derive]` so we get the correct internally-tagged JSON
/// format without hand-writing a visitor. The conversions between the two
/// types are O(n) in tree size and only called on the serde boundary.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", content = "payload", rename_all = "lowercase")]
enum SyncValueBoxRaw {
    Null,
    Bool(bool),
    Int(i64),
    Bitmap(i64),
    Float(f64),
    Text(String),
    Blob(Vec<u8>),
    Uuid(Uuid),
    Timestamp(i64),
    Json(Vec<u8>),
    Hlc(PackedHLC),
    Fingerprint(FingerprintWire),
    Array(Vec<SyncValueBoxRaw>),
}

impl From<SyncValueBoxRaw> for SyncValueBox {
    fn from(raw: SyncValueBoxRaw) -> Self {
        match raw {
            SyncValueBoxRaw::Null => SyncValueBox::Null,
            SyncValueBoxRaw::Bool(b) => SyncValueBox::Bool(b),
            SyncValueBoxRaw::Int(i) => SyncValueBox::Int(i),
            SyncValueBoxRaw::Bitmap(i) => SyncValueBox::Bitmap(i),
            SyncValueBoxRaw::Float(f) => SyncValueBox::Float(f),
            SyncValueBoxRaw::Text(s) => SyncValueBox::Text(s),
            SyncValueBoxRaw::Blob(b) => SyncValueBox::Blob(b),
            SyncValueBoxRaw::Uuid(u) => SyncValueBox::Uuid(u),
            SyncValueBoxRaw::Timestamp(t) => SyncValueBox::Timestamp(t),
            SyncValueBoxRaw::Json(b) => SyncValueBox::Json(b),
            SyncValueBoxRaw::Hlc(h) => SyncValueBox::Hlc(h),
            SyncValueBoxRaw::Fingerprint(f) => SyncValueBox::Fingerprint(f),
            SyncValueBoxRaw::Array(items) => {
                SyncValueBox::Array(items.into_iter().map(SyncValueBox::from).collect())
            }
        }
    }
}

impl From<SyncValueBox> for SyncValueBoxRaw {
    fn from(val: SyncValueBox) -> Self {
        match val {
            SyncValueBox::Null => SyncValueBoxRaw::Null,
            SyncValueBox::Bool(b) => SyncValueBoxRaw::Bool(b),
            SyncValueBox::Int(i) => SyncValueBoxRaw::Int(i),
            SyncValueBox::Bitmap(i) => SyncValueBoxRaw::Bitmap(i),
            SyncValueBox::Float(f) => SyncValueBoxRaw::Float(f),
            SyncValueBox::Text(s) => SyncValueBoxRaw::Text(s),
            SyncValueBox::Blob(b) => SyncValueBoxRaw::Blob(b),
            SyncValueBox::Uuid(u) => SyncValueBoxRaw::Uuid(u),
            SyncValueBox::Timestamp(t) => SyncValueBoxRaw::Timestamp(t),
            SyncValueBox::Json(b) => SyncValueBoxRaw::Json(b),
            SyncValueBox::Hlc(h) => SyncValueBoxRaw::Hlc(h),
            SyncValueBox::Fingerprint(f) => SyncValueBoxRaw::Fingerprint(f),
            SyncValueBox::Array(items) => {
                SyncValueBoxRaw::Array(items.into_iter().map(SyncValueBoxRaw::from).collect())
            }
        }
    }
}

/// One TypedValue case, encoded with a discriminator. Mirrors
/// Swift's SyncValueBox.
///
/// Serialize and Deserialize are implemented manually (not derived) to
/// enforce `SYNC_VALUE_BOX_MAX_ARRAY_DEPTH` on both paths. The JSON
/// wire format is identical to what `#[derive]` would produce — the
/// private `SyncValueBoxRaw` mirror carries the serde derive attributes
/// and is used to produce/consume JSON.
#[derive(Debug, Clone)]
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

impl SyncValueBox {
    /// Returns the deepest array nesting level.
    ///
    /// Non-array values → 0. `Array([scalars])` → 1.
    /// `Array([Array([scalars])])` → 2. Etc.
    /// Used by the depth cap on both Serialize and Deserialize.
    pub fn array_nesting_depth(&self) -> u8 {
        match self {
            SyncValueBox::Array(items) => {
                let child_max = items.iter()
                    .map(|i| i.array_nesting_depth())
                    .max()
                    .unwrap_or(0);
                1u8.saturating_add(child_max)
            }
            _ => 0,
        }
    }
}

impl Serialize for SyncValueBox {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        // Depth cap: refuse to encode arrays nested deeper than the maximum.
        // A local bug that produces deep nesting should fail loudly at encode
        // rather than ship a payload that peers will reject on decode.
        let depth = self.array_nesting_depth();
        if depth > SYNC_VALUE_BOX_MAX_ARRAY_DEPTH {
            return Err(serde::ser::Error::custom(format!(
                "SyncValueBox array nesting depth {} exceeds maximum {} (CVK-WC5). \
                 LocusKit usage is ≤2; depth >{} is adversarial or corrupt input.",
                depth, SYNC_VALUE_BOX_MAX_ARRAY_DEPTH, SYNC_VALUE_BOX_MAX_ARRAY_DEPTH
            )));
        }
        SyncValueBoxRaw::from(self.clone()).serialize(s)
    }
}

impl<'de> Deserialize<'de> for SyncValueBox {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        // Deserialize via the derived mirror (serde handles the tagged format).
        // After conversion, validate depth — reject rather than accept or crash.
        let raw = SyncValueBoxRaw::deserialize(d)?;
        let val = SyncValueBox::from(raw);
        let depth = val.array_nesting_depth();
        if depth > SYNC_VALUE_BOX_MAX_ARRAY_DEPTH {
            return Err(serde::de::Error::custom(format!(
                "SyncValueBox array nesting depth {} exceeds maximum {} (CVK-WC5). \
                 Counted as per-record conflict; record rejected, no crash.",
                depth, SYNC_VALUE_BOX_MAX_ARRAY_DEPTH
            )));
        }
        Ok(val)
    }
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

/// Per-column HLC map for the `fieldLevelLWW` conflict policy (B-8, v1.2-draft).
///
/// Stores one `PackedHLC` per column name. Wire format:
/// `{"entries": {"col": {"physicalTime":…,"logicalCount":…,"nodeID":…}}}`.
///
/// WHY `BTreeMap` (not `HashMap`):
/// `BTreeMap` serialises keys in alphabetical order, producing deterministic
/// JSON output regardless of insertion order. This guarantees byte-identical
/// encoding between multiple serialisation passes and between Swift
/// (which also sorts dictionary keys alphabetically via `JSONEncoder`'s
/// default key encoding) and Rust. Byte-level parity is required by C-8.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ColumnHLCMap {
    pub entries: BTreeMap<String, PackedHLC>,
}

impl ColumnHLCMap {
    pub fn new() -> Self {
        ColumnHLCMap {
            entries: BTreeMap::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Merge two ColumnHLCMaps, keeping the highest HLC per column.
    /// Commutative: `a.merge(&b)` and `b.merge(&a)` produce the same result.
    pub fn merge(&self, other: &ColumnHLCMap) -> ColumnHLCMap {
        let mut result = self.entries.clone();
        for (column, other_hlc) in &other.entries {
            let entry = result.entry(column.clone()).or_insert(*other_hlc);
            // Keep the higher HLC. PackedHLC fields are ordered: physicalTime,
            // logicalCount, nodeID — same lexicographic order as Swift's Comparable.
            let packed_other = other_hlc;
            if packed_other.physical_time > entry.physical_time
                || (packed_other.physical_time == entry.physical_time
                    && packed_other.logical_count > entry.logical_count)
                || (packed_other.physical_time == entry.physical_time
                    && packed_other.logical_count == entry.logical_count
                    && packed_other.node_id > entry.node_id)
            {
                *entry = *other_hlc;
            }
        }
        ColumnHLCMap { entries: result }
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
/// JSON contract: camelCase field names matching Swift's property names.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncRecord {
    pub table: String,
    pub event: SyncEventKind,
    pub row_key: Uuid,
    pub values: Option<SyncValueMap>,
    pub hlc: PackedHLC,
    pub schema_version: i32,
    /// Serializes as "kitID" to match Swift's property name (not "kitId").
    #[serde(rename = "kitID")]
    pub kit_id: String,
    /// Set to `true` when this record represents a delete tombstone.
    ///
    /// WHY: explicit tombstone flag signals that the deletion HLC must
    /// persist in the `_fed_sync_meta` side table after the row is
    /// hard-deleted (A6 adjudication), preventing stale resurrections.
    /// Matches Swift's `syncDeleted: Bool?` field (C-8 wire parity).
    ///
    /// Omitted from JSON when None (`skip_serializing_if`); decoded as
    /// None when absent in older wire format (`default`).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub sync_deleted: Option<bool>,

    /// Per-column HLC map for the `fieldLevelLWW` conflict policy (B-8, v1.2-draft).
    ///
    /// WHY wire-carried (A7): the sender knows which columns were written and at
    /// which HLC. The receiver must not derive column HLCs from the row-grain HLC.
    ///
    /// Nil when `conflict_policy != fieldLevelLWW` or sender does not support
    /// field-level LWW (backward-compat). Omitted from JSON when None (C-8 parity).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub column_hlcs: Option<ColumnHLCMap>,
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
            sync_deleted: None,
            column_hlcs: None,
        }
    }

    /// Construct a tombstone record for a delete event.
    ///
    /// A tombstone carries the delete HLC so the receiver can apply the
    /// same LWW gate as for upserts and persist the HLC in the side table
    /// after hard-deleting the row (A6 adjudication).
    pub fn new_tombstone(
        table: impl Into<String>,
        row_key: Uuid,
        hlc: HLC,
        schema_version: i32,
        kit_id: impl Into<String>,
    ) -> Self {
        SyncRecord {
            table: table.into(),
            event: SyncEventKind::Delete,
            row_key,
            values: None,
            hlc: PackedHLC::from(hlc),
            schema_version,
            kit_id: kit_id.into(),
            sync_deleted: Some(true),
            column_hlcs: None,
        }
    }
}
