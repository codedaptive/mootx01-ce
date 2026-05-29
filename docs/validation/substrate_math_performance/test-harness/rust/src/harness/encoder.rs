// src/harness/encoder.rs
//
// Canonical binary encoder. Same rules as the Swift harness's
// CanonicalBinaryEncoder.swift.
//
// All integers little-endian. f64 as IEEE-754 bit pattern LE.
// Bool as 1 byte. Option<T> as tag + payload. Vec<T> as u32 LE
// length + elements. String as u32 LE length + UTF-8.

#[derive(Default)]
pub struct CanonicalBinaryEncoder {
    bytes: Vec<u8>,
}

impl CanonicalBinaryEncoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.bytes
    }

    // Unsigned ints
    pub fn write_u8(&mut self, v: u8) {
        self.bytes.push(v);
    }
    pub fn write_u16(&mut self, v: u16) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn write_u32(&mut self, v: u32) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn write_u64(&mut self, v: u64) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }

    // Signed ints (two's complement LE)
    pub fn write_i8(&mut self, v: i8) {
        self.bytes.push(v as u8);
    }
    pub fn write_i16(&mut self, v: i16) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn write_i32(&mut self, v: i32) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn write_i64(&mut self, v: i64) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }

    // Floats
    pub fn write_f64(&mut self, v: f64) {
        self.write_u64(v.to_bits());
    }
    pub fn write_f32(&mut self, v: f32) {
        self.write_u32(v.to_bits());
    }

    // Bool
    pub fn write_bool(&mut self, v: bool) {
        self.write_u8(if v { 1 } else { 0 });
    }

    // Option
    pub fn write_option<T>(&mut self, v: &Option<T>, mut encode: impl FnMut(&mut Self, &T)) {
        match v {
            None => self.write_u8(0),
            Some(inner) => {
                self.write_u8(1);
                encode(self, inner);
            }
        }
    }

    // Raw bytes
    pub fn write_bytes(&mut self, raw: &[u8]) {
        self.bytes.extend_from_slice(raw);
    }

    // Length-prefixed array
    pub fn write_array<T>(&mut self, items: &[T], mut encode: impl FnMut(&mut Self, &T)) {
        assert!(
            items.len() <= u32::MAX as usize,
            "array too long for u32 length prefix"
        );
        self.write_u32(items.len() as u32);
        for item in items {
            encode(self, item);
        }
    }

    // Length-prefixed UTF-8 string
    pub fn write_string(&mut self, s: &str) {
        let bytes = s.as_bytes();
        assert!(
            bytes.len() <= u32::MAX as usize,
            "string too long for u32 length prefix"
        );
        self.write_u32(bytes.len() as u32);
        self.bytes.extend_from_slice(bytes);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn u64_little_endian() {
        let mut e = CanonicalBinaryEncoder::new();
        e.write_u64(0x0102_0304_0506_0708);
        assert_eq!(
            e.into_bytes(),
            vec![0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
        );
    }

    #[test]
    fn f64_is_bit_pattern() {
        let mut e = CanonicalBinaryEncoder::new();
        e.write_f64(4.0);
        // 4.0 IEEE-754 bits = 0x4010_0000_0000_0000.
        assert_eq!(
            e.into_bytes(),
            vec![0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x40]
        );
    }

    #[test]
    fn bool_encoding() {
        let mut e = CanonicalBinaryEncoder::new();
        e.write_bool(true);
        e.write_bool(false);
        assert_eq!(e.into_bytes(), vec![0x01, 0x00]);
    }
}
