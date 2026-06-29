// MerkleDomain.swift
//
// Domain-separation byte constants from ADR-017 §16. These are
// the one-byte prefixes prepended before hashing to prevent
// cross-domain collisions in the Merkle content-integrity tree.
//
// Values are frozen by the NT-P0 reconciled bakeoff and
// conformance-pinned forever.

import Foundation

/// Domain-separation tags for the Merkle content-integrity tree.
///
/// Each tag is a one-byte prefix prepended before the payload
/// bytes when computing a hash, ensuring a leaf hash can never
/// collide with or be substituted for an interior hash.
///
/// These values are conformance-frozen — they MUST be identical
/// across Swift and Rust, and MUST NOT change after NT-P0.
public enum MerkleDomain {
    /// Leaf node: a single drawer's content + vectors.
    public static let leaf: UInt8 = 0x00

    /// Interior node: a parent whose hash summarizes its children.
    public static let interior: UInt8 = 0x01

    /// Tombstone: an expunged payload (content + vectors destroyed).
    public static let tombstone: UInt8 = 0x02

    /// Keyed commitment: HMAC-SHA256 over the canonical leaf bytes.
    public static let commitment: UInt8 = 0x03
}
