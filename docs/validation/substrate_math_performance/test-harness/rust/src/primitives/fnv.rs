// src/primitives/fnv.rs
//
// Mirror of Swift FNVPrimitive.swift. Calls the real reference at
// glref-rust-fnv.rs via substrate-lib (aliased as substrate_kit
// in this crate).
//
// The primitive exercises all three FNV-1a entry points the
// substrate exports: hash64, hash32, and the 16-bit fold of
// hash64. Cases cycle through the three ops via the `op` field.
//
// Input schema:
//   op : u8 (0 = hash64, 1 = hash32, 2 = hash16)
//   s  : utf-8 string
//
// Output schema:
//   result : u64 (hex, zero-extended for hash32 / hash16)

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::decode_hex,
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_types::fnv;

pub struct FNVPrimitive;

impl FNVPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "fnv",
            cookbook_section: "§3.3",
            reference_file: "glref-rust-fnv.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let op: u8 = (i % 3) as u8;
            // Mirror the Swift `length = 1 + Int(rng.next() % 24)` step
            // exactly: two RNG draws per case (length, then string body).
            let length = 1 + (rng.next() % 24) as usize;
            let s = random_string(&mut rng, length);

            let result: u64 = match op {
                0 => fnv::hash64(&s),
                1 => fnv::hash32(&s) as u64,
                _ => fnv::hash16(&s) as u64,
            };

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("op".into(), JsonValue::String(format!("0x{:02x}", op)));
            inputs.insert("s".into(), JsonValue::String(s.clone()));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("result".into(), JsonValue::String(encode_u64_le(result)));

            let op_name = match op {
                0 => "hash64",
                1 => "hash32",
                _ => "hash16",
            };
            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!("op {}, len {}", op_name, s.len()),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "fnv".to_string(),
            cookbook_section: "§3.3".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-fnv.rs".to_string(),
            },
            seed,
            generated_at: iso_timestamp(),
            output_crc32: crc,
            cases,
        })
    }

    pub fn validate(file: &VectorFile) -> Result<ValidationResult, Box<dyn std::error::Error>> {
        let mut case_results = Vec::with_capacity(file.cases.len());
        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &file.cases { case_results.push(validate_case(c, &mut encoder)); }
        let crc_actual = CRC32::compute(encoder.as_slice());
        let all_passed = case_results.iter().all(|r| r.passed);
        Ok(ValidationResult {
            passed: all_passed && crc_actual == file.output_crc32,
            case_results,
            crc_expected: file.output_crc32,
            crc_actual,
        })
    }
}

fn validate_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let op = match c.inputs.get("op") {
        Some(JsonValue::String(s)) => match parse_u8(s) {
            Some(v) => v,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed op".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing op".into()) },
    };
    let s = match c.inputs.get("s") {
        Some(JsonValue::String(v)) => v.clone(),
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing s".into()) },
    };

    let actual: u64 = match op {
        0 => fnv::hash64(&s),
        1 => fnv::hash32(&s) as u64,
        2 => fnv::hash16(&s) as u64,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some(format!("unknown op {}", op)) },
    };

    let expected = match c.expected_output.get("result") {
        Some(JsonValue::String(s)) => match parse_u64(s) {
            Some(v) => v,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed expected result".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected result".into()) },
    };

    encoder.write_u64(actual);

    if actual == expected {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "result mismatch: expected 0x{:x}, got 0x{:x}", expected, actual)),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let raw = match output.get("result") {
        Some(JsonValue::String(s)) => parse_u64(s).expect("malformed result"),
        _ => panic!("expected_output missing result"),
    };
    encoder.write_u64(raw);
}

/// Build a deterministic string from the RNG. Uses the same
/// printable-ASCII alphabet as the Swift mirror so both languages
/// produce identical UTF-8 byte streams from the same seed.
fn random_string(rng: &mut SplitMix64, length: usize) -> String {
    let alphabet: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
    let mut bytes = Vec::with_capacity(length);
    for _ in 0..length {
        let r = rng.next();
        bytes.push(alphabet[(r as usize) % alphabet.len()]);
    }
    String::from_utf8(bytes).expect("alphabet is pure ASCII, never invalid UTF-8")
}

fn parse_u8(s: &str) -> Option<u8> {
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    u8::from_str_radix(stripped, 16).ok()
}

/// Parse a HexCoding.u64-encoded string: 16 hex chars representing
/// 8 LE bytes (byte 0 = LSB). Matches the Swift convention.
fn parse_u64(s: &str) -> Option<u64> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 { return None; }
    let mut v: u64 = 0;
    for i in 0..8 { v |= (bytes[i] as u64) << (i * 8); }
    Some(v)
}

/// Mirror Swift HexCoding.u64: 8 bytes little-endian, hex-encoded
/// with a `0x` prefix.
fn encode_u64_le(v: u64) -> String {
    let mut s = String::with_capacity(2 + 16);
    s.push_str("0x");
    for i in 0..8 {
        let b = ((v >> (i * 8)) & 0xff) as u8;
        s.push_str(&format!("{:02x}", b));
    }
    s
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
