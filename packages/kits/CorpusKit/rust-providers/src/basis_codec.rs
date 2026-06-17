//! Shared little-endian binary codec for distributional-provider basis
//! serialization (mission 6a-i). Rust mirror of Swift's `BasisCodec.swift`.
//! One definition, used by all four stateful providers (RandomIndexing,
//! PPMI, LSA, NMF). This is PROVIDER-FORMAT code, not a math primitive —
//! it lives in `corpus-kit-providers`, never in the substrate.
//!
//! ## Why a hand-rolled binary codec rather than serde/JSON
//!
//! The format is the CROSS-PORT CONTRACT: identical trained state on Swift
//! and Rust MUST produce byte-identical blobs. JSON float encoding, key
//! ordering, and whitespace are not guaranteed identical across the two
//! language ecosystems. A fixed little-endian binary layout with explicit
//! sorted-key map ordering removes every source of ambiguity: the byte
//! stream is a pure function of the logical state.
//!
//! ## Byte format (the contract — mirrored exactly in Swift BasisCodec.swift)
//!
//!   - Endianness: LITTLE-ENDIAN throughout, no exceptions.
//!   - Integers: u32 → 4 bytes LE; u64 → 8 bytes LE.
//!   - Float32:  IEEE-754 bit pattern (`f32::to_bits` / `to_le_bytes`).
//!   - String:   u32 LE byte-length prefix, then that many UTF-8 bytes.
//!   - `Vec<f32>`: u32 LE element count, then count × (f32 = 4 bytes).
//!   - `Vec<Vec<f32>>` (matrix): u32 LE row count, then each row as a vec.
//!   - Map<String,*>: u32 LE entry count, then entries emitted in
//!     LEXICOGRAPHICALLY ASCENDING order of the key's UTF-8 bytes. Rust's
//!     `Ord for str` compares by bytes; the Swift port sorts by the same
//!     UTF-8 byte order, so both ports emit identical bytes for a given map.
//!
//! Each provider blob is framed as:
//!   MAGIC (4 ASCII bytes, provider-specific) | FORMAT_VERSION (1 byte) | payload
//!
//! The magic + version live at the FRONT so mission 6a-ii can detect and
//! version a persisted basis without parsing the payload. An unknown
//! version or a truncated blob is rejected with a structured
//! `BasisCodecError` — never a panic or out-of-bounds unwrap.

use std::collections::HashMap;

/// Current basis-blob format version. Bumped only when the byte layout of
/// any provider's payload changes incompatibly. Mission 6a-i ships v1.
pub const BASIS_FORMAT_VERSION: u8 = 1;

// MARK: - Error

/// Structured errors for basis (de)serialization. Returned instead of a
/// panic so a truncated, mistyped, or future-versioned blob fails loud and
/// recoverably (mission 6a-ii surfaces this to the caller).
#[derive(Debug, PartialEq, Eq)]
pub enum BasisCodecError {
    /// The blob ended before a required field could be fully read.
    /// Payload is a human-readable description of what was being read.
    Truncated(String),

    /// The 4-byte magic header did not match the expected provider tag.
    /// Payload describes expected vs. actual.
    MagicMismatch(String),

    /// The format-version byte names a version this build cannot decode.
    /// Payload reports the version seen and the version expected.
    UnsupportedVersion(String),

    /// A length-prefixed string was not valid UTF-8.
    InvalidUtf8(String),
}

impl std::fmt::Display for BasisCodecError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BasisCodecError::Truncated(m) => write!(f, "basis codec: truncated blob: {m}"),
            BasisCodecError::MagicMismatch(m) => write!(f, "basis codec: magic mismatch: {m}"),
            BasisCodecError::UnsupportedVersion(m) => {
                write!(f, "basis codec: unsupported version: {m}")
            }
            BasisCodecError::InvalidUtf8(m) => write!(f, "basis codec: invalid UTF-8: {m}"),
        }
    }
}

impl std::error::Error for BasisCodecError {}

// MARK: - Writer

