// src/harness/crc32.rs
//
// CRC-32/ISO-HDLC implementation. Same polynomial and parameters
// as the Swift harness's CRC32.swift; mirrors zlib `crc32`.
//
// Parameters:
//   polynomial   0xEDB88320 (reversed 0x04C11DB7)
//   initial      0xFFFFFFFF
//   input refl   true
//   output refl  true
//   output XOR   0xFFFFFFFF

const fn build_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut c: u32 = i as u32;
        let mut j = 0;
        while j < 8 {
            if c & 1 == 1 {
                c = 0xEDB8_8320 ^ (c >> 1);
            } else {
                c >>= 1;
            }
            j += 1;
        }
        table[i] = c;
        i += 1;
    }
    table
}

static TABLE: [u32; 256] = build_table();

pub struct CRC32 {
    state: u32,
}

impl Default for CRC32 {
    fn default() -> Self {
        Self::new()
    }
}

impl CRC32 {
    pub fn new() -> Self {
        Self {
            state: 0xFFFF_FFFF,
        }
    }

    pub fn update(&mut self, bytes: &[u8]) {
        let mut s = self.state;
        for &b in bytes {
            let idx = ((s ^ (b as u32)) & 0xFF) as usize;
            s = (s >> 8) ^ TABLE[idx];
        }
        self.state = s;
    }

    pub fn finalize(self) -> u32 {
        self.state ^ 0xFFFF_FFFF
    }

    pub fn compute(bytes: &[u8]) -> u32 {
        let mut c = Self::new();
        c.update(bytes);
        c.finalize()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_is_zero() {
        assert_eq!(CRC32::compute(&[]), 0);
    }

    #[test]
    fn known_vector_123456789() {
        // ASCII "123456789" → 0xCBF43926
        let input = b"123456789";
        assert_eq!(CRC32::compute(input), 0xCBF4_3926);
    }
}
