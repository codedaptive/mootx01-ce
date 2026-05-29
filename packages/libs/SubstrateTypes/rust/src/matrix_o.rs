// matrix_o.rs
//
// Co-occurrence matrix O per cookbook § 6.3. Mirror of
// glref-swift-MatrixO.swift.

/// Canonical 4-byte key for an O-matrix cell. Field indices are
/// 0..63 (6 bits, anticipating §11.x growth); values are 0..63
/// (6 bits, the field-width floor I-15).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CooccurrenceKey {
    pub field_i: u8,
    pub value_i: u8,
    pub field_j: u8,
    pub value_j: u8,
}

impl CooccurrenceKey {
    pub fn new(field_i: u8, value_i: u8, field_j: u8, value_j: u8) -> Self {
        assert!(field_i < 64 && field_j < 64, "field index must fit in 6 bits");
        assert!(value_i < 64 && value_j < 64, "field value must fit in 6 bits (I-15)");
        Self {
            field_i,
            value_i,
            field_j,
            value_j,
        }
    }

    /// Packed u32 ordering, matching the Swift packed layout.
    /// Layout (high → low): field_i:8 | value_i:8 | field_j:8 | value_j:8.
    #[inline]
    pub fn packed(&self) -> u32 {
        ((self.field_i as u32) << 24)
            | ((self.value_i as u32) << 16)
            | ((self.field_j as u32) << 8)
            | (self.value_j as u32)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MatrixO {
    /// Sorted (by key.packed ascending) list of non-zero cells.
    entries: Vec<(CooccurrenceKey, i64)>,
}

impl MatrixO {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    pub fn entries(&self) -> &[(CooccurrenceKey, i64)] {
        &self.entries
    }

    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    /// Returns the count for a key, zero if not present.
    pub fn count(&self, key: CooccurrenceKey) -> i64 {
        match self
            .entries
            .binary_search_by_key(&key.packed(), |e| e.0.packed())
        {
            Ok(idx) => self.entries[idx].1,
            Err(_) => 0,
        }
    }

    /// Increment one cell by `delta`. Inserts if absent, drops if
    /// zero after increment.
    pub fn increment(&mut self, key: CooccurrenceKey, delta: i64) {
        if delta == 0 {
            return;
        }
        match self
            .entries
            .binary_search_by_key(&key.packed(), |e| e.0.packed())
        {
            Ok(idx) => {
                let new_count = self.entries[idx].1.wrapping_add(delta);
                if new_count == 0 {
                    self.entries.remove(idx);
                } else {
                    self.entries[idx].1 = new_count;
                }
            }
            Err(idx) => {
                self.entries.insert(idx, (key, delta));
            }
        }
    }

    /// Apply a row's (field, value) presence to the matrix.
    /// Iterates all ordered pairs (including i == j) per cookbook
    /// § 6.3.
    pub fn apply_row(&mut self, delta: i64, field_values: &[(u8, u8)]) {
        if delta == 0 {
            return;
        }
        for &a in field_values {
            for &b in field_values {
                let key = CooccurrenceKey::new(a.0, a.1, b.0, b.1);
                self.increment(key, delta);
            }
        }
    }

    pub fn total_count(&self) -> i64 {
        let mut sum: i64 = 0;
        for (_, c) in &self.entries {
            sum = sum.wrapping_add(*c);
        }
        sum
    }

    pub fn reset(&mut self) {
        self.entries.clear();
    }

    // Canonical wire form: u32 LE count, then for each entry:
    //   packed key u32 LE, count i64 LE.

    pub fn write_wire(&self, out: &mut Vec<u8>) {
        let n = self.entries.len() as u32;
        out.extend_from_slice(&n.to_le_bytes());
        for (key, count) in &self.entries {
            out.extend_from_slice(&key.packed().to_le_bytes());
            out.extend_from_slice(&count.to_le_bytes());
        }
    }

    pub fn read_wire(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < 4 {
            return None;
        }
        let mut buf = [0u8; 4];
        buf.copy_from_slice(&bytes[0..4]);
        let n = u32::from_le_bytes(buf) as usize;
        let expected = 4 + n * (4 + 8);
        if bytes.len() != expected {
            return None;
        }
        let mut entries = Vec::with_capacity(n);
        let mut off = 4;
        for _ in 0..n {
            let mut kbuf = [0u8; 4];
            kbuf.copy_from_slice(&bytes[off..off + 4]);
            off += 4;
            let packed = u32::from_le_bytes(kbuf);
            let mut cbuf = [0u8; 8];
            cbuf.copy_from_slice(&bytes[off..off + 8]);
            off += 8;
            let count = i64::from_le_bytes(cbuf);
            let key = CooccurrenceKey {
                field_i: ((packed >> 24) & 0xFF) as u8,
                value_i: ((packed >> 16) & 0xFF) as u8,
                field_j: ((packed >> 8) & 0xFF) as u8,
                value_j: (packed & 0xFF) as u8,
            };
            entries.push((key, count));
        }
        Some(Self { entries })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_matrix_zero_counts() {
        let o = MatrixO::new();
        let k = CooccurrenceKey::new(0, 0, 0, 0);
        assert_eq!(o.count(k), 0);
        assert_eq!(o.entry_count(), 0);
    }

    #[test]
    fn increment_and_query() {
        let mut o = MatrixO::new();
        let k = CooccurrenceKey::new(3, 2, 5, 4);
        o.increment(k, 5);
        assert_eq!(o.count(k), 5);
        o.increment(k, -3);
        assert_eq!(o.count(k), 2);
        o.increment(k, -2);
        assert_eq!(o.count(k), 0);
        assert_eq!(o.entry_count(), 0); // dropped when zero
    }

    #[test]
    fn apply_row_diagonal_and_pairs() {
        let mut o = MatrixO::new();
        // Two fields with values: field 0 = value 1, field 5 = value 3.
        let pairs = vec![(0u8, 1u8), (5u8, 3u8)];
        o.apply_row(1, &pairs);
        // Four cells expected: (0,1)x(0,1), (0,1)x(5,3),
        // (5,3)x(0,1), (5,3)x(5,3).
        assert_eq!(o.entry_count(), 4);
        assert_eq!(o.count(CooccurrenceKey::new(0, 1, 0, 1)), 1);
        assert_eq!(o.count(CooccurrenceKey::new(0, 1, 5, 3)), 1);
        assert_eq!(o.count(CooccurrenceKey::new(5, 3, 0, 1)), 1);
        assert_eq!(o.count(CooccurrenceKey::new(5, 3, 5, 3)), 1);
    }

    #[test]
    fn apply_row_inverse_clears() {
        let mut o = MatrixO::new();
        let pairs = vec![(0u8, 1u8), (5u8, 3u8)];
        o.apply_row(1, &pairs);
        o.apply_row(-1, &pairs);
        assert_eq!(o.entry_count(), 0);
        assert_eq!(o.total_count(), 0);
    }

    #[test]
    fn entries_sorted_by_packed_key() {
        let mut o = MatrixO::new();
        o.increment(CooccurrenceKey::new(5, 3, 5, 3), 1);
        o.increment(CooccurrenceKey::new(0, 1, 0, 1), 1);
        o.increment(CooccurrenceKey::new(5, 3, 0, 1), 1);
        let packed: Vec<u32> = o.entries().iter().map(|e| e.0.packed()).collect();
        let mut sorted = packed.clone();
        sorted.sort();
        assert_eq!(packed, sorted);
    }

    #[test]
    fn wire_round_trip() {
        let mut o = MatrixO::new();
        o.increment(CooccurrenceKey::new(0, 1, 5, 3), 42);
        o.increment(CooccurrenceKey::new(10, 5, 20, 4), -17);
        let mut bytes = Vec::new();
        o.write_wire(&mut bytes);
        let back = MatrixO::read_wire(&bytes).unwrap();
        assert_eq!(back, o);
    }
}