/// Append-only little-endian byte writer for basis serialization.
///
/// Every primitive is appended in the fixed little-endian layout documented
/// at the top of this file. The writer holds no provider knowledge —
/// providers compose their blob from these primitives.
#[derive(Default)]
pub struct BasisWriter {
    bytes: Vec<u8>,
}

impl BasisWriter {
    /// Create an empty writer.
    pub fn new() -> Self {
        BasisWriter { bytes: Vec::new() }
    }

    /// Consume the writer and return the accumulated bytes.
    pub fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }

    /// Append a single raw byte (used for the format-version tag).
    pub fn write_byte(&mut self, b: u8) {
        self.bytes.push(b);
    }

    /// Append the 4 ASCII magic bytes that identify a provider's blob.
    pub fn write_magic(&mut self, magic: &[u8; 4]) {
        self.bytes.extend_from_slice(magic);
    }

    /// Append a u32 in little-endian order (low byte first).
    pub fn write_u32(&mut self, v: u32) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }

    /// Append a u64 in little-endian order (low byte first).
    pub fn write_u64(&mut self, v: u64) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }

    /// Append an f32 as its IEEE-754 bit pattern, little-endian. Using the
    /// bit pattern guarantees -0.0, NaN, and subnormals round-trip exactly
    /// and match Swift's `Float.bitPattern`.
    pub fn write_f32(&mut self, v: f32) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }

    /// Append a UTF-8 string: u32 LE byte-length prefix, then the bytes.
    pub fn write_string(&mut self, s: &str) {
        let utf8 = s.as_bytes();
        self.write_u32(utf8.len() as u32);
        self.bytes.extend_from_slice(utf8);
    }

    /// Append an f32 vector: u32 LE count, then each f32.
    pub fn write_f32_array(&mut self, a: &[f32]) {
        self.write_u32(a.len() as u32);
        for &x in a {
            self.write_f32(x);
        }
    }

    /// Append an f32 matrix: u32 LE row count, then each row as a
    /// length-prefixed f32 vector (rows may be ragged; each carries its own
    /// length, so jagged matrices round-trip faithfully).
    pub fn write_f32_matrix(&mut self, m: &[Vec<f32>]) {
        self.write_u32(m.len() as u32);
        for row in m {
            self.write_f32_array(row);
        }
    }

    /// Append a `HashMap<String, Vec<f32>>` in lexicographically ascending
    /// key order (UTF-8 byte order). Sorting is REQUIRED for cross-port byte
    /// identity: HashMap iteration order is unspecified, so the keys are
    /// sorted before emission so Rust and Swift agree byte-for-byte. Rust's
    /// `str` ordering is by raw bytes, which is exactly what the Swift port
    /// sorts by.
    pub fn write_string_f32_vector_map(&mut self, map: &HashMap<String, Vec<f32>>) {
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
        self.write_u32(keys.len() as u32);
        for key in keys {
            self.write_string(key);
            self.write_f32_array(&map[key]);
        }
    }

    /// Append a `HashMap<String, usize>` (term → vocabulary index), sorted
    /// by the key's UTF-8 bytes (same ordering rule as the float-vector map).
    /// Indices are written as u32 LE.
    pub fn write_string_u32_map(&mut self, map: &HashMap<String, usize>) {
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
        self.write_u32(keys.len() as u32);
        for key in keys {
            self.write_string(key);
            self.write_u32(map[key] as u32);
        }
    }
}

// MARK: - Reader

/// Sequential little-endian byte reader for basis deserialization.
///
/// Every read advances a cursor and bounds-checks against the buffer. A
/// read past the end returns `Err(BasisCodecError::Truncated)` — there is
/// NO unwrap and NO out-of-bounds panic on a truncated blob.
pub struct BasisReader<'a> {
    bytes: &'a [u8],
    cursor: usize,
}

impl<'a> BasisReader<'a> {
    /// Create a reader over `bytes`.
    pub fn new(bytes: &'a [u8]) -> Self {
        BasisReader { bytes, cursor: 0 }
    }

