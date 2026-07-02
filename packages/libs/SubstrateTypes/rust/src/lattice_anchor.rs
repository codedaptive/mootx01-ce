//! Lattice anchor reference per cookbook §2.7 / I-16.
//!
//! Sixteen bytes: an 8-byte UDC code plus an 8-byte Q-ID pointer
//! (or 0 for null). Pure data. Moved here from substrate-lib in
//! Phase 6.3 of the pre-ship refactor (decision 2026-05-28 §6.6).

/// Lattice anchor reference per § 2.7 / I-16.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LatticeAnchor {
    pub udc_code: u64,
    pub qid_pointer: u64, // 0 = null
}

impl LatticeAnchor {
    pub fn new(udc_code: u64, qid_pointer: u64) -> Self {
        Self { udc_code, qid_pointer }
    }

    /// FNV-1a 64-bit hash of a string's bytes. Byte-exact mirror of Swift
    /// `LatticeAnchor.fnv1a64`.
    pub fn fnv1a64(s: &str) -> u64 {
        let mut h: u64 = 0xCBF2_9CE4_8422_2325;
        for byte in s.bytes() {
            h ^= byte as u64;
            h = h.wrapping_mul(0x100_0000_01B3);
        }
        h
    }

    /// Build an anchor from a dotted UDC string, hashing with FNV-1a
    /// 64-bit so the same string yields the same anchor. Byte-exact
    /// mirror of Swift `LatticeAnchor.udc` (M1: one implementation).
    pub fn udc(udc_string: &str) -> Self {
        Self { udc_code: Self::fnv1a64(udc_string), qid_pointer: 0 }
    }

    /// Factory carrying BOTH the UDC class AND the varied per-content Q-ID:
    /// hashes each string with FNV-1a 64-bit. Without this the anchor
    /// collapses to the UDC code alone (a uniform "Knowledge" class for most
    /// prose), so downstream matrix O/T coordinates lose all per-content
    /// signal. An empty `qid_string` yields qid_pointer 0 (null), identical to
    /// `udc`. Byte-exact mirror of Swift `LatticeAnchor.udcQid`.
    pub fn udc_qid(udc_string: &str, qid_string: &str) -> Self {
        Self {
            udc_code: Self::fnv1a64(udc_string),
            qid_pointer: if qid_string.is_empty() { 0 } else { Self::fnv1a64(qid_string) },
        }
    }

    pub fn is_null(&self) -> bool {
        self.udc_code == 0 && self.qid_pointer == 0
    }
}
