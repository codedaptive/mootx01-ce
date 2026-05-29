// gset.rs
//
// Grow-only set CRDT audit log per cookbook § 5.1.
//
// The audit log is the substrate's source of truth. Visible
// drawer state is a projection over the log; the log itself is
// append-only and CRDT-merge-safe.
//
// G-Set (grow-only set) semantics: entries can be added but
// never removed. Two replicas merge their G-Sets via set union
// and converge to the same state regardless of message order
// (cookbook § 5.4 convergence proof).
//
// Each entry carries:
//   - HLC timestamp (cookbook § 5.2) for total ordering
//   - Verb (cookbook § 10) saying what mutation occurred
//   - Row ID + before/after field deltas
//   - Provenance (origin of the mutation)
//
// CRDT join operator: set union over entries keyed by
// (hlc, verb, row_id, field_path). Idempotent because identical
// entries deduplicate; commutative and associative because set
// union is. Projection over the joined set is deterministic
// because HLC gives a total order to apply entries.

use std::collections::HashMap;

use crate::hlc::HLC;
use crate::fingerprint256::Fingerprint256;

/// The nine cookbook verbs (§ 10) plus migration / system verbs.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde-support", serde(rename_all = "camelCase"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AuditVerb {
    Capture,
    Mutate,
    Retract,
    Sync,
    Pair,
    Unpair,
    Derive,
    Decay,
    Promote,
    Migrate,        // schema migration (cookbook § 16)
    DreamCompact,   // dreaming-daemon § 15 compaction
}

/// Typed audit value. Fields can be bitmaps (u64), strings,
/// fingerprints, or integers. F16.B (2026-05-27): the previous
/// `Null` variant was removed in favor of `Option<AuditValue>`
/// at the AuditEntry level — `None` represents the capture /
/// retract boundary semantics that `Null` formerly carried.
///
/// Wire format (under `serde-support`): externally-tagged
/// single-key object with camelCase variant names. Examples:
///
///   {"bitmap": 42}
///   {"string": "hello"}
///   {"fingerprint": {"block0": 1, ...}}
///   {"integer": -1}
///
/// Mirrors the Swift custom Codable in GSetAuditLog.swift.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde-support", serde(rename_all = "camelCase"))]
#[derive(Debug, Clone, PartialEq)]
pub enum AuditValue {
    Bitmap(u64),
    String(String),
    Fingerprint(Fingerprint256),
    Integer(i64),
}

/// Row identifier — 128-bit UUID.
pub type RowID = u128;

/// One immutable entry in the audit log.
///
/// `id` is a deterministic content hash: SHA-256 over the wire
/// encoding of (hlc, verb, row_id, field_path, before_value,
/// after_value, origin_row_id). Two replicas producing the same
/// logical mutation produce identical IDs and the G-Set
/// deduplicates them.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, PartialEq)]
pub struct AuditEntry {
    pub id: [u8; 32],
    pub hlc: HLC,
    pub verb: AuditVerb,
    #[cfg_attr(feature = "serde-support",
               serde(rename = "rowID", with = "row_id_uuid"))]
    pub row_id: RowID,
    #[cfg_attr(feature = "serde-support", serde(rename = "fieldPath"))]
    pub field_path: String,            // e.g. "adjective.state"
    #[cfg_attr(feature = "serde-support", serde(rename = "beforeValue"))]
    pub before_value: Option<AuditValue>,
    #[cfg_attr(feature = "serde-support", serde(rename = "afterValue"))]
    pub after_value: Option<AuditValue>,
    #[cfg_attr(feature = "serde-support",
               serde(rename = "originRowID", with = "row_id_uuid_option",
                     skip_serializing_if = "Option::is_none", default))]
    pub origin_row_id: Option<RowID>,
}

/// G-Set audit log. Pure CRDT semantics: only `add` and `merge`
/// mutate; everything else reads.
///
/// F16.B (2026-05-27) wire format under `serde-support`:
/// `{"entries": [<AuditEntry>, ...]}` — array sorted by `id`
/// byte-lex for determinism. The internal HashMap keying is an
/// O(1)-dedup optimization and is not part of the wire format;
/// mirrors Swift's custom Codable in GSetAuditLog.swift.
#[derive(Debug, Clone, Default)]
pub struct GSetAuditLog {
    /// Backing store keyed by content hash for O(1) dedupe.
    entries: HashMap<[u8; 32], AuditEntry>,
}

