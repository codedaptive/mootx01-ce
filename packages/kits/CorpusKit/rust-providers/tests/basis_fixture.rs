//! Shared test helper for the four basis-serialization conformance suites
//! (mission 6a-i). Holds the per-text embedding-pin struct and a tiny inline
//! base64 decoder so the canonical blob (emitted by Swift as base64 inside a
//! JSON fixture) can be recovered without adding an external base64 crate
//! (C-1 doctrine: zero new external dependencies).
//!
//! This file is included via `mod basis_fixture;` from each conformance test
//! binary; it is NOT compiled into the library.

#![allow(dead_code)] // each test binary uses a subset of these items

use serde::Deserialize;

/// One probe-text embedding expectation, mirroring Swift's
/// `BasisEmbeddingEntry` Codable struct (camelCase JSON keys).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BasisEmbeddingEntry {
    pub text: String,
    pub block0: u64,
    pub block1: u64,
    pub block2: u64,
    pub block3: u64,
    pub float_bits: Vec<u32>,
}

/// Decode standard base64 (RFC 4648, `+`/`/` alphabet, `=` padding) into
/// bytes. Minimal, allocation-light, and panics on malformed input — which
/// is appropriate in a test: a malformed fixture is a hard failure.
pub fn decode_base64(s: &str) -> Vec<u8> {
    fn val(c: u8) -> i16 {
        match c {
            b'A'..=b'Z' => (c - b'A') as i16,
            b'a'..=b'z' => (c - b'a' + 26) as i16,
            b'0'..=b'9' => (c - b'0' + 52) as i16,
            b'+' => 62,
            b'/' => 63,
            _ => -1, // padding or whitespace
        }
    }

    let mut out = Vec::with_capacity(s.len() / 4 * 3);
    let mut acc: u32 = 0;
    let mut bits: u32 = 0;
    for &c in s.as_bytes() {
        if c == b'=' {
            break; // padding: no more data
        }
        let v = val(c);
        if v < 0 {
            continue; // skip newlines/whitespace
        }
        acc = (acc << 6) | (v as u32);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_decodes_known_vector() {
        // "Man" → "TWFu"; "any carnal pleasure." → known RFC examples.
        assert_eq!(decode_base64("TWFu"), b"Man");
        assert_eq!(decode_base64("cGxlYXN1cmUu"), b"pleasure.");
        assert_eq!(decode_base64("c3VyZS4="), b"sure.");
        assert_eq!(decode_base64("YW55IGNhcm5hbCBwbGVhc3VyZQ=="), b"any carnal pleasure");
    }

    #[test]
    fn base64_skips_whitespace() {
        assert_eq!(decode_base64("TW\nFu"), b"Man");
    }
}
