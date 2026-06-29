// matrix_f.rs
//
// Field-presence matrix F per cookbook § 6.1. Mirror of
// Sources/SubstrateTypes/MatrixF.swift.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MatrixF {
    /// Flat storage. cells[field * 6 + bit] = count of rows where
    /// that bit is set in field's encoding.
    cells: Vec<i64>,
}

impl MatrixF {
    pub const FIELD_COUNT: usize = 36;
    pub const BITS_PER_FIELD: usize = 6;
    pub const CELL_COUNT: usize = Self::FIELD_COUNT * Self::BITS_PER_FIELD; // 216
    pub const WIRE_BYTES: usize = Self::CELL_COUNT * 8;

    pub fn new() -> Self {
        Self {
            cells: vec![0; Self::CELL_COUNT],
        }
    }

    pub fn from_cells(cells: Vec<i64>) -> Self {
        assert_eq!(
            cells.len(),
            Self::CELL_COUNT,
            "MatrixF requires exactly {} cells",
            Self::CELL_COUNT
        );
        Self { cells }
    }

    pub fn cells(&self) -> &[i64] {
        &self.cells
    }

    // Indexing

    #[inline]
    pub fn cell_index(field: usize, bit: usize) -> usize {
        assert!(field < Self::FIELD_COUNT, "field {field} out of range");
        assert!(bit < Self::BITS_PER_FIELD, "bit {bit} out of range");
        field * Self::BITS_PER_FIELD + bit
    }

    pub fn get(&self, field: usize, bit: usize) -> i64 {
        self.cells[Self::cell_index(field, bit)]
    }

    pub fn set(&mut self, field: usize, bit: usize, value: i64) {
        self.cells[Self::cell_index(field, bit)] = value;
    }

    // Update rules

    /// Apply a row's bitmap-tier presence to the matrix.
    /// `delta` is +1 on capture, -1 on expunge. For mutate, call
    /// twice: once with -1 against the old bitmap, once with +1
    /// against the new bitmap.
    pub fn apply_row<F>(&mut self, delta: i64, bit_presence: F)
    where
        F: Fn(usize, usize) -> bool,
    {
        if delta == 0 {
            return;
        }
        for field in 0..Self::FIELD_COUNT {
            for bit in 0..Self::BITS_PER_FIELD {
                if bit_presence(field, bit) {
                    let idx = Self::cell_index(field, bit);
                    self.cells[idx] = self.cells[idx].wrapping_add(delta);
                }
            }
        }
    }

    pub fn total_count(&self) -> i64 {
        let mut sum: i64 = 0;
        for c in &self.cells {
            sum = sum.wrapping_add(*c);
        }
        sum
    }

    pub fn reset(&mut self) {
        for c in self.cells.iter_mut() {
            *c = 0;
        }
    }

    // Canonical wire form: 216 × 8 bytes, all LE.

    pub fn write_wire(&self, out: &mut Vec<u8>) {
        for c in &self.cells {
            out.extend_from_slice(&c.to_le_bytes());
        }
    }

    pub fn read_wire(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != Self::WIRE_BYTES {
            return None;
        }
        let mut cells = vec![0i64; Self::CELL_COUNT];
        for i in 0..Self::CELL_COUNT {
            let mut buf = [0u8; 8];
            buf.copy_from_slice(&bytes[i * 8..i * 8 + 8]);
            cells[i] = i64::from_le_bytes(buf);
        }
        Some(Self { cells })
    }
}

impl Default for MatrixF {
    fn default() -> Self {
        Self::new()
    }
}

// Properties
//
//   linearity:   apply_row(delta=k, p) followed by apply_row(delta=-k, p)
//                restores the original matrix (modulo wrap; we use
//                wrapping_add which is overflow-safe).
//   monotone-on-capture: with only delta=+1, every cell is non-negative.
//   reset-idempotent: reset() applied twice equals reset() applied once.

#[cfg(test)]
mod tests {
    use super::*;

    fn always_set(_f: usize, _b: usize) -> bool {
        true
    }

    fn never_set(_f: usize, _b: usize) -> bool {
        false
    }

    #[test]
    fn fresh_matrix_zero() {
        let m = MatrixF::new();
        assert_eq!(m.total_count(), 0);
        assert_eq!(m.cells().len(), MatrixF::CELL_COUNT);
    }

    #[test]
    fn apply_row_all_set_capture() {
        let mut m = MatrixF::new();
        m.apply_row(1, always_set);
        assert_eq!(m.total_count(), MatrixF::CELL_COUNT as i64);
        for c in m.cells() {
            assert_eq!(*c, 1);
        }
    }

    #[test]
    fn apply_row_inverse() {
        let mut m = MatrixF::new();
        let row_pattern = |f: usize, b: usize| (f + b) % 2 == 0;
        m.apply_row(1, row_pattern);
        m.apply_row(-1, row_pattern);
        assert_eq!(m.total_count(), 0);
    }

    #[test]
    fn never_set_is_noop() {
        let mut m = MatrixF::new();
        m.apply_row(1, never_set);
        assert_eq!(m.total_count(), 0);
    }

    #[test]
    fn wire_round_trip() {
        let mut m = MatrixF::new();
        m.set(0, 0, 42);
        m.set(35, 5, -7);
        m.set(17, 3, 1_000_000);
        let mut bytes = Vec::new();
        m.write_wire(&mut bytes);
        assert_eq!(bytes.len(), MatrixF::WIRE_BYTES);
        let back = MatrixF::read_wire(&bytes).unwrap();
        assert_eq!(back, m);
    }
}
