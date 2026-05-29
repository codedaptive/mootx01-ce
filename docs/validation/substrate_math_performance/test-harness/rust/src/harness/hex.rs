// src/harness/hex.rs
//
// Hex coding. Same rules as the Swift harness's HexCoding.swift.
// Lowercase "0x..." everywhere; no padding except fixed-width
// types (f64 → 16 hex digits; u32 → 8 hex digits; u64 → 16 hex
// digits).

const LOWER: &[u8; 16] = b"0123456789abcdef";

pub fn encode_hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(2 + bytes.len() * 2);
    s.push_str("0x");
    for &b in bytes {
        s.push(LOWER[(b >> 4) as usize] as char);
        s.push(LOWER[(b & 0x0F) as usize] as char);
    }
    s
}

pub fn decode_hex(input: &str) -> Result<Vec<u8>, HexError> {
    let stripped = input
        .strip_prefix("0x")
        .or_else(|| input.strip_prefix("0X"))
        .unwrap_or(input);
    if stripped.len() % 2 != 0 {
        return Err(HexError::OddLength(input.to_owned()));
    }
    let mut out = Vec::with_capacity(stripped.len() / 2);
    let bytes = stripped.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let hi = hex_nibble(bytes[i]).ok_or_else(|| {
            HexError::InvalidCharacter(format!(
                "{}{}",
                bytes[i] as char,
                bytes[i + 1] as char
            ))
        })?;
        let lo = hex_nibble(bytes[i + 1]).ok_or_else(|| {
            HexError::InvalidCharacter(format!(
                "{}{}",
                bytes[i] as char,
                bytes[i + 1] as char
            ))
        })?;
        out.push((hi << 4) | lo);
        i += 2;
    }
    Ok(out)
}

fn hex_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

pub fn u8_hex(v: u8) -> String {
    encode_hex(&[v])
}

pub fn u16_hex(v: u16) -> String {
    encode_hex(&v.to_le_bytes())
}

pub fn u32_hex(v: u32) -> String {
    encode_hex(&v.to_le_bytes())
}

pub fn u64_hex(v: u64) -> String {
    encode_hex(&v.to_le_bytes())
}

/// f64 as the IEEE-754 bit pattern, always 16 hex digits.
pub fn f64_hex(v: f64) -> String {
    u64_hex(v.to_bits())
}

/// f32 as the IEEE-754 bit pattern, always 8 hex digits.
pub fn f32_hex(v: f32) -> String {
    u32_hex(v.to_bits())
}

#[derive(Debug, Clone)]
pub enum HexError {
    OddLength(String),
    InvalidCharacter(String),
}

impl std::fmt::Display for HexError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HexError::OddLength(s) => write!(f, "hex string has odd length: {s}"),
            HexError::InvalidCharacter(s) => write!(f, "invalid hex characters: {s}"),
        }
    }
}

impl std::error::Error for HexError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn u64_round_trip() {
        let v: u64 = 0xDEAD_BEEF_CAFE_BABE;
        let h = u64_hex(v);
        assert_eq!(h, "0xbebafecaefbeadde"); // LE bytes
        let bytes = decode_hex(&h).unwrap();
        assert_eq!(bytes.len(), 8);
        let mut back = 0u64;
        for (i, b) in bytes.iter().enumerate() {
            back |= (*b as u64) << (i * 8);
        }
        assert_eq!(back, v);
    }

    #[test]
    fn f64_round_trip() {
        let v: f64 = 4.0;
        let h = f64_hex(v);
        assert_eq!(h, "0x0000000000001040");
        let bytes = decode_hex(&h).unwrap();
        let mut bits = 0u64;
        for (i, b) in bytes.iter().enumerate() {
            bits |= (*b as u64) << (i * 8);
        }
        assert_eq!(f64::from_bits(bits), v);
    }
}
