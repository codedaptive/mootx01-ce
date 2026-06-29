// merkle_domain.rs
//
// Domain-separation byte constants from ADR-017 §16. These are
// the one-byte prefixes prepended before hashing to prevent
// cross-domain collisions in the Merkle content-integrity tree.
//
// Values are frozen by the NT-P0 reconciled bakeoff and
// conformance-pinned forever.

/// Domain-separation tags for the Merkle content-integrity tree.
///
/// Each tag is a one-byte prefix prepended before the payload
/// bytes when computing a hash, ensuring a leaf hash can never
/// collide with or be substituted for an interior hash.
///
/// These values are conformance-frozen — they MUST be identical
/// across Swift and Rust, and MUST NOT change after NT-P0.
pub struct MerkleDomain;

impl MerkleDomain {
    /// Leaf node: a single drawer's content + vectors.
    pub const LEAF: u8 = 0x00;

    /// Interior node: a parent whose hash summarizes its children.
    pub const INTERIOR: u8 = 0x01;

    /// Tombstone: an expunged payload (content + vectors destroyed).
    pub const TOMBSTONE: u8 = 0x02;

    /// Keyed commitment: HMAC-SHA256 over the canonical leaf bytes.
    pub const COMMITMENT: u8 = 0x03;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn domain_tags_are_distinct() {
        let tags = [
            MerkleDomain::LEAF,
            MerkleDomain::INTERIOR,
            MerkleDomain::TOMBSTONE,
            MerkleDomain::COMMITMENT,
        ];
        for i in 0..tags.len() {
            for j in (i + 1)..tags.len() {
                assert_ne!(tags[i], tags[j], "domain tags must be distinct");
            }
        }
    }

    #[test]
    fn frozen_values() {
        assert_eq!(MerkleDomain::LEAF, 0x00);
        assert_eq!(MerkleDomain::INTERIOR, 0x01);
        assert_eq!(MerkleDomain::TOMBSTONE, 0x02);
        assert_eq!(MerkleDomain::COMMITMENT, 0x03);
    }
}
