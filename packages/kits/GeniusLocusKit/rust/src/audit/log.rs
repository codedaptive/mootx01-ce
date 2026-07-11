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
// docs/engineering/HARNESS_REFERENCE.md. If you
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

// NOTE (RUST-AUDIT-DURABILITY, 2026-07-09): Swift's `UnifiedAuditVerb`
// also carries `keyDecayed`/`physicalKeyDecayed` — key-custody
// placeholders (GLK-03, DECISION_FEDERATION_SHARING_MODEL Appendix B)
// added ahead of the federation mechanics themselves shipping. Rust
// still does not carry those 2 cases; bringing Rust to parity with
// those two placeholders remains out of scope (no writer emits them on
// either port yet). `GrantIssued`/`GrantRevoked`, however, are now
// carried below: the FUP-C / GLK-03 grant-lifecycle seam
// (`EstateCoordinator::issue_grant` / `revoke_grant`) durably appends
// these two verbs, mirroring Swift's `appendGrantAuditEntry`
// (VerbSurface.swift). Previously (through AUDIT-TRAIL-RESTORE-GRANTS,
// 2026-07-09) Rust carried neither grantIssued nor grantRevoked and
// `sensitivity_audit_verbs.rs` documented their absence as "nothing to
// accidentally reuse" — see that test file's
// `grant_verbs_never_collide_with_sensitivity_verbs` for the now-live
// parity check.
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

    // FUP-C / GLK-03 grant-lifecycle verbs. Federation-reserved — see the
    // Swift `UnifiedAuditLog.swift` doc comment. Deliberately distinct
    // from the ADR-025 sensitivity-unlock verbs below even though both
    // are "synthetic" (non-drawer-scoped) entries sharing the same
    // encode/decode convention (`SyntheticAuditValueCodec`, hydration.rs).
    GrantIssued,
    GrantRevoked,

    // ADR-025 sensitivity-unlock verbs (2026-07-04, amended 2026-07-04).
    // Deliberately NOT the federation grantIssued/grantRevoked — see the
    // Swift `UnifiedAuditLog.swift` doc comment for why those are a
    // different concern. No expiry verb: expiry is passive (the issued
    // record's `after_value` carries its own expiry timestamp; ADR-025
    // §4).
    SensitivityGrantIssued,
    SensitivityGrantDenied,
    SensitivityGrantRevoked,
    SensitivityReadUnderGrant,
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
            // Raw strings match Swift's `String` rawValue exactly —
            // camelCase, same spelling as the Swift enum case names.
            UnifiedAuditVerb::GrantIssued => "grantIssued",
            UnifiedAuditVerb::GrantRevoked => "grantRevoked",
            UnifiedAuditVerb::SensitivityGrantIssued => "sensitivityGrantIssued",
            UnifiedAuditVerb::SensitivityGrantDenied => "sensitivityGrantDenied",
            UnifiedAuditVerb::SensitivityGrantRevoked => "sensitivityGrantRevoked",
            UnifiedAuditVerb::SensitivityReadUnderGrant => "sensitivityReadUnderGrant",
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

    /// Returns `true` if this entry's `id` matches the SHA-256 of its
    /// canonical wire encoding — i.e., the entry is self-consistent.
    ///
    /// Reuses the existing `wire_bytes` + `sha256` path that
    /// `UnifiedAuditEntry::new` uses, so the verification is
    /// byte-identical to the construction. A legitimate locally-produced
    /// entry always passes; an externally-supplied entry whose `id` was
    /// crafted to collide with a different entry fails.
    ///
    /// Called on every ingress path in `UnifiedAuditLog` (add, merge)
    /// as the structural defence against same-id/different-content CRDT
    /// forgery (codex a477800).
    fn content_id_matches(&self) -> bool {
        let bytes = Self::wire_bytes(
            self.tier,
            self.hlc,
            self.verb,
            self.row_id,
            &self.field_path,
            &self.before_value,
            &self.after_value,
            self.origin_row_id,
        );
        sha256(&bytes) == self.id
    }
}

// MARK: - G-Set log

