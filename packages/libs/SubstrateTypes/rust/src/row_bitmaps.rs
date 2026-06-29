// row_bitmaps.rs
//
// Row-level adjective/operational/provenance bitmap layout, made
// explicit as a value type. Mirrors Swift RowBitmaps + BitVector216
// from Sources/SubstrateTypes/RowBitmaps.swift.
//
// Layout (cookbook §2.3 / §2.4 / §2.5):
//   Three flat i64 columns, each holding named bit-fields at
//   specific bit positions. The abstract 36-field / 6-bit-per-field
//   grid used for MatrixF indexing maps as:
//
//     adjective    fields  0..<12  → adjective_bitmap   (bits 0–27 used)
//     operational  fields 12..<24  → operational_bitmap (bits 0–30 used)
//     provenance   fields 24..<36  → provenance_bitmap  (bits 0–41 used)
//
// The real named fields do NOT form a uniform 12 × 6-bit grid; they
// are named ranges at specific bit positions. RowBitmaps::field(idx)
// reads them as if the grid were uniform — valid for real row data
// because real fields only use bits well below the i64 boundary.
// For arbitrary 216-bit presence grids use BitVector216::from_presence_bytes
// directly.

/// Three flat i64 bitmap columns that carry the 36 × 6-bit abstract
/// field grid across a substrate row. Mirrors Swift `RowBitmaps`.
///
/// Fields within each column:
///   `adjective`    — 36-field grid columns 0–11  (bits 0–27 used)
///   `operational`  — 36-field grid columns 12–23 (bits 0–30 used)
///   `provenance`   — 36-field grid columns 24–35 (bits 0–41 used)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct RowBitmaps {
    pub adjective:   i64,
    pub operational: i64,
    pub provenance:  i64,
}

impl RowBitmaps {
    // Layout constants — single source of truth, mirrors Swift statics.
    pub const FIELD_COUNT:      usize = 36;
    pub const BITS_PER_FIELD:   usize = 6;
    pub const BITMAPS_COUNT:    usize = 3;
    pub const FIELDS_PER_BITMAP: usize = 12; // 36 / 3
    pub const TOTAL_BITS:       usize = 216; // 36 * 6
    pub const FIELD_VALUE_MASK: i64 = 0x3F;  // (1 << 6) - 1

    pub const ZERO: RowBitmaps = RowBitmaps { adjective: 0, operational: 0, provenance: 0 };

    /// Construct from three raw i64 columns.
    #[inline]
    pub fn new(adjective: i64, operational: i64, provenance: i64) -> Self {
        Self { adjective, operational, provenance }
    }

    /// Returns the 6-bit value of field `idx` in 0..36.
    ///
    /// Panics in debug builds if `idx` is out of range. Mirrors
    /// Swift `RowBitmaps.field(_:)` including the same precondition.
    ///
    /// Note: fields 10 and 11 in each column correspond to local
    /// shifts of 60 and 66 bits respectively. A 66-bit shift on an
    /// i64 overflows in Rust debug mode. Per cookbook §2.3/§2.4/§2.5
    /// bits 28–63 / 26–63 / 42–63 are reserved, so fields at those
    /// positions (local indices 5–11 for adjective, 5–11 for
    /// operational, 8–11 for provenance) always return zero for any
    /// conforming row. We guard with a saturating shift via u32 to
    /// produce the correct zero result without panicking.
    #[inline]
    pub fn field(&self, idx: usize) -> u8 {
        assert!(idx < Self::FIELD_COUNT, "RowBitmaps::field: index out of range");
        let (bitmap, local_field) = if idx < Self::FIELDS_PER_BITMAP {
            (self.adjective, idx)
        } else if idx < 2 * Self::FIELDS_PER_BITMAP {
            (self.operational, idx - Self::FIELDS_PER_BITMAP)
        } else {
            (self.provenance, idx - 2 * Self::FIELDS_PER_BITMAP)
        };
        let shift = local_field * Self::BITS_PER_FIELD;
        // Guard against shift overflow (fields 10/11 hit shift=60/66).
        // Any shift >= 64 means the value is in reserved bits and is
        // defined to be zero per the cookbook.
        if shift >= 64 {
            return 0;
        }
        // Cast bitmap to u64 before right-shifting: `bitmap` is i64, and
        // Rust arithmetic-shifts signed integers (fills with the sign bit).
        // When bit 63 of an i64 is set, `bitmap >> shift` floods the result
        // with 1-bits, making field(10) (shift=60) return 0x3F instead of 0.
        // Bits 60-63 of all three bitmap columns are reserved (cookbook §2.3
        // /§2.4/§2.5), so a conforming row always has them zero and would
        // never have bit 63 set — but the guard is needed for defensive
        // correctness against non-conforming inputs (e.g. from fuzz callers).
        ((bitmap as u64 >> shift) & Self::FIELD_VALUE_MASK as u64) as u8
    }

