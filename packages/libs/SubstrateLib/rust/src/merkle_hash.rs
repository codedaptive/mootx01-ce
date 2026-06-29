// merkle_hash.rs
//
// Public hash pipeline for the Merkle content-integrity tree (ADR-017 §16).
//
// Three functions: leaf (drawer content + vectors), interior (subtree of
// children), tombstone (expunged payload). All three use
// substrate_kernel::sha256::hash — no new hash implementation.
//
// Domain-separated by MerkleDomain tags (0x00 leaf, 0x01 interior,
// 0x02 tombstone) prepended before hashing.
//
// The canonical byte encoding for leaf payloads is shared with
// keyed_commitment (§17): one encoding, two uses.
//
// Mirror: SubstrateLib/Sources/SubstrateLib/MerkleHash.swift —
// conformance-gated byte-identical.

use substrate_kernel::sha256;
use substrate_types::content_hash::ContentHash;
use substrate_types::merkle_domain::MerkleDomain;
use substrate_types::merkle_root::MerkleRoot;

/// Lightweight vector input for the hash pipeline.
///
/// substrate-lib cannot depend on vectorkit (dependency inversion), so
/// this struct captures the fields needed to serialize vectors into the
/// canonical byte format per ADR-017 §16.
#[derive(Debug, Clone)]
pub struct MerkleVectorInput {
    /// The embedding model identifier, used for sort ordering.
    pub model_id: String,
    /// Multi-vector index (0 for single-vector models).
    pub vector_index: u32,
    /// IEEE-754 float32 coefficients.
    pub floats: Vec<f32>,
}

impl MerkleVectorInput {
    pub fn new(model_id: String, vector_index: u32, floats: Vec<f32>) -> Self {
        Self { model_id, vector_index, floats }
    }
}

/// Hash a drawer's content and vectors into a ContentHash.
///
/// Canonical byte format per ADR-017 §16 v2:
/// - MerkleDomain::LEAF (0x00)
/// - drawer id: 16 bytes big-endian UUID
/// - content: u64 BE length prefix + raw caller-supplied bytes
///   (no UTF-8 validation or NFC normalization is performed here)
/// - vectors: u32 BE count prefix, then each vector sorted by
///   (model_id ascending, vector_index ascending) with per-vector layout:
///   u32 BE model_id-length | model_id UTF-8 bytes | u32 BE vector_index |
///   u32 BE float-count | IEEE-754 LE floats
///
/// The v2 layout writes vector identity into the preimage before the float
/// payload. v1 used model_id/vector_index only for sort order — a binding
/// gap allowing vector substitution without hash mismatch (WS2-F4).
///
/// `drawer_id` is the 16-byte big-endian UUID representation (RFC 4122).
pub fn leaf(drawer_id: &[u8; 16], content: &[u8], vectors: &[MerkleVectorInput]) -> ContentHash {
    let payload = canonical_leaf_bytes(drawer_id, content, vectors, MerkleDomain::LEAF);
    ContentHash::new(sha256::hash(&payload))
}

/// Hash a node's children into a MerkleRoot.
///
/// Children are sorted by UUID ascending (lexicographic over the
/// 16-byte big-endian representation) to make the roll-up
/// independent of write order.
///
/// Returns `MerkleRoot::EMPTY` when child_hashes is empty.
pub fn interior(child_hashes: &[([u8; 16], ContentHash)]) -> MerkleRoot {
    if child_hashes.is_empty() {
        return MerkleRoot::EMPTY;
    }

    // Sort by UUID ascending — lexicographic over 16-byte BE.
    let mut sorted: Vec<_> = child_hashes.to_vec();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));

    let mut payload = vec![MerkleDomain::INTERIOR];
    for (_, hash) in &sorted {
        payload.extend_from_slice(hash.bytes());
    }
    MerkleRoot::new(sha256::hash(&payload))
}

