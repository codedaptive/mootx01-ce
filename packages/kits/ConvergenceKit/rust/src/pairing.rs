//! Federation pairing types. Pairing handshake per paper section
//! 9.2. Two estates negotiate a shared hyperplane family so
//! their 256-bit fingerprints are directly comparable across the
//! federation.
//!
//! For v1.0 the handshake exchanges family parameters (seed +
//! dimension) signed by each peer's Ed25519 key.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct HyperplaneFamilySpec {
    pub seed: u64,
    pub dimension: u32,
}

impl HyperplaneFamilySpec {
    pub fn new(seed: u64) -> Self {
        HyperplaneFamilySpec { seed, dimension: 256 }
    }

    pub fn with_dimension(seed: u64, dimension: u32) -> Self {
        HyperplaneFamilySpec { seed, dimension }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairingProposal {
    /// 32-byte Ed25519 public key.
    pub proposer_public_key: Vec<u8>,
    pub proposed_family: HyperplaneFamilySpec,
    pub nonce: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairingAcceptance {
    /// 32-byte Ed25519 public key.
    pub accepter_public_key: Vec<u8>,
    pub accepted_family: HyperplaneFamilySpec,
    /// Ed25519 signature over the canonical encoding of the
    /// proposal (proposer_public_key + family.seed + family.dimension + nonce).
    pub signature_of_proposal: Vec<u8>,
}

/// Canonical byte encoding of a PairingProposal for signing.
/// Both peers MUST produce the same bytes; ordering and width
/// are explicit here. Mirrors the Swift convention.
pub fn proposal_signing_bytes(proposal: &PairingProposal) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(
        proposal.proposer_public_key.len() + 8 + 4 + proposal.nonce.len(),
    );
    bytes.extend_from_slice(&proposal.proposer_public_key);
    bytes.extend_from_slice(&proposal.proposed_family.seed.to_le_bytes());
    bytes.extend_from_slice(&proposal.proposed_family.dimension.to_le_bytes());
    bytes.extend_from_slice(&proposal.nonce);
    bytes
}