    /// Returns true when bit `bit` of field `field_idx` is set.
    /// `field_idx` in 0..36, `bit` in 0..6. Mirrors Swift
    /// `RowBitmaps.bit(field:bit:)`.
    #[inline]
    pub fn bit(&self, field_idx: usize, bit: usize) -> bool {
        assert!(bit < Self::BITS_PER_FIELD, "RowBitmaps::bit: bit index out of range");
        (self.field(field_idx) >> bit) & 1 == 1
    }

    /// Yields all (field, value) pairs in field-index order. Mirrors
    /// Swift `RowBitmaps.fieldValues()`.
    pub fn field_values(&self) -> Vec<(u8, u8)> {
        (0..Self::FIELD_COUNT)
            .map(|f| (f as u8, self.field(f)))
            .collect()
    }

    /// Dense 216-bit view suitable for MatrixF consumers. Mirrors
    /// Swift `RowBitmaps.bitVector()`.
    #[inline]
    pub fn bit_vector(&self) -> BitVector216 {
        BitVector216::from_row_bitmaps(self)
    }
}

// ---------------------------------------------------------------------------

/// Dense 216-bit view for field-presence consumers (e.g. MatrixF).
/// Mirrors Swift `BitVector216` with the same two initializers:
///
/// `from_row_bitmaps` — builds from a live substrate row. Reads each
///   of the 36 fields' 6-bit values via `RowBitmaps::field` and maps
///   each set bit to its absolute position `field * 6 + bit`. Mirrors
///   Swift `BitVector216.init(rowBitmaps:)`.
///
/// `from_presence_bytes` — builds from a raw 27-byte (216-bit)
///   presence pattern where bit at absolute index `field * 6 + bit`
///   is packed at `bytes[pos/8]`, bit `pos%8` (LSB-first). This is
///   the canonical layout for the harness vector format (cookbook
///   §6.1). Mirrors Swift `BitVector216.init(presenceBytes:)`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BitVector216 {
    // 27 bytes = 216 bits, packed LSB-first per absolute position.
    storage: [u8; 27],
}

impl BitVector216 {
    pub const BIT_COUNT:  usize = RowBitmaps::TOTAL_BITS;   // 216
    pub const BYTE_COUNT: usize = 27;                        // (216 + 7) / 8

    /// Build from a live substrate row. Each of the 36 fields' 6-bit
    /// values is read via `RowBitmaps::field`, and each set bit is
    /// mapped to absolute position `field * 6 + bit`. Mirrors Swift
    /// `BitVector216.init(rowBitmaps:)`.
    pub fn from_row_bitmaps(rb: &RowBitmaps) -> Self {
        let mut s = [0u8; Self::BYTE_COUNT];
        for field in 0..RowBitmaps::FIELD_COUNT {
            let v = rb.field(field);
            for b in 0..RowBitmaps::BITS_PER_FIELD {
                if (v >> b) & 1 == 1 {
                    let abs = field * RowBitmaps::BITS_PER_FIELD + b;
                    s[abs / 8] |= 1 << (abs % 8);
                }
            }
        }
        Self { storage: s }
    }