/// Hash a node's child MerkleRoots into a parent MerkleRoot.
///
/// Used at wing and estate levels where children already carry
/// MerkleRoots (not ContentHashes). Same domain tag and sort order
/// as the ContentHash overload — the hash is over the raw 32-byte
/// values regardless of type wrapper.
///
/// Returns `MerkleRoot::EMPTY` when child_roots is empty.
pub fn interior_roots(child_roots: &[([u8; 16], MerkleRoot)]) -> MerkleRoot {
    if child_roots.is_empty() {
        return MerkleRoot::EMPTY;
    }

    let mut sorted: Vec<_> = child_roots.to_vec();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));

    let mut payload = vec![MerkleDomain::INTERIOR];
    for (_, root) in &sorted {
        payload.extend_from_slice(root.bytes());
    }
    MerkleRoot::new(sha256::hash(&payload))
}

/// Hash a tombstoned drawer into a ContentHash.
///
/// Canonical format: MerkleDomain::TOMBSTONE (0x02) + drawer id 16B BE.
/// No content, no vectors — they are destroyed by expunge.
pub fn tombstone(drawer_id: &[u8; 16]) -> ContentHash {
    let mut payload = vec![MerkleDomain::TOMBSTONE];
    payload.extend_from_slice(drawer_id);
    ContentHash::new(sha256::hash(&payload))
}