#[cfg(feature = "serde-support")]
impl serde::Serialize for GSetAuditLog {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut sorted: Vec<&AuditEntry> = self.entries.values().collect();
        sorted.sort_by(|a, b| a.id.cmp(&b.id));
        let mut state = s.serialize_struct("GSetAuditLog", 1)?;
        state.serialize_field("entries", &sorted)?;
        state.end()
    }
}

#[cfg(feature = "serde-support")]
impl<'de> serde::Deserialize<'de> for GSetAuditLog {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(serde::Deserialize)]
        struct Helper {
            entries: Vec<AuditEntry>,
        }
        let h = Helper::deserialize(d)?;
        let mut entries: HashMap<[u8; 32], AuditEntry> = HashMap::new();
        for e in h.entries {
            entries.insert(e.id, e);
        }
        Ok(GSetAuditLog { entries })
    }
}

// MARK: - RowID UUID-string serde helpers
//
// Swift's `UUID` type Codable encodes as an UPPERCASE hyphenated
// UUID string (e.g. "550E8400-E29B-41D4-A716-446655440000"). The
// SubstrateLib Rust mirror uses `pub type RowID = u128`; we
// can't impl traits directly on the alias, so attach the
// conversion via `#[serde(with = "row_id_uuid")]` on every
// AuditEntry field that carries a RowID.
//
// The conversion treats the u128 as 16 big-endian bytes and
// formats / parses them in the canonical 8-4-4-4-12 hex layout,
// matching Swift's output exactly (uppercase hex).

