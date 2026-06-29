// matrix_c.rs
//
// Correlation matrix C per cookbook § 6.2. Mirror of
// Sources/SubstrateTypes/MatrixC.swift.

use crate::matrix_f::MatrixF;

#[derive(Debug, Clone, PartialEq)]
pub struct MatrixC {
    cells: Vec<f32>,
}

impl MatrixC {
    pub const CELL_COUNT: usize = MatrixF::CELL_COUNT; // 216
    pub const WIRE_BYTES: usize = Self::CELL_COUNT * 4;

    pub fn new() -> Self {
        Self {
            cells: vec![0.0; Self::CELL_COUNT],
        }
    }

    pub fn from_cells(cells: Vec<f32>) -> Self {
        assert_eq!(
            cells.len(),
            Self::CELL_COUNT,
            "MatrixC requires exactly {} cells",
            Self::CELL_COUNT
        );
        Self { cells }
    }

    pub fn cells(&self) -> &[f32] {
        &self.cells
    }

    pub fn get(&self, field: usize, bit: usize) -> f32 {
        self.cells[MatrixF::cell_index(field, bit)]
    }

    pub fn set(&mut self, field: usize, bit: usize, value: f32) {
        self.cells[MatrixF::cell_index(field, bit)] = value;
    }

    /// Compute C from F and N_rows. If N_rows is zero, every cell
    /// is set to zero. Division is performed in f64 then cast to
    /// f32, matching the Swift implementation exactly so that
    /// cross-language bit-identity holds.
    pub fn derive(f: &MatrixF, n_rows: i64) -> Self {
        let mut out = Self::new();
        if n_rows == 0 {
            return out;
        }
        let denom = n_rows as f64;
        let f_cells = f.cells();
        for i in 0..Self::CELL_COUNT {
            let v = (f_cells[i] as f64) / denom;
            out.cells[i] = v as f32;
        }
        out
    }

    // Canonical wire form: 216 × 4 bytes, IEEE-754 f32 LE.

    pub fn write_wire(&self, out: &mut Vec<u8>) {
        for cell in &self.cells {
            out.extend_from_slice(&cell.to_bits().to_le_bytes());
        }
    }

    pub fn read_wire(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != Self::WIRE_BYTES {
            return None;
        }
        let mut cells = vec![0.0f32; Self::CELL_COUNT];
        for i in 0..Self::CELL_COUNT {
            let mut buf = [0u8; 4];
            buf.copy_from_slice(&bytes[i * 4..i * 4 + 4]);
            cells[i] = f32::from_bits(u32::from_le_bytes(buf));
        }
        Some(Self { cells })
    }
}

impl Default for MatrixC {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_rows_gives_zero_matrix() {
        let mut f = MatrixF::new();
        f.set(3, 2, 100);
        f.set(10, 5, 999);
        let c = MatrixC::derive(&f, 0);
        for v in c.cells() {
            assert_eq!(*v, 0.0);
        }
    }

    #[test]
    fn derive_marginal_half() {
        let mut f = MatrixF::new();
        f.set(0, 0, 50);
        let c = MatrixC::derive(&f, 100);
        assert!((c.get(0, 0) - 0.5).abs() < 1e-7);
    }

    #[test]
    fn derive_marginal_one_third() {
        // 1/3 has a non-terminating binary expansion. Check that
        // Swift and Rust produce the same f32 bit pattern for
        // 1.0/3.0 cast: f32 representation of 1/3 = 0x3eaaaaab.
        let mut f = MatrixF::new();
        f.set(0, 0, 1);
        let c = MatrixC::derive(&f, 3);
        assert_eq!(c.get(0, 0).to_bits(), 0x3eaa_aaabu32);
    }

    #[test]
    fn wire_round_trip() {
        let mut c = MatrixC::new();
        c.set(0, 0, 0.5);
        c.set(35, 5, 0.123_456);
        c.set(17, 3, -1.0); // exotic but possible
        let mut bytes = Vec::new();
        c.write_wire(&mut bytes);
        assert_eq!(bytes.len(), MatrixC::WIRE_BYTES);
        let back = MatrixC::read_wire(&bytes).unwrap();
        assert_eq!(back, c);
    }
}
