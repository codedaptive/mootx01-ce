// src/primitives/bit_field_masked_equals.rs
//
// Mirror of Swift BitFieldMaskedEqualsPrimitive.swift. Calls the
// real reference at glref-rust-bit_field.rs via substrate-lib
// (aliased as substrate_kit in this crate).
//
// BitField masked-equality predicate (cookbook §2.8 / §7.7). F18.2b
// — promotes the kit-local `andMask` AND+compare pattern to a
// substrate-gated primitive.
//
// Input schema:
//   bitmap   : i64 (hex, u64 bit-pattern encoding)
//   mask     : i64 (hex, u64 bit-pattern encoding)
//   expected : i64 (hex, u64 bit-pattern encoding)
//
// Output schema:
//   result : bool (hex u8, 0x00 = false, 0x01 = true)
//
// Case construction and RNG draw pattern match the Swift mirror
// one-for-one so the shared vector is byte-identical across ports:
// 10 hand-rolled corner triples in fixed order, then 22 PRNG cases
// where even j draws three values (bitmap, mask, expected) and odd
// j draws two (bitmap, mask) with expected = bitmap & mask.

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

use substrate_kit::bit_field;

pub struct BitFieldMaskedEqualsPrimitive;

// (bitmap, mask, expected, label) — fixed-order corner cases that
// exercise the documented edges of masked_equals. MUST match the
// Swift mirror's cornerCases array exactly.
const CORNER_CASES: &[(i64, i64, i64, &str)] = &[
    (0,                       0,                       0,                       "all_zero"),
    (-1,                      -1,                      -1,                      "all_ones"),
    (0,                       0xFF,                    0x12,                    "zero_bitmap_nonzero_expected"),
    (0xFF,                    0,                       0,                       "zero_mask_zero_expected"),
    (0xFF,                    0,                       0x42,                    "zero_mask_nonzero_expected"),
    (0x12345678,              0xFF00,                  0x5600,                  "post_mask_aligned_match"),
    (0x12345678,              0xFF00,                  0x5601,                  "expected_bit_outside_mask"),
    (-1,                      0xF,                     0xF,                     "sign_bit_low_nibble"),
    (0x0000_0003_0000_0000,   0x0000_003F_0000_0000,   0x0000_0003_0000_0000,   "cookbook_state_field"),
    (0x0000_003F_0000_0000,   0x0000_003F_0000_0000,   0x0000_0003_0000_0000,   "field_full_expected_partial"),
];

impl BitFieldMaskedEqualsPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "bit_field_masked_equals",
            cookbook_section: "§2.8",
            reference_file: "glref-rust-bit_field.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let total_cases = 32usize;
        let mut cases = Vec::with_capacity(total_cases);

        // Hand-rolled corners first.
        for (i, &(bitmap, mask, expected, label)) in CORNER_CASES.iter().enumerate() {
            let result = bit_field::masked_equals(bitmap, mask, expected);
            cases.push(make_case(i, bitmap, mask, expected, result,
                                 format!("corner: {}", label)));
        }

        // PRNG-driven cases. Even j: independent expected (3 draws).
        // Odd j: expected = bitmap & mask (2 draws). Matches Swift.
        let prng_count = total_cases - CORNER_CASES.len();
        for j in 0..prng_count {
            let bitmap = rng.next() as i64;
            let mask = rng.next() as i64;
            let expected: i64 = if j % 2 == 0 {
                rng.next() as i64
            } else {
                bitmap & mask
            };
            let result = bit_field::masked_equals(bitmap, mask, expected);
            let desc = if j % 2 == 0 { "prng: independent" } else { "prng: aligned" };
            cases.push(make_case(CORNER_CASES.len() + j, bitmap, mask, expected,
                                 result, desc.to_string()));
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "bit_field_masked_equals".to_string(),
            cookbook_section: "§2.8".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-bit_field.rs".to_string(),
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
    let bitmap = match c.inputs.get("bitmap") {
        Some(JsonValue::String(s)) => match parse_i64(s) {
            Some(v) => v,
            None => return fail(c, "malformed bitmap"),
        },
        _ => return fail(c, "missing bitmap"),
    };
    let mask = match c.inputs.get("mask") {
        Some(JsonValue::String(s)) => match parse_i64(s) {
            Some(v) => v,
            None => return fail(c, "malformed mask"),
        },
        _ => return fail(c, "missing mask"),
    };
    let expected_in = match c.inputs.get("expected") {
        Some(JsonValue::String(s)) => match parse_i64(s) {
            Some(v) => v,
            None => return fail(c, "malformed expected"),
        },
        _ => return fail(c, "missing expected"),
    };

    let actual = bit_field::masked_equals(bitmap, mask, expected_in);

    let expected_byte = match c.expected_output.get("result") {
        Some(JsonValue::String(s)) => match parse_u8(s) {
            Some(v) => v,
            None => return fail(c, "malformed expected result"),
        },
        _ => return fail(c, "missing expected result"),
    };
    let expected_result = expected_byte != 0;

    encoder.write_u8(if actual { 1 } else { 0 });

    if actual == expected_result {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "result mismatch: expected {}, got {}", expected_result, actual)),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let byte = match output.get("result") {
        Some(JsonValue::String(s)) => parse_u8(s).expect("malformed result"),
        _ => panic!("expected_output missing result"),
    };
    encoder.write_u8(byte);
}

fn make_case(index: usize, bitmap: i64, mask: i64, expected: i64,
             result: bool, description: String) -> VectorCase {
    let mut inputs: JsonObject = BTreeMap::new();
    inputs.insert("bitmap".into(),   JsonValue::String(encode_u64_le(bitmap as u64)));
    inputs.insert("mask".into(),     JsonValue::String(encode_u64_le(mask as u64)));
    inputs.insert("expected".into(), JsonValue::String(encode_u64_le(expected as u64)));

    let mut output: JsonObject = BTreeMap::new();
    output.insert("result".into(), JsonValue::String(format!("0x{:02x}", if result { 1u8 } else { 0u8 })));

    VectorCase {
        id: format!("case_{:03}", index),
        description,
        inputs,
        expected_output: output,
    }
}

fn fail(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.into()) }
}

fn encode_u64_le(v: u64) -> String {
    let mut s = String::with_capacity(18);
    s.push_str("0x");
    for i in 0..8 { s.push_str(&format!("{:02x}", (v >> (i * 8)) & 0xFF)); }
    s
}

fn parse_u8(s: &str) -> Option<u8> {
    let stripped = s.strip_prefix("0x").unwrap_or(s);
    u8::from_str_radix(stripped, 16).ok()
}

fn parse_i64(s: &str) -> Option<i64> {
    parse_u64(s).map(|u| u as i64)
}

fn parse_u64(s: &str) -> Option<u64> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 { return None; }
    let mut v: u64 = 0;
    for i in 0..8 { v |= (bytes[i] as u64) << (i * 8); }
    Some(v)
}

fn iso_timestamp() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    format!("{}", secs)
}