/// Build the canonical leaf payload bytes per ADR-017 §16 v2.
///
/// Shared between `leaf` (domain tag 0x00) and
/// `keyed_commitment::commit` (domain tag 0x03) — one encoding,
/// two uses. The v2 format writes vector identity (model_id + vector_index)
/// into the preimage before the float payload, binding the vector's
/// provenance to the hash. This prevents vector substitution attacks
/// where swapping vectors of the same dimension would not change the
/// leaf hash (security finding WS2-F4, fixed 2026-06-28).
///
/// Per-vector layout (v2):
///   u32 BE model_id-length | model_id UTF-8 bytes | u32 BE vector_index |
///   u32 BE float-count | IEEE-754 LE floats
pub(crate) fn canonical_leaf_bytes(
    drawer_id: &[u8; 16],
    content: &[u8],
    vectors: &[MerkleVectorInput],
    domain_tag: u8,
) -> Vec<u8> {
    let mut bytes = vec![domain_tag];

    // Drawer id: 16 bytes big-endian UUID.
    bytes.extend_from_slice(drawer_id);

    // Content: u64 BE length prefix + UTF-8 bytes.
    bytes.extend_from_slice(&(content.len() as u64).to_be_bytes());
    bytes.extend_from_slice(content);

    // Vectors: sorted by (model_id ascending, vector_index ascending).
    let mut sorted: Vec<_> = vectors.to_vec();
    sorted.sort_by(|a, b| {
        a.model_id.cmp(&b.model_id)
            .then(a.vector_index.cmp(&b.vector_index))
    });

    // u32 BE count prefix: number of vectors.
    bytes.extend_from_slice(&(sorted.len() as u32).to_be_bytes());

    for v in &sorted {
        // v2 per-vector layout: write identity BEFORE floats so that
        // substituting a different model's embedding changes the hash.
        // model_id: u32 BE length prefix + UTF-8 bytes.
        let model_id_bytes = v.model_id.as_bytes();
        bytes.extend_from_slice(&(model_id_bytes.len() as u32).to_be_bytes());
        bytes.extend_from_slice(model_id_bytes);
        // vector_index: u32 BE (multi-vector slot; 0 for single-vector models).
        bytes.extend_from_slice(&v.vector_index.to_be_bytes());
        // Float payload: u32 BE float count, then IEEE-754 LE floats.
        bytes.extend_from_slice(&(v.floats.len() as u32).to_be_bytes());
        for &f in &v.floats {
            // IEEE-754 single-precision, little-endian per ADR-017 §16.
            bytes.extend_from_slice(&f.to_le_bytes());
        }
    }

    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The test UUID bytes (12345678-1234-1234-1234-123456789abc) in
    /// RFC 4122 big-endian form — matches Swift's `withUnsafeBytes(of: uuid.uuid)`.
    fn test_uuid_bytes() -> [u8; 16] {
        [0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x12, 0x34,
         0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc]
    }

    #[test]
    fn leaf_empty_content_no_vectors() {
        let id = test_uuid_bytes();
        let hash = leaf(&id, b"", &[]);
        let hash2 = leaf(&id, b"", &[]);
        assert_eq!(hash, hash2, "deterministic");
        let ts = tombstone(&id);
        assert_ne!(hash, ts, "leaf and tombstone must differ (domain separation)");
    }

    #[test]
    fn leaf_with_content() {
        let id = test_uuid_bytes();
        let hash1 = leaf(&id, b"hello world", &[]);
        let hash2 = leaf(&id, b"hello world", &[]);
        assert_eq!(hash1, hash2, "deterministic");

        let hash3 = leaf(&id, b"different", &[]);
        assert_ne!(hash1, hash3, "different content = different hash");
    }

    #[test]
    fn leaf_with_vectors() {
        let id = test_uuid_bytes();
        let vecs = vec![
            MerkleVectorInput::new("model-a".into(), 0, vec![1.0, 2.0, 3.0]),
            MerkleVectorInput::new("model-a".into(), 1, vec![4.0, 5.0, 6.0]),
        ];
        let hash = leaf(&id, b"content", &vecs);
        let hash2 = leaf(&id, b"content", &vecs);
        assert_eq!(hash, hash2, "deterministic with vectors");
    }

    #[test]
    fn leaf_vector_sort_order_independent() {
        let id = test_uuid_bytes();
        let v1 = vec![
            MerkleVectorInput::new("model-b".into(), 0, vec![1.0]),
            MerkleVectorInput::new("model-a".into(), 0, vec![2.0]),
        ];
        let v2 = vec![
            MerkleVectorInput::new("model-a".into(), 0, vec![2.0]),
            MerkleVectorInput::new("model-b".into(), 0, vec![1.0]),
        ];
        assert_eq!(
            leaf(&id, b"x", &v1),
            leaf(&id, b"x", &v2),
            "vector sort order must not affect hash"
        );
    }

    #[test]
    fn interior_empty_returns_empty_constant() {
        let root = interior(&[]);
        assert_eq!(root, MerkleRoot::EMPTY);
    }

    #[test]
    fn interior_deterministic() {
        let id1 = [0xaa; 16];
        let id2 = [0xbb; 16];
        let h1 = ContentHash::new([0x11; 32]);
        let h2 = ContentHash::new([0x22; 32]);

        let root1 = interior(&[(id1, h1), (id2, h2)]);
        let root2 = interior(&[(id2, h2), (id1, h1)]);
        assert_eq!(root1, root2, "interior hash must be order-independent");
    }

    #[test]
    fn tombstone_deterministic() {
        let id = test_uuid_bytes();
        let ts1 = tombstone(&id);
        let ts2 = tombstone(&id);
        assert_eq!(ts1, ts2, "tombstone must be deterministic");

        let other = [0x99; 16];
        let ts3 = tombstone(&other);
        assert_ne!(ts1, ts3, "different drawer id = different tombstone hash");
    }

    #[test]
    fn interior_roots_empty_returns_empty_constant() {
        let root = interior_roots(&[]);
        assert_eq!(root, MerkleRoot::EMPTY);
    }

    #[test]
    fn interior_roots_deterministic() {
        let id1 = [0xaa; 16];
        let id2 = [0xbb; 16];
        let r1 = MerkleRoot::new([0x11; 32]);
        let r2 = MerkleRoot::new([0x22; 32]);

        let root1 = interior_roots(&[(id1, r1), (id2, r2)]);
        let root2 = interior_roots(&[(id2, r2), (id1, r1)]);
        assert_eq!(root1, root2, "interior_roots hash must be order-independent");
    }

    #[test]
    fn interior_and_interior_roots_produce_same_hash_for_same_bytes() {
        let id1 = [0xaa; 16];
        let id2 = [0xbb; 16];
        let bytes1 = [0x11; 32];
        let bytes2 = [0x22; 32];

        let from_content = interior(&[(id1, ContentHash::new(bytes1)), (id2, ContentHash::new(bytes2))]);
        let from_roots = interior_roots(&[(id1, MerkleRoot::new(bytes1)), (id2, MerkleRoot::new(bytes2))]);
        assert_eq!(
            from_content.bytes(), from_roots.bytes(),
            "same raw bytes must produce the same hash regardless of type wrapper"
        );
    }

    #[test]
    fn domain_separation_leaf_vs_interior() {
        let id = test_uuid_bytes();
        let hash = leaf(&id, b"", &[]);
        let root = interior(&[(id, hash)]);
        assert_ne!(hash.bytes().as_slice(), root.bytes().as_slice());
    }

    // WS2-F4 security regression tests — v2 identity binding.
    // These tests verify that the v2 canonical leaf encoding binds vector
    // identity (model_id + vector_index) into the preimage, so swapping a
    // vector from a different model or slot changes the leaf hash.

    #[test]
    fn v2_binding_model_id_changes_hash() {
        // Same floats, different model_id — must produce different hash.
        let id = test_uuid_bytes();
        let h1 = leaf(
            &id,
            b"test",
            &[MerkleVectorInput::new("model-a".into(), 0, vec![1.0, 2.0, 3.0])],
        );
        let h2 = leaf(
            &id,
            b"test",
            &[MerkleVectorInput::new("model-b".into(), 0, vec![1.0, 2.0, 3.0])],
        );
        assert_ne!(
            h1, h2,
            "v2 identity binding: same floats with different model_id must change the hash"
        );
    }

    #[test]
    fn v2_binding_vector_index_changes_hash() {
        // Same floats, same model_id, different vector_index — must produce different hash.
        let id = test_uuid_bytes();
        let h1 = leaf(
            &id,
            b"test",
            &[MerkleVectorInput::new("model-a".into(), 0, vec![1.0, 2.0, 3.0])],
        );
        let h2 = leaf(
            &id,
            b"test",
            &[MerkleVectorInput::new("model-a".into(), 1, vec![1.0, 2.0, 3.0])],
        );
        assert_ne!(
            h1, h2,
            "v2 identity binding: same floats with different vector_index must change the hash"
        );
    }

    #[test]
    fn v2_cross_port_conformance_vector() {
        // Pinned SHA-256 of v2 canonical leaf encoding for the shared
        // cross-port conformance vector. Both Rust and Swift must produce
        // this exact value. Seed: drawer 12345678-1234-1234-1234-123456789abc,
        // content "hello", one vector model-a/idx=0/[1.0, 2.0].
        //
        // Derivation (v2 layout):
        //   domain tag: 0x00
        //   drawer id: 12 34 56 78 12 34 12 34 12 34 12 34 56 78 9a bc
        //   content len: 00 00 00 00 00 00 00 05
        //   content: 68 65 6c 6c 6f
        //   vector count: 00 00 00 01
        //   model_id len: 00 00 00 07
        //   model_id: 6d 6f 64 65 6c 2d 61
        //   vector_index: 00 00 00 00
        //   float count: 00 00 00 02
        //   float[0] 1.0f: 00 00 80 3f (LE)
        //   float[1] 2.0f: 00 00 00 40 (LE)
        let id = test_uuid_bytes();
        // Pinned hash value: SHA-256 of v2 preimage described above.
        // Identical to Swift test v2BindingCrossPortConformanceVector — byte-identical
        // across ports is the conformance gate.
        let expected_hex = "cb18e8a5dcff4eb955f731bf75c078b9390a175ff225cc67a1ff0f1d3fa192dc";
        let hash = leaf(
            &id,
            b"hello",
            &[MerkleVectorInput::new("model-a".into(), 0, vec![1.0_f32, 2.0_f32])],
        );
        let hex: String = hash.bytes().iter().map(|b| format!("{:02x}", b)).collect();
        assert_eq!(
            hex, expected_hex,
            "v2 cross-port conformance vector mismatch — Swift and Rust must agree byte-for-byte"
        );
        // Print visible with `cargo test -- --nocapture` for external verification.
        println!("v2-conformance-leaf-hex: {}", hex);
    }
}
