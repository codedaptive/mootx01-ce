// keyed_commitment.rs
//
// Public keyed-commitment API for expunge provenance (ADR-017 §17).
//
// Computes HMAC-SHA256 over the canonical leaf payload bytes (the same
// encoding merkle_hash::leaf uses), keyed by an estate-held secret.
// Domain-separated from the plain leaf hash by the COMMITMENT tag 0x03
// (vs LEAF 0x00).
//
// Reuses substrate_kernel::hkdf::hmac (the existing HMAC-SHA256) —
// no new HMAC implementation.
//
// Mirror: SubstrateLib/Sources/SubstrateLib/KeyedCommitment.swift —
// conformance-gated byte-identical.

use std::collections::HashMap;

use substrate_kernel::hkdf;
use substrate_kernel::sha256;
use substrate_types::hlc::HLC;
use substrate_types::merkle_domain::MerkleDomain;

use crate::merkle_hash::{canonical_leaf_bytes, MerkleVectorInput};

/// The output of a keyed commitment: HMAC bytes + key version.
///
/// Carried in the expunge provenance audit entry and in
/// snapshot_attestations.key_version.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct KeyedCommitmentValue {
    /// 32-byte HMAC-SHA256 output.
    pub hmac_bytes: [u8; 32],
    /// The key version that produced this commitment.
    pub key_version: i64,
}

impl KeyedCommitmentValue {
    pub fn new(hmac_bytes: [u8; 32], key_version: i64) -> Self {
        Self { hmac_bytes, key_version }
    }

    /// Lowercase hex string of the HMAC bytes.
    pub fn hex_string(&self) -> String {
        self.hmac_bytes.iter().map(|b| format!("{:02x}", b)).collect()
    }
}

/// Compute a keyed commitment over a drawer's content and vectors.
///
/// The HMAC input is the canonical leaf payload bytes (the same
/// encoding merkle_hash::leaf uses) but with the COMMITMENT domain
/// tag 0x03 instead of the LEAF tag 0x00.
///
/// `drawer_id` is the 16-byte big-endian UUID representation (RFC 4122).
pub fn commit(
    key: &[u8],
    key_version: i64,
    drawer_id: &[u8; 16],
    content: &[u8],
    vectors: &[MerkleVectorInput],
) -> KeyedCommitmentValue {
    let payload = canonical_leaf_bytes(
        drawer_id,
        content,
        vectors,
        MerkleDomain::COMMITMENT,
    );
    let hmac = hkdf::hmac(key, &payload);
    KeyedCommitmentValue::new(hmac, key_version)
}

/// One immutable entry in the commitment audit log.
///
/// Records that a keyed commitment was made at expunge time, proving
/// the payload existed without retaining a reversible fingerprint of
/// destroyed personal data.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct KeyedCommitmentAuditEntry {
    /// Deterministic content hash (32-byte SHA-256) over the entry's
    /// identifying fields, used as the G-Set key for deduplication.
    pub id: [u8; 32],
    /// The drawer whose payload was committed before expunge.
    pub drawer_id: [u8; 16],
    /// The HMAC commitment value (HMAC bytes + key version).
    pub commitment: KeyedCommitmentValue,
    /// The HLC at which the tombstone was applied.
    pub tombstone_hlc: HLC,
    /// Human-readable reason for the expunge.
    pub reason: String,
}

impl KeyedCommitmentAuditEntry {
    pub fn new(
        drawer_id: [u8; 16],
        commitment: KeyedCommitmentValue,
        tombstone_hlc: HLC,
        reason: String,
    ) -> Self {
        let id = Self::compute_id(&drawer_id, &commitment, &tombstone_hlc, &reason);
        Self { id, drawer_id, commitment, tombstone_hlc, reason }
    }

    /// Deterministic content ID so two replicas producing the same
    /// logical commitment entry produce identical IDs and the G-Set
    /// deduplicates them.
    fn compute_id(
        drawer_id: &[u8; 16],
        commitment: &KeyedCommitmentValue,
        tombstone_hlc: &HLC,
        reason: &str,
    ) -> [u8; 32] {
        let mut bytes: Vec<u8> = Vec::new();
        // Drawer id: 16 bytes.
        bytes.extend_from_slice(drawer_id);
        // HMAC bytes: 32 bytes.
        bytes.extend_from_slice(&commitment.hmac_bytes);
        // Key version: 8 bytes big-endian.
        bytes.extend_from_slice(&(commitment.key_version as u64).to_be_bytes());
        // Tombstone HLC wire bytes.
        bytes.extend_from_slice(&tombstone_hlc.wire_bytes());
        // Reason: UTF-8 with NUL terminator.
        bytes.extend_from_slice(reason.as_bytes());
        bytes.push(0);
        sha256::hash(&bytes)
    }
}

