// snapshot_id.rs
//
// Typed UUID wrapper for snapshot identifiers per ADR-017 §15.
// Each snapshot in the snapshot registry carries a unique
// SnapshotId that distinguishes it from drawer IDs, node IDs,
// and estate IDs at the type level.

use std::fmt;

/// Unique identifier for a point-in-time snapshot of an estate.
///
/// SnapshotId is a UUID wrapper that prevents accidental
/// substitution of drawer, node, or estate identifiers where
/// a snapshot identifier is expected.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SnapshotId {
    /// 16-byte UUID stored as big-endian bytes.
    bytes: [u8; 16],
}

impl SnapshotId {
    /// Creates a SnapshotId from 16 raw UUID bytes.
    pub const fn from_bytes(bytes: [u8; 16]) -> Self {
        Self { bytes }
    }

    /// The raw 16-byte UUID.
    pub const fn bytes(&self) -> &[u8; 16] {
        &self.bytes
    }

    /// Parse from a UUID string (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).
    ///
    /// Returns `Err` on non-ASCII input or any character that is not a hex
    /// digit or '-'.  Slicing a `str` at byte indices panics when the indices
    /// do not fall on UTF-8 character boundaries; rejecting non-ASCII input up
    /// front prevents that panic (a valid UUID string is always pure ASCII).
    pub fn from_uuid_string(s: &str) -> Result<Self, SnapshotIdError> {
        let hex: String = s.chars().filter(|c| *c != '-').collect();
        if hex.len() != 32 {
            return Err(SnapshotIdError::InvalidUUID(s.to_string()));
        }
        // Reject non-ASCII before byte-slicing: a multi-byte UTF-8 character
        // in `hex` makes hex.len() count bytes rather than characters, so
        // hex[i*2..i*2+2] could panic on a mid-codepoint boundary.
        if !hex.is_ascii() {
            return Err(SnapshotIdError::InvalidUUID(s.to_string()));
        }
        let mut bytes = [0u8; 16];
        for i in 0..16 {
            bytes[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16)
                .map_err(|_| SnapshotIdError::InvalidUUID(s.to_string()))?;
        }
        Ok(Self { bytes })
    }

    /// UUID string representation (uppercase, hyphenated).
    pub fn uuid_string(&self) -> String {
        format!(
            "{:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
            self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3],
            self.bytes[4], self.bytes[5],
            self.bytes[6], self.bytes[7],
            self.bytes[8], self.bytes[9],
            self.bytes[10], self.bytes[11], self.bytes[12], self.bytes[13],
            self.bytes[14], self.bytes[15],
        )
    }
}

impl fmt::Display for SnapshotId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.uuid_string())
    }
}

/// Errors for SnapshotId construction from external input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SnapshotIdError {
    InvalidUUID(String),
}

impl fmt::Display for SnapshotIdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidUUID(s) => write!(f, "invalid UUID string: {}", s),
        }
    }
}

impl std::error::Error for SnapshotIdError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_bytes() {
        let bytes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                     0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10];
        let id = SnapshotId::from_bytes(bytes);
        assert_eq!(*id.bytes(), bytes);
    }

    #[test]
    fn uuid_string_round_trip() {
        let uuid_str = "550E8400-E29B-41D4-A716-446655440000";
        let id = SnapshotId::from_uuid_string(uuid_str).unwrap();
        assert_eq!(id.uuid_string(), uuid_str);
    }

    #[test]
    fn uuid_string_lowercase_input() {
        let uuid_str = "550e8400-e29b-41d4-a716-446655440000";
        let id = SnapshotId::from_uuid_string(uuid_str).unwrap();
        // Output is uppercase per UUID convention
        assert_eq!(id.uuid_string(), "550E8400-E29B-41D4-A716-446655440000");
    }

    #[test]
    fn equality() {
        let a = SnapshotId::from_bytes([1; 16]);
        let b = SnapshotId::from_bytes([1; 16]);
        let c = SnapshotId::from_bytes([2; 16]);
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn invalid_uuid_string() {
        assert!(SnapshotId::from_uuid_string("not-a-uuid").is_err());
    }

    #[test]
    fn non_ascii_input_returns_error_not_panic() {
        // A UUID-shaped string that contains a multi-byte UTF-8 character
        // after dash-filtering.  Before the fix, hex[i*2..i*2+2] would panic
        // on a non-char-boundary when the post-filter string's byte length is
        // 32 but character count is less than 32.
        //
        // "£" (U+00A3) is two bytes.  Replacing the final two hex chars with
        // "£" gives a 32-byte string (30 ASCII bytes + 2-byte £) that passes
        // the len() == 32 guard but must not panic.
        let non_ascii = "00000000000000000000000000000".to_string() + "£"; // 29 + 2 = 31 bytes …
        // Ensure the test string does trigger the non-ASCII path by explicitly
        // using a full 32-byte case:
        let padded = "0000000000000000000000000000000".to_string() + "£"; // 31 + 2 = 33 bytes
        // len() != 32 → InvalidUUID (the length guard fires first). That is
        // also safe. Let's test the exact 32-byte case instead:
        // 30 ASCII chars + '£' (2 bytes) = 32 bytes — triggers is_ascii check.
        let exact = "00".repeat(15) + "£"; // 30 + 2 = 32 bytes
        assert_eq!(exact.len(), 32, "test setup: byte length must be 32");
        assert!(SnapshotId::from_uuid_string(&exact).is_err());
        let _ = (non_ascii, padded); // suppress unused warnings
    }
}
