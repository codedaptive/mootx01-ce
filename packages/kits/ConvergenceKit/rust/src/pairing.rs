//! Federation pairing value types (paper section 9.2). Two estates
//! share a hyperplane family so their 256-bit fingerprints are directly
//! comparable across the federation.
//!
//! This module defines the Codable proposal/acceptance types and a
//! canonical byte helper. It does not implement negotiation, signing,
//! or verification; those are caller responsibilities.

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

/// JSON contract: camelCase field names matching Swift's property names.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingProposal {
    /// 32-byte Ed25519 public key.
    pub proposer_public_key: Vec<u8>,
    pub proposed_family: HyperplaneFamilySpec,
    pub nonce: Vec<u8>,
}

/// JSON contract: camelCase field names matching Swift's property names.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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
/// are explicit here. There is no Swift proposal-signing-bytes
/// helper to mirror; the Swift types are Codable value types only.
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