/// Grow-only set for keyed-commitment audit entries.
///
/// Mirrors the GSetAuditLog pattern: entries can be added but never
/// removed. Two replicas merge their sets via set union and converge
/// regardless of message order.
pub struct CommitmentAuditLog {
    /// Backing store keyed by content hash for O(1) dedupe.
    entries: HashMap<[u8; 32], KeyedCommitmentAuditEntry>,
}

impl CommitmentAuditLog {
    pub fn new() -> Self {
        Self { entries: HashMap::new() }
    }

    /// Add a single entry. Idempotent: re-adding an entry with the
    /// same content hash is a no-op.
    pub fn add(&mut self, entry: KeyedCommitmentAuditEntry) {
        self.entries.entry(entry.id).or_insert(entry);
    }

    /// CRDT join. Merging two logs is set union of entries.
    pub fn merge(&mut self, other: &CommitmentAuditLog) {
        for (id, entry) in &other.entries {
            self.entries.entry(*id).or_insert_with(|| entry.clone());
        }
    }

    pub fn count(&self) -> usize {
        self.entries.len()
    }

    /// All entries in tombstone-HLC order.
    pub fn ordered_entries(&self) -> Vec<&KeyedCommitmentAuditEntry> {
        let mut v: Vec<&KeyedCommitmentAuditEntry> = self.entries.values().collect();
        v.sort_by(|a, b| a.tombstone_hlc.cmp(&b.tombstone_hlc));
        v
    }

    /// Entries for a specific drawer.
    pub fn entries_for_drawer(&self, drawer_id: &[u8; 16]) -> Vec<&KeyedCommitmentAuditEntry> {
        let mut v: Vec<&KeyedCommitmentAuditEntry> = self.entries.values()
            .filter(|e| &e.drawer_id == drawer_id)
            .collect();
        v.sort_by(|a, b| a.tombstone_hlc.cmp(&b.tombstone_hlc));
        v
    }
}

