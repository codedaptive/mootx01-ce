// merkle_root.rs
//
// Typed 32-byte root hash of an interior node's children per
// ADR-017 §16. MerkleRoot is semantically distinct from
// ContentHash — a root summarizes a subtree of children's
// hashes, a content hash summarizes one leaf payload. The type
// system prevents substituting one for the other.

use std::fmt;

/// 32-byte Merkle root hash of a subtree (room, wing, or estate).
///
/// MerkleRoot is the substrate's per-node integrity summary.
/// It is NOT a content hash; see `ContentHash` for the leaf
/// payload digest.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct MerkleRoot {
    bytes: [u8; 32],
}

impl MerkleRoot {
    /// Creates a MerkleRoot from exactly 32 bytes.
    pub const fn new(bytes: [u8; 32]) -> Self {
        Self { bytes }
    }

    /// The raw 32 bytes of the root hash.
    pub const fn bytes(&self) -> &[u8; 32] {
        &self.bytes
    }

    /// Root hash of an empty subtree (a node with no live children).
    ///
    /// SHA-256 of the bare INTERIOR domain tag byte (0x01).
    /// Per the I-25 layering constraint, this is a byte literal —
    /// substrate-types (layer 1) cannot depend on substrate-kernel
    /// (layer 2) to compute it at runtime. A substrate-kernel
    /// bridge test verifies the literal equals
    /// SHA256::digest(&[MerkleDomain::INTERIOR]).
    pub const EMPTY: MerkleRoot = MerkleRoot {
        bytes: [
            0x4b, 0xf5, 0x12, 0x2f, 0x34, 0x45, 0x54, 0xc5,
            0x3b, 0xde, 0x2e, 0xbb, 0x8c, 0xd2, 0xb7, 0xe3,
            0xd1, 0x60, 0x0a, 0xd6, 0x31, 0xc3, 0x85, 0xa5,
            0xd7, 0xcc, 0xe2, 0x3c, 0x77, 0x85, 0x45, 0x9a,
        ],
    };

    /// Lowercase hex string representation of the 32 bytes.
    pub fn hex_string(&self) -> String {
        self.bytes.iter().map(|b| format!("{:02x}", b)).collect()
    }

    /// Construct from a 64-character hex string.
    ///
    /// Returns `Err(InvalidHexCharacter)` on non-ASCII input.  Slicing a
    /// `str` at byte indices panics when the indices do not fall on UTF-8
    /// character boundaries; rejecting non-ASCII input up front prevents that
    /// panic without any other behaviour change (a valid hex string is always
    /// pure ASCII).
    pub fn from_hex(hex: &str) -> Result<Self, MerkleRootError> {
        if hex.len() != 64 {
            return Err(MerkleRootError::InvalidHexLength(hex.len()));
        }
        // Reject non-ASCII before byte-slicing: a multi-byte UTF-8 character
        // can make hex.len() == 64 (bytes) while the string has fewer than 64
        // characters, causing hex[i*2..i*2+2] to panic on a mid-codepoint
        // boundary.
        if !hex.is_ascii() {
            return Err(MerkleRootError::InvalidHexCharacter);
        }
        let mut bytes = [0u8; 32];
        for i in 0..32 {
            bytes[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16)
                .map_err(|_| MerkleRootError::InvalidHexCharacter)?;
        }
        Ok(Self { bytes })
    }
}

impl fmt::Debug for MerkleRoot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "MerkleRoot({})", self.hex_string())
    }
}

impl fmt::Display for MerkleRoot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.hex_string())
    }
}

/// Errors for MerkleRoot construction from external input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MerkleRootError {
    InvalidHexLength(usize),
    InvalidHexCharacter,
}

impl fmt::Display for MerkleRootError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidHexLength(len) => {
                write!(f, "expected 64 hex characters, got {}", len)
            }
            Self::InvalidHexCharacter => {
                write!(f, "invalid hex character in merkle root string")
            }
        }
    }
}

impl std::error::Error for MerkleRootError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_bytes() {
        let bytes = [0xcd; 32];
        let root = MerkleRoot::new(bytes);
        assert_eq!(*root.bytes(), bytes);
    }

    #[test]
    fn hex_display() {
        let root = MerkleRoot::new([0; 32]);
        assert_eq!(
            root.hex_string(),
            "0000000000000000000000000000000000000000000000000000000000000000"
        );
    }

    #[test]
    fn hex_round_trip() {
        let original = MerkleRoot::new([
            0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
            0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
            0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
            0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        ]);
        let hex = original.hex_string();
        let restored = MerkleRoot::from_hex(&hex).unwrap();
        assert_eq!(original, restored);
    }

    #[test]
    fn equality() {
        let a = MerkleRoot::new([1; 32]);
        let b = MerkleRoot::new([1; 32]);
        let c = MerkleRoot::new([2; 32]);
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn empty_constant_bytes() {
        // SHA-256 of [0x01] (INTERIOR domain tag)
        let expected = [
            0x4b, 0xf5, 0x12, 0x2f, 0x34, 0x45, 0x54, 0xc5,
            0x3b, 0xde, 0x2e, 0xbb, 0x8c, 0xd2, 0xb7, 0xe3,
            0xd1, 0x60, 0x0a, 0xd6, 0x31, 0xc3, 0x85, 0xa5,
            0xd7, 0xcc, 0xe2, 0x3c, 0x77, 0x85, 0x45, 0x9a,
        ];
        assert_eq!(*MerkleRoot::EMPTY.bytes(), expected);
    }

    #[test]
    fn content_hash_and_merkle_root_are_distinct_types() {
        // This test verifies at compile time that ContentHash and
        // MerkleRoot are distinct types — you cannot assign one to
        // the other. The runtime check is that their sentinel
        // constants have different byte values.
        use crate::content_hash::ContentHash;
        assert_ne!(
            ContentHash::TOMBSTONE.bytes().as_slice(),
            MerkleRoot::EMPTY.bytes().as_slice(),
        );
    }

    #[test]
    fn non_ascii_input_returns_error_not_panic() {
        // A string whose byte length is 64 but whose characters include a
        // multi-byte UTF-8 codepoint (the two-byte '£', U+00A3).  Before the
        // fix, hex[i*2..i*2+2] would panic on a non-char-boundary; now it
        // must return Err rather than panic.
        let non_ascii = "00".repeat(31) + "£"; // 62 + 2 = 64 bytes, passes len check
        assert_eq!(non_ascii.len(), 64, "test setup: byte length must be 64");
        assert!(matches!(
            MerkleRoot::from_hex(&non_ascii),
            Err(MerkleRootError::InvalidHexCharacter)
        ));
    }
}
