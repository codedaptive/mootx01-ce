// src/primitives/merkle_commitment_spike.rs
//
// The NT-P0 bakeoff's Merkle/commitment byte contract, vendored into the
// harness as harness-local support code. Rust twin of the Swift recovery
// (MerkleCommitmentSpike.swift, 296a4c74).
//
// Provenance: this contract arrived with the bakeoff as a SubstrateKernel
// spike and was correctly deleted from the kernel (the PRODUCTION Merkle
// implementation is SubstrateLib merkle_hash.rs / MerkleHash.swift, NT-F2)
// — but the CE Rust harness primitive (merkle_commitment.rs) arrived via
// the EE 06-29 SHARED mirror still importing the EE kernel's
// `substrate_kernel::merkle_commitment`, a module that never existed in
// the CE kernel, leaving this package uncompilable. The Swift harness got
// its vendored copy in 296a4c74; this module completes the recovery for
// Rust: the bakeoff contract belongs to the bakeoff tooling, not to the
// substrate.
//
// The byte contract is identical to production merkle_hash (leaf layout,
// domain tags, interior sort, empty root) — the bakeoff is where that
// contract was ratified — so the checked-in vectors/merkle_commitment.json
// remain valid unchanged.
//
// Hashing uses the in-repo substrate_kernel::sha256; keyed commitments
// reuse substrate_kernel::hkdf::hmac so there is only one HMAC-SHA256
// construction in play — mirroring the Swift spike's SHA256/GrantHKDF use.

use substrate_kernel::{hkdf, sha256};
use substrate_types::content_hash::ContentHash;
use substrate_types::merkle_domain::MerkleDomain;
use substrate_types::MerkleRoot;

/// Borrowed vector record for the canonical leaf payload. Mirrors the
/// Swift spike's `MerkleVectorPayload` (borrowed here because the harness
/// builds records over slices it already owns).
pub struct MerkleVectorPayload<'a> {
    pub model_id: &'a str,
    pub vector_index: u32,
    pub values: &'a [f32],
}

impl<'a> MerkleVectorPayload<'a> {
    pub fn new(model_id: &'a str, vector_index: u32, values: &'a [f32]) -> Self {
        Self { model_id, vector_index, values }
    }
}

/// One child of an interior node: raw 16-byte big-endian UUID + its root.
pub struct MerkleChild {
    pub child_id: [u8; 16],
    pub root: MerkleRoot,
}

impl MerkleChild {
    pub fn new(child_id: [u8; 16], root: MerkleRoot) -> Self {
        Self { child_id, root }
    }
}

/// Harness-local stand-in for the spike-era `KeyedCommitment` type.
/// Carries exactly what the harness consumers read: the 32-byte HMAC
/// (`wire_bytes`/`as_bytes`) and the producing key version. Mirrors the
/// Swift spike's `MerkleKeyedCommitment`.
pub struct MerkleKeyedCommitment {
    wire: [u8; 32],
    pub key_version: u32,
}

impl MerkleKeyedCommitment {
    pub fn wire_bytes(&self) -> [u8; 32] {
        self.wire
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.wire
    }
}

/// Canonical leaf bytes (bakeoff contract, byte-identical to production
/// canonical_leaf_bytes):
///
/// 1. leaf domain tag (0x00)
/// 2. drawer UUID raw 16-byte big-endian form
/// 3. u64 big-endian byte length + content bytes (the caller supplies
///    already-normalized UTF-8; no NFC pass happens here, matching the
///    Swift spike's byte-level overload)
/// 4. u32 big-endian vector record count
/// 5. vector records sorted by (model_id UTF-8 bytes, vector_index),
///    each as u32 BE model_id length | model_id bytes | u32 BE
///    vector_index | u32 BE value count | IEEE-754 LE float bytes
pub fn canonical_leaf_payload(
    drawer_id: [u8; 16],
    content: &[u8],
    vectors: &[MerkleVectorPayload<'_>],
) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(1 + 16 + 8 + content.len() + 4);
    bytes.push(MerkleDomain::LEAF);
    bytes.extend_from_slice(&drawer_id);
    bytes.extend_from_slice(&(content.len() as u64).to_be_bytes());
    bytes.extend_from_slice(content);

    let mut order: Vec<usize> = (0..vectors.len()).collect();
    order.sort_by(|&a, &b| {
        vectors[a]
            .model_id
            .as_bytes()
            .cmp(vectors[b].model_id.as_bytes())
            .then(vectors[a].vector_index.cmp(&vectors[b].vector_index))
    });
    bytes.extend_from_slice(&(vectors.len() as u32).to_be_bytes());
    for i in order {
        let v = &vectors[i];
        let model_bytes = v.model_id.as_bytes();
        bytes.extend_from_slice(&(model_bytes.len() as u32).to_be_bytes());
        bytes.extend_from_slice(model_bytes);
        bytes.extend_from_slice(&v.vector_index.to_be_bytes());
        bytes.extend_from_slice(&(v.values.len() as u32).to_be_bytes());
        for value in v.values {
            bytes.extend_from_slice(&value.to_bits().to_le_bytes());
        }
    }
    bytes
}