    /// Build from a raw 27-byte presence pattern (216 bits packed
    /// LSB-first). Mirrors Swift `BitVector216.init(presenceBytes:)`.
    ///
    /// Panics if `presence_bytes.len() != 27`.
    pub fn from_presence_bytes(presence_bytes: &[u8]) -> Self {
        assert_eq!(
            presence_bytes.len(),
            Self::BYTE_COUNT,
            "BitVector216::from_presence_bytes: must be exactly 27 bytes"
        );
        let mut storage = [0u8; Self::BYTE_COUNT];
        storage.copy_from_slice(presence_bytes);
        Self { storage }
    }

    /// Expose the underlying 27-byte storage slice. Consumers that
    /// need raw bytes (e.g. harness wire serialization) use this.
    #[inline]
    pub fn as_bytes(&self) -> &[u8; 27] {
        &self.storage
    }

    /// Bit at absolute index 0..216. Mirrors Swift
    /// `BitVector216.bit(at:)`.
    #[inline]
    pub fn bit_at(&self, index: usize) -> bool {
        assert!(index < Self::BIT_COUNT, "BitVector216::bit_at: index out of range");
        (self.storage[index / 8] >> (index % 8)) & 1 == 1
    }

    /// Bit at (field, bit) coordinates. Mirrors Swift
    /// `BitVector216.bit(field:bit:)`.
    #[inline]
    pub fn bit(&self, field: usize, bit: usize) -> bool {
        self.bit_at(field * RowBitmaps::BITS_PER_FIELD + bit)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- RowBitmaps ---

    #[test]
    fn zero_constant() {
        assert_eq!(RowBitmaps::ZERO, RowBitmaps { adjective: 0, operational: 0, provenance: 0 });
    }

    #[test]
    fn layout_constants() {
        assert_eq!(RowBitmaps::FIELD_COUNT, 36);
        assert_eq!(RowBitmaps::BITS_PER_FIELD, 6);
        assert_eq!(RowBitmaps::FIELDS_PER_BITMAP, 12);
        assert_eq!(RowBitmaps::TOTAL_BITS, 216);
        assert_eq!(RowBitmaps::FIELD_VALUE_MASK, 0x3F);
    }

    #[test]
    fn field_extracts_adjective_fields() {
        // Set adjective field 0 to value 0b101010 (42).
        let rb = RowBitmaps::new(42, 0, 0);
        assert_eq!(rb.field(0), 42);
        // Fields 1..11 in adjective are zero.
        for i in 1..12 {
            assert_eq!(rb.field(i), 0, "field {i} should be 0");
        }
    }

    #[test]
    fn field_extracts_operational_fields() {
        // Set operational field 0 (grid index 12) to value 7.
        let rb = RowBitmaps::new(0, 7, 0);
        assert_eq!(rb.field(12), 7);
        for i in 13..24 {
            assert_eq!(rb.field(i), 0, "field {i} should be 0");
        }
    }

    #[test]
    fn field_extracts_provenance_fields() {
        // Set provenance field 0 (grid index 24) to value 63 (0x3F).
        let rb = RowBitmaps::new(0, 0, 0x3F);
        assert_eq!(rb.field(24), 63);
        for i in 25..36 {
            assert_eq!(rb.field(i), 0, "field {i} should be 0");
        }
    }

    #[test]
    fn field_adjacent_packing() {
        // Pack two 6-bit fields into adjective: field0=1, field1=2.
        let adjective = 1i64 | (2i64 << 6);
        let rb = RowBitmaps::new(adjective, 0, 0);
        assert_eq!(rb.field(0), 1);
        assert_eq!(rb.field(1), 2);
    }

    #[test]
    fn field_values_length() {
        let rb = RowBitmaps::ZERO;
        let vals = rb.field_values();
        assert_eq!(vals.len(), 36);
        assert_eq!(vals[0], (0, 0));
        assert_eq!(vals[35], (35, 0));
    }

    #[test]
    fn bit_accessor() {
        // Field 0 = 0b000001 → bit 0 is set, bit 1 is not.
        let rb = RowBitmaps::new(1, 0, 0);
        assert!(rb.bit(0, 0));
        assert!(!rb.bit(0, 1));
    }

    // --- BitVector216 ---

    #[test]
    fn bit_vector_from_zero_is_zero_bytes() {
        let bv = RowBitmaps::ZERO.bit_vector();
        assert!(bv.as_bytes().iter().all(|&b| b == 0));
    }

    #[test]
    fn bit_vector_from_row_bitmaps_roundtrips() {
        // Set field 0 = 1 (bit 0 of adjective). Absolute position 0.
        // That sets byte 0 bit 0 of the BitVector216.
        let rb = RowBitmaps::new(1, 0, 0);
        let bv = BitVector216::from_row_bitmaps(&rb);
        assert!(bv.bit_at(0));   // field 0, bit 0 → absolute 0
        assert!(!bv.bit_at(1));
    }

    #[test]
    fn bit_vector_field_bit_coords() {
        // Set field 2 = 0b000010 → bit 1 of field 2 is set.
        // Absolute position = 2 * 6 + 1 = 13.
        let adjective = 0b10i64 << (2 * 6);
        let rb = RowBitmaps::new(adjective, 0, 0);
        let bv = BitVector216::from_row_bitmaps(&rb);
        assert!(bv.bit(2, 1));
        assert!(!bv.bit(2, 0));
        assert!(bv.bit_at(13));
    }

    #[test]
    fn bit_vector_from_presence_bytes_passthrough() {
        // Build a 27-byte pattern with all bits set and verify.
        let all_set = [0xFFu8; 27];
        let bv = BitVector216::from_presence_bytes(&all_set);
        for i in 0..216 {
            assert!(bv.bit_at(i), "bit {i} should be set");
        }
    }

    #[test]
    fn from_presence_bytes_byte_count() {
        // Confirm the canonical 27-byte requirement is enforced.
        let result = std::panic::catch_unwind(|| {
            BitVector216::from_presence_bytes(&[0u8; 26]);
        });
        assert!(result.is_err(), "should panic on wrong byte count");
    }

    #[test]
    fn bit_vector216_byte_count() {
        assert_eq!(BitVector216::BYTE_COUNT, 27);
        assert_eq!(BitVector216::BIT_COUNT, 216);
    }

    #[test]
    fn row_bitmaps_default_is_zero() {
        let rb: RowBitmaps = Default::default();
        assert_eq!(rb, RowBitmaps::ZERO);
    }

    #[test]
    fn field_10_sign_extension_fix() {
        // field(10) has local_field=10, shift=60. i64 arithmetic right-shift
        // propagates the sign bit: if bit 63 is set, `i64::MIN >> 60 = -1 =
        // 0xFF...FF`, and `& 0x3F = 0x3F (63)` — WRONG.
        //
        // Correct behavior: cast to u64 first so the shift is logical (zero-
        // filling). For i64::MIN (= 0x8000000000000000):
        //   `(0x8000000000000000u64) >> 60 = 0x8`, `& 0x3F = 8`.
        // Bit 63 is bit 3 of field(10) (since shift=60 and 63-60=3); the
        // correct extraction is 8, not 63.
        let rb = RowBitmaps::new(i64::MIN, i64::MIN, i64::MIN);
        // field(10) = u64-cast-corrected extraction = 8 (NOT 63 as arithmetic shift would give)
        assert_eq!(rb.field(10), 8,
            "field(10) with i64::MIN adjective: u64 logical shift gives 8, not 0x3F=63");
        assert_eq!(rb.field(22), 8,
            "field(22) with i64::MIN operational: u64 logical shift gives 8, not 0x3F=63");
        assert_eq!(rb.field(34), 8,
            "field(34) with i64::MIN provenance: u64 logical shift gives 8, not 0x3F=63");
    }

    #[test]
    fn field_10_with_only_lower_bits_set_no_sign_bleed() {
        // A value with bits 60-62 set (decimal 7 at bit 60), but bit 63 clear,
        // must extract the 3-bit value 7 without contamination from sign extension.
        // (Bit 63 is what triggers arithmetic-shift bleed; having it clear means
        // BOTH the old and new paths agree — this is a sanity check.)
        let adjective = 0b111i64 << 60; // bits 60, 61, 62 set; bit 63 clear
        let rb = RowBitmaps::new(adjective, 0, 0);
        assert_eq!(rb.field(10), 7, "bits 60-62 set, bit 63 clear → field(10) = 7");
    }
}