    /// Number of unread bytes remaining.
    pub fn remaining(&self) -> usize {
        self.bytes.len() - self.cursor
    }

    /// Read a single raw byte, or error if the buffer is exhausted.
    pub fn read_byte(&mut self) -> Result<u8, BasisCodecError> {
        if self.cursor + 1 > self.bytes.len() {
            return Err(BasisCodecError::Truncated(format!(
                "reading byte at offset {}",
                self.cursor
            )));
        }
        let b = self.bytes[self.cursor];
        self.cursor += 1;
        Ok(b)
    }

    /// Read 4 magic bytes and verify they equal `expected`. Errors on
    /// truncation or magic mismatch (wrong provider / corrupted header).
    pub fn expect_magic(&mut self, expected: &[u8; 4]) -> Result<(), BasisCodecError> {
        if self.cursor + 4 > self.bytes.len() {
            return Err(BasisCodecError::Truncated("reading magic".to_string()));
        }
        let got = &self.bytes[self.cursor..self.cursor + 4];
        self.cursor += 4;
        if got != expected {
            return Err(BasisCodecError::MagicMismatch(format!(
                "expected {expected:?}, got {got:?}"
            )));
        }
        Ok(())
    }

    /// Read the format-version byte and verify it is `expected`. An unknown
    /// version is rejected so a future on-disk format is never silently
    /// misread (mission 6a-ii relies on this gate).
    pub fn expect_version(&mut self, expected: u8) -> Result<(), BasisCodecError> {
        let v = self.read_byte()?;
        if v != expected {
            return Err(BasisCodecError::UnsupportedVersion(format!(
                "version {v} (expected {expected})"
            )));
        }
        Ok(())
    }

    /// Read a little-endian u32, or error on truncation.
    pub fn read_u32(&mut self) -> Result<u32, BasisCodecError> {
        if self.cursor + 4 > self.bytes.len() {
            return Err(BasisCodecError::Truncated(format!(
                "reading u32 at offset {}",
                self.cursor
            )));
        }
        let mut buf = [0u8; 4];
        buf.copy_from_slice(&self.bytes[self.cursor..self.cursor + 4]);
        self.cursor += 4;
        Ok(u32::from_le_bytes(buf))
    }

    /// Read a little-endian u64, or error on truncation.
    pub fn read_u64(&mut self) -> Result<u64, BasisCodecError> {
        if self.cursor + 8 > self.bytes.len() {
            return Err(BasisCodecError::Truncated(format!(
                "reading u64 at offset {}",
                self.cursor
            )));
        }
        let mut buf = [0u8; 8];
        buf.copy_from_slice(&self.bytes[self.cursor..self.cursor + 8]);
        self.cursor += 8;
        Ok(u64::from_le_bytes(buf))
    }

    /// Read an f32 from its little-endian IEEE-754 bit pattern.
    pub fn read_f32(&mut self) -> Result<f32, BasisCodecError> {
        Ok(f32::from_bits(self.read_u32()?))
    }

    /// Read a UTF-8 string (u32 LE length prefix, then bytes).
    pub fn read_string(&mut self) -> Result<String, BasisCodecError> {
        let len = self.read_u32()? as usize;
        if self.cursor + len > self.bytes.len() {
            return Err(BasisCodecError::Truncated(format!(
                "reading string of length {len}"
            )));
        }
        let slice = &self.bytes[self.cursor..self.cursor + len];
        self.cursor += len;
        String::from_utf8(slice.to_vec())
            .map_err(|e| BasisCodecError::InvalidUtf8(e.to_string()))
    }

    /// Read an f32 vector (u32 LE count, then each f32).
    pub fn read_f32_array(&mut self) -> Result<Vec<f32>, BasisCodecError> {
        let count = self.read_u32()? as usize;
        let mut out = Vec::with_capacity(count);
        for _ in 0..count {
            out.push(self.read_f32()?);
        }
        Ok(out)
    }

