// matrix_t.rs
//
// Temporal causality matrix T per cookbook § 6.4. Mirror of
// Sources/SubstrateTypes/MatrixT.swift.

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CausalityKey {
    pub source_field: u8,
    pub source_value: u8,
    pub target_field: u8,
    pub target_value: u8,
    pub lag_bucket: u8, // 0..7
}

impl CausalityKey {
    pub fn new(
        source_field: u8,
        source_value: u8,
        target_field: u8,
        target_value: u8,
        lag_bucket: u8,
    ) -> Self {
        assert!(source_field < 64 && target_field < 64,
                "field index must fit in 6 bits");
        assert!(source_value < 64 && target_value < 64,
                "field value must fit in 6 bits (I-15)");
        assert!(lag_bucket < 8, "lag bucket must be 0..7");
        Self {
            source_field,
            source_value,
            target_field,
            target_value,
            lag_bucket,
        }
    }

    /// Packed u64. Layout (high → low):
    ///   source_field:8 | source_value:8 | target_field:8 |
    ///   target_value:8 | lag_bucket:8 | unused:24.
    #[inline]
    pub fn packed(&self) -> u64 {
        ((self.source_field as u64) << 56)
            | ((self.source_value as u64) << 48)
            | ((self.target_field as u64) << 40)
            | ((self.target_value as u64) << 32)
            | ((self.lag_bucket as u64) << 24)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct MatrixT {
    entries: Vec<(CausalityKey, i64)>,
}

impl MatrixT {
    pub const BUCKET_EDGES_MINUTES: [i32; 8] = [1, 2, 4, 8, 16, 32, 64, 128];
    pub const MAX_LAG_MINUTES: i32 = 256;

    /// Bucket index for a time difference in minutes, or None if
    /// out of range (< 1 or >= 256).
    pub fn lag_bucket(minutes: i32) -> Option<u8> {
        if minutes < 1 || minutes >= Self::MAX_LAG_MINUTES {
            return None;
        }
        let mut b: u8 = 0;
        for k in 0..Self::BUCKET_EDGES_MINUTES.len() {
            if Self::BUCKET_EDGES_MINUTES[k] <= minutes {
                b = k as u8;
            } else {
                break;
            }
        }
        Some(b)
    }

    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    pub fn entries(&self) -> &[(CausalityKey, i64)] {
        &self.entries
    }

    pub fn entry_count(&self) -> usize {
        self.entries.len()
    }

    pub fn count(&self, key: CausalityKey) -> i64 {
        match self
            .entries
            .binary_search_by_key(&key.packed(), |e| e.0.packed())
        {
            Ok(idx) => self.entries[idx].1,
            Err(_) => 0,
        }
    }

    pub fn total_count(&self) -> i64 {
        let mut sum: i64 = 0;
        for (_, c) in &self.entries {
            sum = sum.wrapping_add(*c);
        }
        sum
    }

    pub fn increment(&mut self, key: CausalityKey, delta: i64) {
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

    /// Apply an ordered pair (row_a precedes row_b by lag_minutes).
    /// If lag_minutes is out of range, no update is performed.
    pub fn apply_pair(
        &mut self,
        delta: i64,
        row_a_field_values: &[(u8, u8)],
        row_b_field_values: &[(u8, u8)],
        lag_minutes: i32,
    ) {
        if delta == 0 {
            return;
        }
        let bucket = match Self::lag_bucket(lag_minutes) {
            Some(b) => b,
            None => return,
        };
        for &a in row_a_field_values {
            for &b in row_b_field_values {
                let key = CausalityKey::new(a.0, a.1, b.0, b.1, bucket);
                self.increment(key, delta);
            }
        }
    }

    pub fn reset(&mut self) {
        self.entries.clear();
    }

    // Canonical wire form: u32 LE count, then per entry:
    //   packed key u64 LE, count i64 LE.

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
        let mut nbuf = [0u8; 4];
        nbuf.copy_from_slice(&bytes[0..4]);
        let n = u32::from_le_bytes(nbuf) as usize;
        let expected = 4 + n * (8 + 8);
        if bytes.len() != expected {
            return None;
        }
        let mut entries = Vec::with_capacity(n);
        let mut off = 4;
        for _ in 0..n {
            let mut kbuf = [0u8; 8];
            kbuf.copy_from_slice(&bytes[off..off + 8]);
            off += 8;
            let packed = u64::from_le_bytes(kbuf);
            let mut cbuf = [0u8; 8];
            cbuf.copy_from_slice(&bytes[off..off + 8]);
            off += 8;
            let count = i64::from_le_bytes(cbuf);
            let key = CausalityKey {
                source_field: ((packed >> 56) & 0xFF) as u8,
                source_value: ((packed >> 48) & 0xFF) as u8,
                target_field: ((packed >> 40) & 0xFF) as u8,
                target_value: ((packed >> 32) & 0xFF) as u8,
                lag_bucket: ((packed >> 24) & 0xFF) as u8,
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
    fn lag_bucket_boundaries() {
        assert_eq!(MatrixT::lag_bucket(0), None);
        assert_eq!(MatrixT::lag_bucket(1), Some(0));
        assert_eq!(MatrixT::lag_bucket(2), Some(1));
        assert_eq!(MatrixT::lag_bucket(3), Some(1));
        assert_eq!(MatrixT::lag_bucket(4), Some(2));
        assert_eq!(MatrixT::lag_bucket(15), Some(3));
        assert_eq!(MatrixT::lag_bucket(16), Some(4));
        assert_eq!(MatrixT::lag_bucket(127), Some(6));
        assert_eq!(MatrixT::lag_bucket(128), Some(7));
        assert_eq!(MatrixT::lag_bucket(255), Some(7));
        assert_eq!(MatrixT::lag_bucket(256), None);
        assert_eq!(MatrixT::lag_bucket(1000), None);
    }

    #[test]
    fn apply_pair_creates_cross_product() {
        let mut t = MatrixT::new();
        let a = vec![(0u8, 1u8), (5u8, 3u8)];
        let b = vec![(2u8, 0u8)];
        t.apply_pair(1, &a, &b, 10); // lag minutes = 10 → bucket 3
        assert_eq!(t.entry_count(), 2);
        assert_eq!(
            t.count(CausalityKey::new(0, 1, 2, 0, 3)),
            1
        );
        assert_eq!(
            t.count(CausalityKey::new(5, 3, 2, 0, 3)),
            1
        );
    }

    #[test]
    fn apply_pair_out_of_range_is_noop() {
        let mut t = MatrixT::new();
        let a = vec![(0u8, 1u8)];
        let b = vec![(2u8, 0u8)];
        t.apply_pair(1, &a, &b, 300);
        assert_eq!(t.entry_count(), 0);
        t.apply_pair(1, &a, &b, 0);
        assert_eq!(t.entry_count(), 0);
    }

    #[test]
    fn asymmetric_storage() {
        let mut t = MatrixT::new();
        let key_ab = CausalityKey::new(0, 1, 5, 3, 2);
        let key_ba = CausalityKey::new(5, 3, 0, 1, 2);
        t.increment(key_ab, 3);
        assert_eq!(t.count(key_ab), 3);
        assert_eq!(t.count(key_ba), 0); // distinct cell
    }

    #[test]
    fn wire_round_trip() {
        let mut t = MatrixT::new();
        t.increment(CausalityKey::new(0, 1, 2, 3, 0), 42);
        t.increment(CausalityKey::new(10, 5, 20, 4, 7), -17);
        let mut bytes = Vec::new();
        t.write_wire(&mut bytes);
        let back = MatrixT::read_wire(&bytes).unwrap();
        assert_eq!(back, t);
    }
}