#[cfg(feature = "serde-support")]
mod row_id_uuid {
    use super::RowID;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(id: &RowID, s: S) -> Result<S::Ok, S::Error> {
        let b = id.to_be_bytes();
        let uuid_str = format!(
            "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
        );
        s.serialize_str(&uuid_str)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<RowID, D::Error> {
        let s = String::deserialize(d)?;
        parse_uuid(&s).map_err(serde::de::Error::custom)
    }

    pub(super) fn parse_uuid(s: &str) -> Result<RowID, String> {
        let hex_only: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
        if hex_only.len() != 32 {
            return Err(format!(
                "UUID must be 32 hex chars after dash removal, got {}",
                hex_only.len()
            ));
        }
        let mut bytes = [0u8; 16];
        for i in 0..16 {
            bytes[i] = u8::from_str_radix(&hex_only[i*2..(i+1)*2], 16)
                .map_err(|_| "invalid hex in UUID".to_string())?;
        }
        Ok(u128::from_be_bytes(bytes))
    }
}

#[cfg(feature = "serde-support")]
mod row_id_uuid_option {
    use super::RowID;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(id: &Option<RowID>, s: S) -> Result<S::Ok, S::Error> {
        match id {
            Some(v) => super::row_id_uuid::serialize(v, s),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<RowID>, D::Error> {
        let opt = Option::<String>::deserialize(d)?;
        match opt {
            Some(s) => Ok(Some(
                super::row_id_uuid::parse_uuid(&s).map_err(serde::de::Error::custom)?,
            )),
            None => Ok(None),
        }
    }
}

impl GSetAuditLog {
    pub fn new() -> Self {
        Self { entries: HashMap::new() }
    }

    pub fn from_entries(entries: Vec<AuditEntry>) -> Self {
        let mut log = Self::new();
        for e in entries {
            log.add(e);
        }
        log
    }

    /// Add a single entry. Idempotent: re-adding an entry with
    /// the same content hash is a no-op.
    pub fn add(&mut self, entry: AuditEntry) {
        self.entries.insert(entry.id, entry);
    }

    /// CRDT join. Merging two G-Sets is set union of entries.
    /// Commutative, associative, idempotent — the three CRDT
    /// properties that guarantee convergence.
    pub fn merge(&mut self, other: &GSetAuditLog) {
        for (id, entry) in &other.entries {
            self.entries.insert(*id, entry.clone());
        }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// All entries in HLC order. Projection (cookbook § 5.3)
    /// applies these to a fresh state to compute the visible
    /// estate.
    pub fn ordered_entries(&self) -> Vec<AuditEntry> {
        let mut v: Vec<AuditEntry> = self.entries.values().cloned().collect();
        v.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        v
    }

    /// Entries scoped to a single row, in HLC order. Drives the
    /// row-state automaton (cookbook § 9).
    pub fn entries_for_row(&self, row_id: RowID) -> Vec<AuditEntry> {
        let mut v: Vec<AuditEntry> = self.entries.values()
            .filter(|e| e.row_id == row_id)
            .cloned()
            .collect();
        v.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        v
    }

    /// Entries since a given HLC, exclusive. Used by the sync
    /// protocol to ship the delta to a peer.
    pub fn entries_since(&self, cutoff: &HLC) -> Vec<AuditEntry> {
        let mut v: Vec<AuditEntry> = self.entries.values()
            .filter(|e| e.hlc > *cutoff)
            .cloned()
            .collect();
        v.sort_by(|a, b| a.hlc.cmp(&b.hlc));
        v
    }
}

// Convergence proof sketch (cookbook § 5.4)
//
// Lemma: For any two replicas R1 and R2 of an estate with audit
// logs G1 and G2, after exchanging messages until quiescent, both
// hold identical state.
//
// Proof:
//   1. G-Set merge is set union of entries by content hash.
//   2. Set union is commutative, associative, and idempotent.
//   3. After quiescence, G1 = G2 = G1 ∪ G2 (every entry from
//      either replica is in both, dedupes by id).
//   4. Projection over G is deterministic: ordered_entries yields
//      a total HLC order, applied left-to-right to a fresh state.
//   5. Two replicas projecting the same G in the same order
//      produce the same state.   ∎
//
// The proof relies on three properties of HLC:
//   - causality:  if A causally precedes B, HLC(A) < HLC(B)
//   - total order: any two HLCs compare unambiguously
//   - stable seed: estate manifest fixes node IDs at creation,
//                  making the tiebreaker stable across replicas

#[cfg(test)]
mod tests {
    use super::*;

    fn make_entry(id_byte: u8, physical_time: i64, node_id: i32,
                  row_id: RowID) -> AuditEntry {
        AuditEntry {
            id: [id_byte; 32],
            hlc: HLC::new(physical_time, 0, node_id),
            verb: AuditVerb::Capture,
            row_id,
            field_path: "test.field".to_string(),
            before_value: None,
            after_value: Some(AuditValue::Integer(42)),
            origin_row_id: None,
        }
    }

    #[test]
    fn add_is_idempotent() {
        let mut log = GSetAuditLog::new();
        let e = make_entry(0xAA, 1000, 1, 1);
        log.add(e.clone());
        log.add(e.clone());
        assert_eq!(log.len(), 1);
    }

    #[test]
    fn merge_is_commutative() {
        let e1 = make_entry(0x01, 1000, 1, 1);
        let e2 = make_entry(0x02, 2000, 2, 1);

        let mut a = GSetAuditLog::from_entries(vec![e1.clone()]);
        let b = GSetAuditLog::from_entries(vec![e2.clone()]);

        let mut a_then_b = a.clone();
        a_then_b.merge(&b);

        let mut b_then_a = b.clone();
        b_then_a.merge(&a);

        assert_eq!(a_then_b.len(), b_then_a.len());
        assert_eq!(a_then_b.ordered_entries(), b_then_a.ordered_entries());
    }

    #[test]
    fn merge_is_idempotent() {
        let e = make_entry(0x05, 1000, 1, 1);
        let mut log = GSetAuditLog::from_entries(vec![e]);
        let copy = log.clone();
        log.merge(&copy);
        assert_eq!(log.len(), 1);
    }

    #[test]
    fn ordered_entries_are_hlc_sorted() {
        let e1 = make_entry(0x01, 3000, 1, 1);
        let e2 = make_entry(0x02, 1000, 1, 1);
        let e3 = make_entry(0x03, 2000, 1, 1);
        let log = GSetAuditLog::from_entries(vec![e1, e2, e3]);
        let ordered = log.ordered_entries();
        assert_eq!(ordered[0].hlc.physical_time, 1000);
        assert_eq!(ordered[1].hlc.physical_time, 2000);
        assert_eq!(ordered[2].hlc.physical_time, 3000);
    }

    #[test]
    fn entries_since_excludes_cutoff() {
        let e1 = make_entry(0x01, 1000, 1, 1);
        let e2 = make_entry(0x02, 2000, 1, 1);
        let e3 = make_entry(0x03, 3000, 1, 1);
        let log = GSetAuditLog::from_entries(vec![e1, e2, e3]);
        let cutoff = HLC::new(2000, 0, 1);
        let since = log.entries_since(&cutoff);
        assert_eq!(since.len(), 1);
        assert_eq!(since[0].hlc.physical_time, 3000);
    }
}