    /// Read an f32 matrix (u32 LE row count, then each row).
    pub fn read_f32_matrix(&mut self) -> Result<Vec<Vec<f32>>, BasisCodecError> {
        let rows = self.read_u32()? as usize;
        let mut out = Vec::with_capacity(rows);
        for _ in 0..rows {
            out.push(self.read_f32_array()?);
        }
        Ok(out)
    }

    /// Read a `HashMap<String, Vec<f32>>`. Entries were written in sorted
    /// key order but the reconstructed map does not depend on order.
    pub fn read_string_f32_vector_map(
        &mut self,
    ) -> Result<HashMap<String, Vec<f32>>, BasisCodecError> {
        let count = self.read_u32()? as usize;
        let mut out = HashMap::with_capacity(count);
        for _ in 0..count {
            let key = self.read_string()?;
            let vec = self.read_f32_array()?;
            out.insert(key, vec);
        }
        Ok(out)
    }

    /// Read a `HashMap<String, usize>` (term → vocabulary index).
    pub fn read_string_u32_map(&mut self) -> Result<HashMap<String, usize>, BasisCodecError> {
        let count = self.read_u32()? as usize;
        let mut out = HashMap::with_capacity(count);
        for _ in 0..count {
            let key = self.read_string()?;
            let idx = self.read_u32()? as usize;
            out.insert(key, idx);
        }
        Ok(out)
    }
}

// MARK: - Unit tests (primitive round-trips)

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn u32_round_trips_little_endian() {
        let mut w = BasisWriter::new();
        w.write_u32(0x0102_0304);
        let bytes = w.into_bytes();
        // Little-endian: low byte first.
        assert_eq!(bytes, vec![0x04, 0x03, 0x02, 0x01]);
        let mut r = BasisReader::new(&bytes);
        assert_eq!(r.read_u32().unwrap(), 0x0102_0304);
    }

    #[test]
    fn f32_round_trips_via_bit_pattern() {
        let mut w = BasisWriter::new();
        // -0.0 and a subnormal must survive the bit-pattern round trip.
        w.write_f32(-0.0);
        w.write_f32(f32::from_bits(0x0000_0001));
        let bytes = w.into_bytes();
        let mut r = BasisReader::new(&bytes);
        assert_eq!(r.read_f32().unwrap().to_bits(), (-0.0f32).to_bits());
        assert_eq!(r.read_f32().unwrap().to_bits(), 0x0000_0001);
    }

    #[test]
    fn string_map_is_sorted_by_utf8_bytes() {
        let mut map = HashMap::new();
        map.insert("car".to_string(), vec![1.0f32]);
        map.insert("apple".to_string(), vec![2.0f32]);
        map.insert("banana".to_string(), vec![3.0f32]);
        let mut w = BasisWriter::new();
        w.write_string_f32_vector_map(&map);
        let bytes = w.into_bytes();
        let mut r = BasisReader::new(&bytes);
        // The reader returns a map, but we verify ordering by re-reading the
        // raw stream: the first key after the u32 count must be "apple".
        assert_eq!(r.read_u32().unwrap(), 3); // entry count
        assert_eq!(r.read_string().unwrap(), "apple");
    }

    #[test]
    fn truncated_blob_errors_not_panics() {
        let bytes = vec![0x01, 0x02]; // too short for a u32
        let mut r = BasisReader::new(&bytes);
        let err = r.read_u32().unwrap_err();
        assert!(matches!(err, BasisCodecError::Truncated(_)));
    }

    #[test]
    fn unknown_version_is_rejected() {
        let bytes = vec![0xFF]; // version 255
        let mut r = BasisReader::new(&bytes);
        let err = r.expect_version(BASIS_FORMAT_VERSION).unwrap_err();
        assert!(matches!(err, BasisCodecError::UnsupportedVersion(_)));
    }

    #[test]
    fn magic_mismatch_is_rejected() {
        let bytes = vec![b'X', b'X', b'X', b'X'];
        let mut r = BasisReader::new(&bytes);
        let err = r.expect_magic(b"RIB1").unwrap_err();
        assert!(matches!(err, BasisCodecError::MagicMismatch(_)));
    }
}
