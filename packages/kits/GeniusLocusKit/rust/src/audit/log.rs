// audit/log.rs — Unified audit log primitives (Rust mirror).
//
// The Swift reference is `UnifiedAuditLog.swift`. Every type, every
// field, every byte the content hash sees is identical to the Swift
// side; the parity tests assert equality via shared vectors.

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
use substrate_types::hlc::HLC;

// MARK: - Tier

/// Storage tier an audit entry originated from.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Ord, PartialOrd)]
pub enum AuditTier {
    Locus,
    Rag,
}

impl AuditTier {
    pub fn raw_value(&self) -> &'static str {
        match self {
            AuditTier::Locus => "locus",
            AuditTier::Rag => "rag",
        }
    }
}

// MARK: - Value

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub enum UnifiedAuditValue {
    Null,
    Bitmap(u64),
    Integer(i64),
    StringValue(String),
    Bytes(Vec<u8>),
}

impl UnifiedAuditValue {
    pub fn wire_bytes(&self) -> Vec<u8> {
        match self {
            UnifiedAuditValue::Null => vec![0x00],
            UnifiedAuditValue::Bitmap(v) => {
                let mut out = vec![0x01];
                out.extend_from_slice(&v.to_le_bytes());
                out
            }
            UnifiedAuditValue::Integer(v) => {
                let mut out = vec![0x02];
                out.extend_from_slice(&v.to_le_bytes());
                out
            }
            UnifiedAuditValue::StringValue(s) => {
                let mut out = vec![0x03];
                let bytes = s.as_bytes();
                let len = bytes.len() as u32;
                out.extend_from_slice(&len.to_le_bytes());
                out.extend_from_slice(bytes);
                out
            }
            UnifiedAuditValue::Bytes(b) => {
                let mut out = vec![0x04];
                let len = b.len() as u32;
                out.extend_from_slice(&len.to_le_bytes());
                out.extend_from_slice(b);
                out
            }
        }
    }
}

// MARK: - Verb

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum UnifiedAuditVerb {
    Capture,
    Recall,
    Mutate,
    Withdraw,
    Expunge,
    Reanchor,
    Learn,
    Propose,
    Associate,
    Migrate,
    DreamCompact,
}

impl UnifiedAuditVerb {
    pub fn raw_value(&self) -> &'static str {
        match self {
            UnifiedAuditVerb::Capture => "capture",
            UnifiedAuditVerb::Recall => "recall",
            UnifiedAuditVerb::Mutate => "mutate",
            UnifiedAuditVerb::Withdraw => "withdraw",
            UnifiedAuditVerb::Expunge => "expunge",
            UnifiedAuditVerb::Reanchor => "reanchor",
            UnifiedAuditVerb::Learn => "learn",
            UnifiedAuditVerb::Propose => "propose",
            UnifiedAuditVerb::Associate => "associate",
            UnifiedAuditVerb::Migrate => "migrate",
            UnifiedAuditVerb::DreamCompact => "dreamCompact",
        }
    }
}

// MARK: - UUID (16-byte newtype)

/// 16-byte UUID. Held as a fixed-length array so byte-for-byte
/// equality with the Swift `UUID.uuid` representation holds: Swift
/// addresses the UUID as `(UInt8 x 16)` and the content hash hashes
/// those bytes in the same order.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Ord, PartialOrd)]
pub struct EntryUUID(pub [u8; 16]);

// MARK: - Entry

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct UnifiedAuditEntry {
    pub id: [u8; 32],
    pub tier: AuditTier,
    pub hlc: HLC,
    pub verb: UnifiedAuditVerb,
    pub row_id: EntryUUID,
    pub field_path: String,
    pub before_value: UnifiedAuditValue,
    pub after_value: UnifiedAuditValue,
    pub origin_row_id: Option<EntryUUID>,
}

#[allow(clippy::too_many_arguments)] // wire-encoding functions require all fields; grouping would obscure the byte-identical contract
impl UnifiedAuditEntry {
    pub fn new(
        tier: AuditTier,
        hlc: HLC,
        verb: UnifiedAuditVerb,
        row_id: EntryUUID,
        field_path: impl Into<String>,
        before_value: UnifiedAuditValue,
        after_value: UnifiedAuditValue,
        origin_row_id: Option<EntryUUID>,
    ) -> Self {
        let field_path = field_path.into();
        let bytes = Self::wire_bytes(
            tier,
            hlc,
            verb,
            row_id,
            &field_path,
            &before_value,
            &after_value,
            origin_row_id,
        );
        let id = sha256(&bytes);
        Self {
            id,
            tier,
            hlc,
            verb,
            row_id,
            field_path,
            before_value,
            after_value,
            origin_row_id,
        }
    }

