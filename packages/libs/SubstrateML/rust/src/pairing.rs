// pairing.rs
//
// Pairing handshake per cookbook § 12.2. Mirror of
// glref-swift-PairingHandshake.swift.
//
// Five-step protocol: nonce exchange, deterministic shared-family
// generation, family commit, initial audit-log sync, audit event.

use substrate_types::hlc::HLC;
use substrate_types::hyperplane::HyperplaneFamily;
use crate::tier_contribution::FederationCase;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingNonce {
    pub bytes: [u8; 32],
}

impl PairingNonce {
    pub fn new(bytes: [u8; 32]) -> Self {
        Self { bytes }
    }

    /// Derive the SplitMix64 seed for shared-family generation by
    /// mixing the nonce with the lower estate UUID. Both estates
    /// compute identically.
    pub fn seed_with(&self, estate_a: [u8; 16], estate_b: [u8; 16]) -> u64 {
        let lower = if estate_a <= estate_b { estate_a } else { estate_b };
        let mut h: u64 = 0xCBF29CE484222325;
        for b in &self.bytes {
            h ^= *b as u64;
            h = h.wrapping_mul(0x100000001B3);
        }
        for b in &lower {
            h ^= *b as u64;
            h = h.wrapping_mul(0x100000001B3);
        }
        h
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingRecord {
    pub peer_estate: [u8; 16],
    pub federation_case: FederationCase,
    pub shared_family_key: String,
    pub paired_at: HLC,
    pub dissolved_at: Option<HLC>,
    pub last_sync_at: HLC,
}

impl PairingRecord {
    pub fn is_active(&self) -> bool {
        self.dissolved_at.is_none()
    }
}

pub struct PairingHandshake;

impl PairingHandshake {
    /// Generate the shared 4-block hyperplane family set
    /// deterministically from the pairing nonce. Cookbook § 12.2:
    /// both estates derive identical families from the same nonce
    /// + estate-uuid-pair, so federation OR-reductions across the
    /// pair are bit-comparable.
    pub fn generate_shared_family(nonce: &PairingNonce,
                                  estate_a: [u8; 16],
                                  estate_b: [u8; 16],
                                  density: f64) -> [HyperplaneFamily; 4] {
        // Both estates derive the same base from the nonce and the
        // estate-UUID pair, then the canonical block_families routine
        // diversifies it per block and applies the canonical widths
        // [192, 64, 64, 64]. The same routine builds the estate-local
        // families, so the shared and local constructions cannot drift.
        let base = HyperplaneFamily::expand_seed_64(nonce.seed_with(estate_a, estate_b));
        HyperplaneFamily::block_families(&base, density)
    }

    /// Canonical manifest key: H_shared_<case>_<peer_uuid_short>.
    pub fn shared_family_key(federation_case: FederationCase, peer_estate: &[u8; 16]) -> String {
        let case_name = match federation_case {
            FederationCase::Household => "household",
            FederationCase::Fleet     => "fleet",
            FederationCase::Industry  => "industry",
        };
        let short = format!("{:02x}{:02x}{:02x}{:02x}",
                            peer_estate[0], peer_estate[1], peer_estate[2], peer_estate[3]);
        format!("H_shared_{}_{}", case_name, short)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingAuditPayload {
    pub mutation_kind: String,            // "pair" | "unpair"
    pub peer_estate: [u8; 16],
    pub federation_case: FederationCase,
    pub shared_family_hash: u64,
    pub hlc: HLC,
}

impl PairingHandshake {
    pub fn build_pair_event(peer_estate: [u8; 16],
                            federation_case: FederationCase,
                            families: &[HyperplaneFamily; 4],
                            hlc: HLC) -> PairingAuditPayload {
        PairingAuditPayload {
            mutation_kind: "pair".to_string(),
            peer_estate,
            federation_case,
            shared_family_hash: combined_family_hash(families),
            hlc,
        }
    }

    pub fn build_unpair_event(peer_estate: [u8; 16],
                              federation_case: FederationCase,
                              families: &[HyperplaneFamily; 4],
                              hlc: HLC) -> PairingAuditPayload {
        PairingAuditPayload {
            mutation_kind: "unpair".to_string(),
            peer_estate,
            federation_case,
            shared_family_hash: combined_family_hash(families),
            hlc,
        }
    }
}

/// Expand a 64-bit seed to 32 bytes via 4 rounds of SplitMix64-
/// style avalanche. Deterministic; same input → same bytes.

/// Canonical hash over the 4-family set: FNV-1a-mix the per-family
/// `canonical_hash()` outputs in block_index order.
fn combined_family_hash(families: &[HyperplaneFamily; 4]) -> u64 {
    let mut h: u64 = 0xCBF29CE484222325;
    for f in families {
        let part = f.canonical_hash();
        for b in part.to_be_bytes() {
            h ^= b as u64;
            h = h.wrapping_mul(0x100000001B3);
        }
    }
    h
}

#[cfg(test)]
mod shared_family_tests {
    use super::*;

    fn nonce() -> PairingNonce {
        let mut b = [0u8; 32];
        for i in 0..32 { b[i] = i as u8; }
        PairingNonce::new(b)
    }
    fn estate_a() -> [u8; 16] { [0x11u8; 16] }
    fn estate_b() -> [u8; 16] { [0x22u8; 16] }

    #[test]
    fn shared_family_has_canonical_widths() {
        let fams = PairingHandshake::generate_shared_family(&nonce(), estate_a(), estate_b(), 1.0);
        let widths: Vec<usize> = fams.iter().map(|f| f.input_bit_length).collect();
        assert_eq!(widths, vec![192, 64, 64, 64]);
    }

    #[test]
    fn shared_family_blocks_are_distinct() {
        let fams = PairingHandshake::generate_shared_family(&nonce(), estate_a(), estate_b(), 1.0);
        let mut hashes: Vec<u64> = fams.iter().map(|f| f.canonical_hash()).collect();
        hashes.sort();
        hashes.dedup();
        assert_eq!(hashes.len(), 4, "the four shared families must be distinct");
    }

    #[test]
    fn shared_family_is_order_independent() {
        let ab = PairingHandshake::generate_shared_family(&nonce(), estate_a(), estate_b(), 1.0);
        let ba = PairingHandshake::generate_shared_family(&nonce(), estate_b(), estate_a(), 1.0);
        let h_ab: Vec<u64> = ab.iter().map(|f| f.canonical_hash()).collect();
        let h_ba: Vec<u64> = ba.iter().map(|f| f.canonical_hash()).collect();
        assert_eq!(h_ab, h_ba);
    }

    #[test]
    fn diversified_seeds_differ_per_block() {
        let base = [7u8; 32];
        let seeds: Vec<[u8; 32]> =
            (0..4).map(|b| HyperplaneFamily::diversified_seed(&base, b)).collect();
        for i in 0..4 {
            for j in (i + 1)..4 {
                assert_ne!(seeds[i], seeds[j], "blocks {} and {} share a seed", i, j);
            }
        }
    }
}
