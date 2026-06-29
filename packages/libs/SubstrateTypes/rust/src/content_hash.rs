// content_hash.rs
//
// Typed 32-byte SHA-256 digest over a leaf payload (drawer
// content + vectors) per ADR-017 §16. ContentHash is semantically
// distinct from MerkleRoot — a content hash summarizes ONE
// payload, a Merkle root summarizes a subtree of children's
// hashes. The type system prevents mixing them.

use std::fmt;

/// 32-byte SHA-256 content hash of a leaf payload.
///
/// ContentHash is the substrate's per-drawer integrity
/// fingerprint. It is NOT a Merkle root; see `MerkleRoot`
/// for the subtree-summary type.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct ContentHash {
    bytes: [u8; 32],
}

impl ContentHash {
    /// Creates a ContentHash from exactly 32 bytes.
    pub const fn new(bytes: [u8; 32]) -> Self {
        Self { bytes }
    }

    /// The raw 32 bytes of the hash.
    pub const fn bytes(&self) -> &[u8; 32] {
        &self.bytes
    }

    /// Sentinel hash for a tombstoned (expunged) drawer payload.
    ///
    /// SHA-256 of the bare TOMBSTONE domain tag byte (0x02).
    /// Per ADR-017 §16 and the I-25 layering constraint, this is
    /// a byte literal — substrate-types (layer 1) cannot depend on
    /// substrate-kernel (layer 2) to compute it at runtime.
    /// A substrate-kernel bridge test verifies the literal equals
    /// SHA256::digest(&[MerkleDomain::TOMBSTONE]).
    pub const TOMBSTONE: ContentHash = ContentHash {
        bytes: [
            0xdb, 0xc1, 0xb4, 0xc9, 0x00, 0xff, 0xe4, 0x8d,
            0x57, 0x5b, 0x5d, 0xa5, 0xc6, 0x38, 0x04, 0x01,
            0x25, 0xf6, 0x5d, 0xb0, 0xfe, 0x3e, 0x24, 0x49,
            0x4b, 0x76, 0xea, 0x98, 0x64, 0x57, 0xd9, 0x86,
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
    pub fn from_hex(hex: &str) -> Result<Self, ContentHashError> {
        if hex.len() != 64 {
            return Err(ContentHashError::InvalidHexLength(hex.len()));
        }
        // Reject non-ASCII before byte-slicing: a multi-byte UTF-8 character
        // can make hex.len() == 64 (bytes) while the string has fewer than 64
        // characters, causing hex[i*2..i*2+2] to panic on a mid-codepoint
        // boundary.
        if !hex.is_ascii() {
            return Err(ContentHashError::InvalidHexCharacter);
        }
        let mut bytes = [0u8; 32];
        for i in 0..32 {
            bytes[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16)
                .map_err(|_| ContentHashError::InvalidHexCharacter)?;
        }
        Ok(Self { bytes })
    }
}

impl fmt::Debug for ContentHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "ContentHash({})", self.hex_string())
    }
}

impl fmt::Display for ContentHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.hex_string())
    }
}

/// Errors for ContentHash construction from external input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContentHashError {
    InvalidHexLength(usize),
    InvalidHexCharacter,
}

impl fmt::Display for ContentHashError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidHexLength(len) => {
                write!(f, "expected 64 hex characters, got {}", len)
            }
            Self::InvalidHexCharacter => {
                write!(f, "invalid hex character in content hash string")
            }
        }
    }
}

impl std::error::Error for ContentHashError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_bytes() {
        let bytes = [0xab; 32];
        let hash = ContentHash::new(bytes);
        assert_eq!(*hash.bytes(), bytes);
    }

    #[test]
    fn hex_display() {
        let hash = ContentHash::new([0; 32]);
        assert_eq!(
            hash.hex_string(),
            "0000000000000000000000000000000000000000000000000000000000000000"
        );
    }

    #[test]
    fn hex_round_trip() {
        let original = ContentHash::new([
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        ]);
        let hex = original.hex_string();
        let restored = ContentHash::from_hex(&hex).unwrap();
        assert_eq!(original, restored);
    }

    #[test]
    fn equality() {
        let a = ContentHash::new([1; 32]);
        let b = ContentHash::new([1; 32]);
        let c = ContentHash::new([2; 32]);
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn tombstone_constant_bytes() {
        // SHA-256 of [0x02] (TOMBSTONE domain tag)
        let expected = [
            0xdb, 0xc1, 0xb4, 0xc9, 0x00, 0xff, 0xe4, 0x8d,
            0x57, 0x5b, 0x5d, 0xa5, 0xc6, 0x38, 0x04, 0x01,
            0x25, 0xf6, 0x5d, 0xb0, 0xfe, 0x3e, 0x24, 0x49,
            0x4b, 0x76, 0xea, 0x98, 0x64, 0x57, 0xd9, 0x86,
        ];
        assert_eq!(*ContentHash::TOMBSTONE.bytes(), expected);
    }

    #[test]
    fn invalid_hex_length() {
        assert!(matches!(
            ContentHash::from_hex("abc"),
            Err(ContentHashError::InvalidHexLength(3))
        ));
    }

    #[test]
    fn invalid_hex_character() {
        let bad = "zz".to_string() + &"00".repeat(31);
        assert!(matches!(
            ContentHash::from_hex(&bad),
            Err(ContentHashError::InvalidHexCharacter)
        ));
    }

    #[test]
    fn non_ascii_input_returns_error_not_panic() {
        // A string whose byte length is 64 but whose characters include a
        // multi-byte UTF-8 codepoint (the two-byte '£', U+00A3).  Before the
        // fix, hex[i*2..i*2+2] would panic on a non-char-boundary; now it
        // must return Err rather than panic.
        //
        // "£" is two bytes (0xC2, 0xA3), so 31 ASCII '00' pairs (62 bytes)
        // plus one '£' (2 bytes) = 64 bytes, passes the len() check.
        let non_ascii = "00".repeat(31) + "£";
        assert_eq!(non_ascii.len(), 64, "test setup: byte length must be 64");
        assert!(matches!(
            ContentHash::from_hex(&non_ascii),
            Err(ContentHashError::InvalidHexCharacter)
        ));
    }
}