/// SHA-256 over a canonical leaf payload. The payload must carry the
/// leaf domain tag (it was built by `canonical_leaf_payload`).
pub fn hash_leaf_payload(payload: &[u8]) -> ContentHash {
    assert_eq!(
        payload.first(),
        Some(&MerkleDomain::LEAF),
        "leaf payload must start with the leaf domain tag"
    );
    ContentHash::new(sha256::hash(payload))
}

/// Interior root: INTERIOR tag plus child roots in ascending child-id
/// byte order.
pub fn interior_root(children: &[MerkleChild]) -> MerkleRoot {
    let mut order: Vec<usize> = (0..children.len()).collect();
    order.sort_by(|&a, &b| children[a].child_id.cmp(&children[b].child_id));

    let mut payload = Vec::with_capacity(1 + children.len() * 32);
    payload.push(MerkleDomain::INTERIOR);
    for i in order {
        payload.extend_from_slice(children[i].root.bytes());
    }
    MerkleRoot::new(sha256::hash(&payload))
}

/// Tombstone hash: TOMBSTONE tag (0x02) + drawer id 16B BE.
pub fn tombstone_hash(drawer_id: [u8; 16]) -> ContentHash {
    let mut payload = Vec::with_capacity(17);
    payload.push(MerkleDomain::TOMBSTONE);
    payload.extend_from_slice(&drawer_id);
    ContentHash::new(sha256::hash(&payload))
}

/// Empty-subtree root: SHA-256 over the bare INTERIOR domain tag. Equal
/// by construction to `MerkleRoot::EMPTY` (whose literal a kernel bridge
/// test pins to this same computation); computed here so the harness
/// validates the derivation, not the literal.
pub fn empty_root() -> MerkleRoot {
    MerkleRoot::new(sha256::hash(&[MerkleDomain::INTERIOR]))
}

/// HMAC-SHA256 commitment over a canonical leaf payload with the
/// COMMITMENT domain tag (0x03) prepended.
pub fn keyed_commitment_for_canonical_leaf_payload(
    payload: &[u8],
    key: &[u8],
    key_version: u32,
) -> MerkleKeyedCommitment {
    assert_eq!(
        payload.first(),
        Some(&MerkleDomain::LEAF),
        "keyed commitment input must be a canonical leaf payload"
    );
    let mut committed = Vec::with_capacity(1 + payload.len());
    committed.push(MerkleDomain::COMMITMENT);
    committed.extend_from_slice(payload);
    MerkleKeyedCommitment { wire: hkdf::hmac(key, &committed), key_version }
}

/// Spike-era spelling compatibility: the bakeoff-era consumer file
/// (merkle_commitment.rs) calls `.wire_bytes()` / `.as_bytes()` on
/// MerkleRoot and ContentHash; the production types (post-NT-F2) spell
/// the accessor `.bytes()`. This trait keeps the consumer verbatim to
/// its recorded bakeoff form — the Rust analogue of the Swift spike's
/// `extension MerkleRoot { var wireBytes … }`.
pub trait SpikeWireBytes {
    fn wire_bytes(&self) -> [u8; 32];
    fn as_bytes(&self) -> &[u8; 32];
}

impl SpikeWireBytes for MerkleRoot {
    fn wire_bytes(&self) -> [u8; 32] {
        *self.bytes()
    }
    fn as_bytes(&self) -> &[u8; 32] {
        self.bytes()
    }
}

impl SpikeWireBytes for ContentHash {
    fn wire_bytes(&self) -> [u8; 32] {
        *self.bytes()
    }
    fn as_bytes(&self) -> &[u8; 32] {
        self.bytes()
    }
}