/// Grow-only set of `UnifiedAuditEntry`. Set union, idempotent add.
/// Wire-shape parity with the Swift reference.
///
/// `Eq`/`PartialEq` are hand-written below (not derived) so `rejected_count`
/// stays out of structural equality — see the `impl PartialEq` doc.
#[derive(Clone, Debug, Default)]
pub struct UnifiedAuditLog {
    entries: BTreeMap<[u8; 32], UnifiedAuditEntry>,
    /// Count of entries rejected on THIS log's ingress (`add` calls that
    /// failed the content-id check) since the log was constructed.
    ///
    /// AUDIT-ALERT-RESTORE (2026-07-09, Bob's option-1 ruling): mirrors
    /// the Swift `UnifiedAuditLog.rejectedEntryCount`. Every `add` call
    /// that rejects an entry increments it, regardless of which caller
    /// invoked `add` (directly, via `with_entries`, or via `merge`).
    /// Monotonic for the lifetime of this value; NOT part of the CRDT
    /// state (excluded from `PartialEq`); not carried across `merge` —
    /// merging only re-adds entries that already survived the source
    /// log's own ingress, so a source log's rejections are not
    /// double-counted into the destination log.
    rejected_count: usize,
}

impl UnifiedAuditLog {
    pub fn new() -> Self {
        Self {
            entries: BTreeMap::new(),
            rejected_count: 0,
        }
    }

    pub fn with_entries<I: IntoIterator<Item = UnifiedAuditEntry>>(entries: I) -> Self {
        let mut log = Self::new();
        for e in entries {
            log.add(e);
        }
        log
    }

    /// Add a single entry. Idempotent for honest entries.
    ///
    /// Security (codex a477800): the entry's SHA-256 content id is
    /// recomputed from its wire encoding before insertion. If the
    /// recomputed id does not match `entry.id`, the entry is rejected,
    /// `rejected_count` is incremented, and the entry is not inserted.
    /// This prevents a peer supplying a forged (same-id, different-
    /// content) entry from overwriting an honest one in the G-Set,
    /// which would break CRDT convergence and constitute audit forgery.
    /// Federation peer-log merge relies on this defence; any future
    /// non-local audit ingress must route through `add` or `merge` to
    /// obtain it.
    pub fn add(&mut self, entry: UnifiedAuditEntry) {
        if !entry.content_id_matches() {
            // Entry rejected: recomputed id does not match entry.id.
            // Legitimate entries always pass because new() computes
            // the id from the same wire_bytes path used here.
            self.rejected_count += 1;
            return;
        }
        self.entries.insert(entry.id, entry);
    }

    /// Number of entries rejected at ingress on this log instance. See the
    /// `rejected_count` field doc for the AUDIT-ALERT-RESTORE rationale.
    pub fn rejected_count(&self) -> usize {
        self.rejected_count
    }

    /// CRDT join. Merging two G-Sets is set union over entry IDs.
    ///
    /// FEDERATION BOUNDARY NOTE: This method is the structural gate
    /// that future federation peer-log merge relies on. Every entry
    /// from a peer-supplied log must route through `merge` (or `add`)
    /// to obtain the content-id verification. Do not add alternative
    /// ingress paths that bypass this check.
    ///
    /// Routes each entry through `add` so the content-id verification
    /// is applied uniformly on every ingress path (codex a477800).
    pub fn merge(&mut self, other: &UnifiedAuditLog) {
        for (_, entry) in &other.entries {
            self.add(entry.clone());  // validated ingress — forged entries dropped
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

/// Structural equality over the G-Set only. `rejected_count` is
/// deliberately excluded: it is per-ingress-operation telemetry, not CRDT
/// state, and including it would break the convergence property tests
/// rely on (two logs holding the same entries must compare equal
/// regardless of how many rejected-entry `add` calls either one happened
/// to observe on the way there). Mirrors the Swift `UnifiedAuditLog`'s
/// custom `==`.
impl PartialEq for UnifiedAuditLog {
    fn eq(&self, other: &Self) -> bool {
        self.entries == other.entries
    }
}

impl Eq for UnifiedAuditLog {}

// Content-hash facade for audit entries. F18.3 (2026-05-27): the
// self-contained SHA-256 that lived here was removed in favor of the
// canonical `substrate_kernel::sha256` (FIPS 180-4, NIST-vector gated).
// The free-function name is kept so call sites and the audit_parity
// re-export are unchanged; the math is centralized in the substrate.
pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    substrate_kernel::sha256::hash(bytes)
}