impl Default for CommitmentAuditLog {
    fn default() -> Self { Self::new() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::merkle_hash;

    fn test_uuid_bytes() -> [u8; 16] {
        [0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x12, 0x34,
         0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc]
    }

    #[test]
    fn commitment_deterministic() {
        let key = [0xAB; 32];
        let id = test_uuid_bytes();
        let c1 = commit(&key, 1, &id, b"hello", &[]);
        let c2 = commit(&key, 1, &id, b"hello", &[]);
        assert_eq!(c1.hmac_bytes, c2.hmac_bytes, "commitment must be deterministic");
        assert_eq!(c1.key_version, 1);
    }

    #[test]
    fn domain_separation_commitment_vs_leaf() {
        let key = [0xAB; 32];
        let id = test_uuid_bytes();
        let commitment = commit(&key, 1, &id, b"data", &[]);
        let content_hash = merkle_hash::leaf(&id, b"data", &[]);
        assert_ne!(
            commitment.hmac_bytes.as_slice(),
            content_hash.bytes().as_slice(),
            "commitment and content hash must differ (domain separation + HMAC vs SHA256)"
        );
    }

    #[test]
    fn different_key_different_commitment() {
        let id = test_uuid_bytes();
        let c1 = commit(&[0x01; 32], 1, &id, b"data", &[]);
        let c2 = commit(&[0x02; 32], 1, &id, b"data", &[]);
        assert_ne!(c1.hmac_bytes, c2.hmac_bytes, "different key = different commitment");
    }

    #[test]
    fn key_version_preserved() {
        let id = test_uuid_bytes();
        let c = commit(&[0xAB; 32], 42, &id, b"data", &[]);
        assert_eq!(c.key_version, 42);
    }

    #[test]
    fn commitment_with_vectors() {
        let key = [0xAB; 32];
        let id = test_uuid_bytes();
        let vecs = vec![
            MerkleVectorInput::new("model-a".into(), 0, vec![1.0, 2.0]),
        ];
        let c1 = commit(&key, 1, &id, b"content", &vecs);
        let c2 = commit(&key, 1, &id, b"content", &vecs);
        assert_eq!(c1, c2, "deterministic with vectors");

        let c3 = commit(&key, 1, &id, b"content", &[]);
        assert_ne!(c1, c3, "vectors change the commitment");
    }

    #[test]
    fn audit_entry_round_trip() {
        let id = test_uuid_bytes();
        let commitment = commit(&[0xAB; 32], 1, &id, b"expunged data", &[]);
        let hlc = HLC::new(1_000_000, 1, 42);
        let entry = KeyedCommitmentAuditEntry::new(
            id, commitment.clone(), hlc, "GDPR request #12345".into(),
        );

        let mut log = CommitmentAuditLog::new();
        log.add(entry.clone());
        assert_eq!(log.count(), 1);

        let entries = log.entries_for_drawer(&id);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].drawer_id, id);
        assert_eq!(entries[0].commitment, commitment);
        assert_eq!(entries[0].tombstone_hlc, hlc);
        assert_eq!(entries[0].reason, "GDPR request #12345");
    }

    #[test]
    fn audit_entry_idempotent_add() {
        let id = test_uuid_bytes();
        let commitment = commit(&[0xAB; 32], 1, &id, b"", &[]);
        let hlc = HLC::new(1_000_000, 1, 42);
        let entry = KeyedCommitmentAuditEntry::new(
            id, commitment, hlc, "test".into(),
        );

        let mut log = CommitmentAuditLog::new();
        log.add(entry.clone());
        log.add(entry);
        assert_eq!(log.count(), 1, "re-adding same entry is a no-op");
    }

    #[test]
    fn audit_entry_merge_logs() {
        let id = test_uuid_bytes();
        let c1 = commit(&[0xAB; 32], 1, &id, b"a", &[]);
        let c2 = commit(&[0xAB; 32], 1, &id, b"b", &[]);
        let hlc1 = HLC::new(1_000_000, 1, 42);
        let hlc2 = HLC::new(2_000_000, 1, 42);

        let mut log1 = CommitmentAuditLog::new();
        log1.add(KeyedCommitmentAuditEntry::new(id, c1, hlc1, "first".into()));

        let mut log2 = CommitmentAuditLog::new();
        log2.add(KeyedCommitmentAuditEntry::new(id, c2, hlc2, "second".into()));

        log1.merge(&log2);
        assert_eq!(log1.count(), 2, "merged log has entries from both");
    }

    #[test]
    fn audit_entry_deterministic_id() {
        let id = test_uuid_bytes();
        let commitment = commit(&[0xAB; 32], 1, &id, b"", &[]);
        let hlc = HLC::new(1_000_000, 1, 42);
        let e1 = KeyedCommitmentAuditEntry::new(id, commitment.clone(), hlc, "test".into());
        let e2 = KeyedCommitmentAuditEntry::new(id, commitment, hlc, "test".into());
        assert_eq!(e1.id, e2.id, "same fields = same deterministic ID");
        // Cross-port conformance vector: Swift must produce the same ID.
        let expected = "8a0cbc8846dcdbd7d60032f55278bbc3ef5aa5575c584d248036d46e08c0a7c6";
        let hex: String = e1.id.iter().map(|b| format!("{:02x}", b)).collect();
        assert_eq!(hex, expected, "cross-port conformance: content-ID must match Swift");
    }

    #[test]
    fn audit_entry_ordered_entries() {
        let id = test_uuid_bytes();
        let c1 = commit(&[0xAB; 32], 1, &id, b"a", &[]);
        let c2 = commit(&[0xAB; 32], 1, &id, b"b", &[]);
        let hlc_early = HLC::new(1_000_000, 1, 42);
        let hlc_late = HLC::new(2_000_000, 1, 42);

        let mut log = CommitmentAuditLog::new();
        // Add later entry first.
        log.add(KeyedCommitmentAuditEntry::new(id, c2, hlc_late, "late".into()));
        log.add(KeyedCommitmentAuditEntry::new(id, c1, hlc_early, "early".into()));

        let ordered = log.ordered_entries();
        assert_eq!(ordered[0].reason, "early");
        assert_eq!(ordered[1].reason, "late");
    }
}
