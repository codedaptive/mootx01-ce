// bit_tensor.rs
//
// 3D bit-sliced tensor per cookbook § 4.1. Mirror of
// glref-swift-ThreeDBitTensor.swift.
//
// Three axes: row (up to N_rows), field (36 across the bitmap
// columns), bit (6 per field — invariant I-6). Storage is six
// flat byte buffers, one per bit position. Scans loop row-by-row
// within each of the six bit-slice passes; not yet vectorized.

#[derive(Debug, Clone)]
pub struct ThreeDBitTensor {
    pub row_count: usize,
    pub slices: Vec<Vec<u8>>,    // 6 slices, each ceil(N*36/8) bytes
}

impl ThreeDBitTensor {
    pub const FIELD_COUNT: usize = 36;
    pub const BITS_PER_FIELD: usize = 6;

    pub fn new(row_count: usize) -> Self {
        assert!(row_count > 0, "row_count must be positive");
        let bits_per_slice = row_count * Self::FIELD_COUNT;
        let bytes_per_slice = (bits_per_slice + 7) / 8;
        let slices = vec![vec![0_u8; bytes_per_slice]; Self::BITS_PER_FIELD];
        Self { row_count, slices }
    }

    /// Read the value (0..63) at (row, field).
    pub fn value_at(&self, row: usize, field: usize) -> u8 {
        assert!(row < self.row_count, "row out of range");
        assert!(field < Self::FIELD_COUNT, "field out of range");
        let mut v = 0_u8;
        for b in 0..Self::BITS_PER_FIELD {
            if self.bit_set(row, field, b) {
                v |= 1 << b;
            }
        }
        v
    }

    /// Write the value (0..63) at (row, field). Value MUST be < 64
    /// (invariant I-6).
    pub fn set_value(&mut self, row: usize, field: usize, value: u8) {
        assert!(row < self.row_count, "row out of range");
        assert!(field < Self::FIELD_COUNT, "field out of range");
        assert!(value < 64, "value must fit in 6 bits (I-6)");
        for b in 0..Self::BITS_PER_FIELD {
            let bit_on = (value >> b) & 1 == 1;
            self.set_bit(row, field, b, bit_on);
        }
    }

    pub fn bit_set(&self, row: usize, field: usize, bit: usize) -> bool {
        let bit_index = row * Self::FIELD_COUNT + field;
        let byte_index = bit_index / 8;
        let bit_in_byte = bit_index % 8;
        (self.slices[bit][byte_index] >> bit_in_byte) & 1 == 1
    }

    pub fn set_bit(&mut self, row: usize, field: usize, bit: usize, on: bool) {
        let bit_index = row * Self::FIELD_COUNT + field;
        let byte_index = bit_index / 8;
        let bit_in_byte = bit_index % 8;
        if on {
            self.slices[bit][byte_index] |= 1 << bit_in_byte;
        } else {
            self.slices[bit][byte_index] &= !(1 << bit_in_byte);
        }
    }

    /// Find all rows where field f has value v. Returns a byte
    /// mask of length ceil(row_count / 8) bits.
    pub fn scan_field_equals(&self, field: usize, value: u8) -> Vec<u8> {
        assert!(field < Self::FIELD_COUNT, "field out of range");
        assert!(value < 64, "value must fit in 6 bits");
        let mask_bytes = (self.row_count + 7) / 8;
        let mut mask = vec![0xFF_u8; mask_bytes];
        for b in 0..Self::BITS_PER_FIELD {
            let bit_on = (value >> b) & 1 == 1;
            for row in 0..self.row_count {
                let actual = self.bit_set(row, field, b);
                if actual != bit_on {
                    mask[row / 8] &= !(1 << (row % 8));
                }
            }
        }
        mask
    }

    /// Enumerate matching row indices from a scan mask.
    pub fn enumerate_matches(&self, mask: &[u8]) -> Vec<usize> {
        let mut hits = Vec::new();
        for row in 0..self.row_count {
            if (mask[row / 8] >> (row % 8)) & 1 == 1 {
                hits.push(row);
            }
        }
        hits
    }

    /// Expand the tensor to `new_row_count` rows. Slice buffers are
    /// resized with zero bytes and `row_count` is updated. No-op if
    /// `new_row_count` ≤ current `row_count`. Existing data preserved.
    pub fn reserve_capacity(&mut self, new_row_count: usize) {
        if new_row_count <= self.row_count { return; }
        let bits_per_slice = new_row_count * Self::FIELD_COUNT;
        let bytes_per_slice = (bits_per_slice + 7) / 8;
        for slice in &mut self.slices {
            slice.resize(bytes_per_slice, 0);
        }
        self.row_count = new_row_count;
    }

    pub fn byte_size(&self) -> usize {
        self.slices.iter().map(|s| s.len()).sum()
    }
}