    /// Canonical wire-encoding bytes for the content hash. Byte-for-
    /// byte identical to the Swift `UnifiedAuditEntry.wireBytes`
    /// helper.
    fn wire_bytes(
        tier: AuditTier,
        hlc: HLC,
        verb: UnifiedAuditVerb,
        row_id: EntryUUID,
        field_path: &str,
        before_value: &UnifiedAuditValue,
        after_value: &UnifiedAuditValue,
        origin_row_id: Option<EntryUUID>,
    ) -> Vec<u8> {
        let mut out: Vec<u8> = Vec::new();
        out.extend_from_slice(tier.raw_value().as_bytes());
        out.push(0x1F);
        out.extend_from_slice(&hlc.wire_bytes());
        out.extend_from_slice(verb.raw_value().as_bytes());
        out.push(0x1F);
        out.extend_from_slice(&row_id.0);
        let path_bytes = field_path.as_bytes();
        let path_len = path_bytes.len() as u32;
        out.extend_from_slice(&path_len.to_le_bytes());
        out.extend_from_slice(path_bytes);
        out.extend_from_slice(&before_value.wire_bytes());
        out.extend_from_slice(&after_value.wire_bytes());
        match origin_row_id {
            Some(origin) => {
                out.push(0x01);
                out.extend_from_slice(&origin.0);
            }
            None => {
                out.push(0x00);
            }
        }
        out
    }

    fn ordering_key(&self) -> (HLC, &'static str, [u8; 32]) {
        (self.hlc, self.tier.raw_value(), self.id)
    }
}

// MARK: - G-Set log

/// Grow-only set of `UnifiedAuditEntry`. Set union, idempotent add.
/// Wire-shape parity with the Swift reference.
#[derive(Clone, Debug, Eq, PartialEq, Default)]
pub struct UnifiedAuditLog {
    entries: BTreeMap<[u8; 32], UnifiedAuditEntry>,
}

impl UnifiedAuditLog {
    pub fn new() -> Self {
        Self {
            entries: BTreeMap::new(),
        }
    }

    pub fn with_entries<I: IntoIterator<Item = UnifiedAuditEntry>>(entries: I) -> Self {
        let mut log = Self::new();
        for e in entries {
            log.add(e);
        }
        log
    }

    pub fn add(&mut self, entry: UnifiedAuditEntry) {
        self.entries.insert(entry.id, entry);
    }

    pub fn merge(&mut self, other: &UnifiedAuditLog) {
        for (id, entry) in &other.entries {
            self.entries.insert(*id, entry.clone());
        }
    }

    pub fn count(&self) -> usize {
        self.entries.len()
    }
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn ordered_entries(&self) -> Vec<UnifiedAuditEntry> {
        let mut entries: Vec<_> = self.entries.values().cloned().collect();
        entries.sort_by(|a, b| a.ordering_key().cmp(&b.ordering_key()));
        entries
    }

    pub fn entries_for_tier(&self, tier: AuditTier) -> Vec<UnifiedAuditEntry> {
        let mut entries: Vec<_> = self
            .entries
            .values()
            .filter(|e| e.tier == tier)
            .cloned()
            .collect();
        entries.sort_by(|a, b| a.ordering_key().cmp(&b.ordering_key()));
        entries
    }

    pub fn entries_for_row(&self, row_id: EntryUUID, tier: AuditTier) -> Vec<UnifiedAuditEntry> {
        let mut entries: Vec<_> = self
            .entries
            .values()
            .filter(|e| e.row_id == row_id && e.tier == tier)
            .cloned()
            .collect();
        entries.sort_by(|a, b| a.ordering_key().cmp(&b.ordering_key()));
        entries
    }

    pub fn entries_since(&self, cutoff: HLC) -> Vec<UnifiedAuditEntry> {
        let mut entries: Vec<_> = self
            .entries
            .values()
            .filter(|e| e.hlc > cutoff)
            .cloned()
            .collect();
        entries.sort_by(|a, b| a.ordering_key().cmp(&b.ordering_key()));
        entries
    }

    pub fn entries_as_of(&self, cutoff: HLC) -> Vec<UnifiedAuditEntry> {
        let mut entries: Vec<_> = self
            .entries
            .values()
            .filter(|e| e.hlc <= cutoff)
            .cloned()
            .collect();
        entries.sort_by(|a, b| a.ordering_key().cmp(&b.ordering_key()));
        entries
    }
}
// Content-hash facade for audit entries. F18.3 (2026-05-27): the
// self-contained SHA-256 that lived here was removed in favor of the
// canonical `substrate_kernel::sha256` (FIPS 180-4, NIST-vector gated).
// The free-function name is kept so call sites and the audit_parity
// re-export are unchanged; the math is centralized in the substrate.
pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    substrate_kernel::sha256::hash(bytes)
}
