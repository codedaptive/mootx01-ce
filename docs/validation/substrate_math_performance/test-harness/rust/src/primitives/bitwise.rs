// src/primitives/bitwise.rs
//
// Mirror of Swift's BitwisePrimitive. Calls real reference at
// glref-rust-bitwise.rs via the geniuslocus-reference crate.
//
// Input schema:
//   op : u8 (0 = intersect, 1 = difference)
//   a  : Fingerprint256
//   b  : Fingerprint256
//
// Output schema:
//   result : Fingerprint256

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, u8_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::fingerprint256::Fingerprint256 as RealFingerprint256;
use substrate_kit::bitwise as real_bitwise;

pub struct BitwisePrimitive;

impl BitwisePrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "bitwise",
            cookbook_section: "§8.6",
            reference_file: "glref-rust-bitwise.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let mut cases = Vec::with_capacity(32);
        let case_count = 32usize;

        for i in 0..case_count {
            let a = RealFingerprint256 {
                block0: rng.next(), block1: rng.next(),
                block2: rng.next(), block3: rng.next(),
            };
            let b = RealFingerprint256 {
                block0: rng.next(), block1: rng.next(),
                block2: rng.next(), block3: rng.next(),
            };
            let op: u8 = (i % 2) as u8;

            let result = if op == 0 {
                real_bitwise::intersect(&a, &b)
            } else {
                real_bitwise::difference(&a, &b)
            };

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("a".into(), JsonValue::String(encode_fingerprint(&a)));
            inputs.insert("b".into(), JsonValue::String(encode_fingerprint(&b)));
            inputs.insert("op".into(), JsonValue::String(u8_hex(op)));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("result".into(), JsonValue::String(encode_fingerprint(&result)));

            let op_name = if op == 0 { "intersect" } else { "difference" };
            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!("op {}", op_name),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "bitwise".to_string(),
            cookbook_section: "§8.6".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-bitwise.rs".to_string(),
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
        for c in &file.cases {
            case_results.push(validate_case(c, &mut encoder));
        }
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
    let a = match c.inputs.get("a") {
        Some(JsonValue::String(s)) => match parse_fingerprint(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed a".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing a".into()) },
    };
    let b = match c.inputs.get("b") {
        Some(JsonValue::String(s)) => match parse_fingerprint(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed b".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing b".into()) },
    };
    let op = match c.inputs.get("op") {
        Some(JsonValue::String(s)) => {
            let bytes = match decode_hex(s) { Ok(b) => b, Err(_) =>
                return CaseResult { id: c.id.clone(), passed: false,
                    diagnostic: Some("malformed op".into()) } };
            if bytes.len() != 1 {
                return CaseResult { id: c.id.clone(), passed: false,
                    diagnostic: Some("malformed op length".into()) };
            }
            bytes[0]
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing op".into()) },
    };

    let actual = if op == 0 {
        real_bitwise::intersect(&a, &b)
    } else {
        real_bitwise::difference(&a, &b)
    };

    let expected = match c.expected_output.get("result") {
        Some(JsonValue::String(s)) => match parse_fingerprint(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed expected result".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected result".into()) },
    };

    write_fingerprint(&actual, encoder);

    if fp_eq(&actual, &expected) {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "result mismatch: expected {}, got {}",
                encode_fingerprint(&expected), encode_fingerprint(&actual))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let s = match output.get("result") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing result"),
    };
    let fp = parse_fingerprint(s).expect("malformed result hex");
    write_fingerprint(&fp, encoder);
}

fn write_fingerprint(fp: &RealFingerprint256, encoder: &mut CanonicalBinaryEncoder) {
    encoder.write_u64(fp.block0);
    encoder.write_u64(fp.block1);
    encoder.write_u64(fp.block2);
    encoder.write_u64(fp.block3);
}

fn encode_fingerprint(fp: &RealFingerprint256) -> String {
    let mut bytes = [0u8; 32];
    let blocks = [fp.block0, fp.block1, fp.block2, fp.block3];
    for (i, w) in blocks.iter().enumerate() {
        for j in 0..8 { bytes[i * 8 + j] = ((w >> (j * 8)) & 0xFF) as u8; }
    }
    let mut out = String::with_capacity(2 + 64);
    out.push_str("0x");
    for b in bytes.iter() { out.push_str(&format!("{:02x}", b)); }
    out
}

fn parse_fingerprint(s: &str) -> Option<RealFingerprint256> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 32 { return None; }
    let mut blocks = [0u64; 4];
    for i in 0..4 {
        let mut w: u64 = 0;
        for j in 0..8 { w |= (bytes[i * 8 + j] as u64) << (j * 8); }
        blocks[i] = w;
    }
    Some(RealFingerprint256 {
        block0: blocks[0], block1: blocks[1],
        block2: blocks[2], block3: blocks[3],
    })
}

fn fp_eq(a: &RealFingerprint256, b: &RealFingerprint256) -> bool {
    a.block0 == b.block0 && a.block1 == b.block1
        && a.block2 == b.block2 && a.block3 == b.block3
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
