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

    /// Build an anchor from a dotted UDC string, hashing with FNV-1a
    /// 64-bit so the same string yields the same anchor. Byte-exact
    /// mirror of Swift `LatticeAnchor.udc` (M1: one implementation).
    pub fn udc(udc_string: &str) -> Self {
        let mut h: u64 = 0xCBF2_9CE4_8422_2325;
        for byte in udc_string.bytes() {
            h ^= byte as u64;
            h = h.wrapping_mul(0x100_0000_01B3);
        }
        Self { udc_code: h, qid_pointer: 0 }
    }
    pub fn is_null(&self) -> bool {
        self.udc_code == 0 && self.qid_pointer == 0
    }
}
