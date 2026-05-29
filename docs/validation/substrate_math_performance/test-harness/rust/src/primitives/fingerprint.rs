// src/primitives/fingerprint.rs
//
// Fingerprint256 wire roundtrip (cookbook § 3.1). Mirror of
// Swift's FingerprintPrimitive.swift.
//
// Input schema:
//   block0..block3 : u64 each
//
// Output schema:
//   wire_bytes : 32-byte hex string

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, encode_hex, u64_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::fingerprint256::Fingerprint256;

pub struct FingerprintPrimitive;

impl FingerprintPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "fingerprint",
            cookbook_section: "§3.1",
            reference_file: "glref-rust-fingerprint256.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let b0 = rng.next();
            let b1 = rng.next();
            let b2 = rng.next();
            let b3 = rng.next();
            let fp = Fingerprint256::new(b0, b1, b2, b3);

            let wire = fp.wire_bytes();
            let _roundtripped = Fingerprint256::from_wire_bytes(&wire).unwrap();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("block0".into(), JsonValue::String(u64_hex(b0)));
            inputs.insert("block1".into(), JsonValue::String(u64_hex(b1)));
            inputs.insert("block2".into(), JsonValue::String(u64_hex(b2)));
            inputs.insert("block3".into(), JsonValue::String(u64_hex(b3)));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("wire_bytes".into(), JsonValue::String(encode_hex(&wire)));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: "random Fingerprint256, roundtrip via wire_bytes".to_string(),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "fingerprint".to_string(),
            cookbook_section: "§3.1".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-fingerprint256.rs".to_string(),
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
    let b0 = match get_u64(&c.inputs, "block0") { Some(v) => v,
        None => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing or malformed block0".into()) }};
    let b1 = match get_u64(&c.inputs, "block1") { Some(v) => v,
        None => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing or malformed block1".into()) }};
    let b2 = match get_u64(&c.inputs, "block2") { Some(v) => v,
        None => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing or malformed block2".into()) }};
    let b3 = match get_u64(&c.inputs, "block3") { Some(v) => v,
        None => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing or malformed block3".into()) }};

    let fp = Fingerprint256::new(b0, b1, b2, b3);
    let actual_wire = fp.wire_bytes();
    let roundtripped = match Fingerprint256::from_wire_bytes(&actual_wire) {
        Ok(r) => r,
        Err(_) => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("wire_bytes roundtrip failed".into()) },
    };
    if roundtripped.block0 != fp.block0 || roundtripped.block1 != fp.block1
        || roundtripped.block2 != fp.block2 || roundtripped.block3 != fp.block3 {
        return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("roundtrip yielded different fingerprint".into()) };
    }

    let expected_wire = match c.expected_output.get("wire_bytes") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 32 => b,
            _ => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed expected wire_bytes".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected wire_bytes".into()) },
    };

    encoder.write_bytes(&actual_wire);

    if actual_wire == expected_wire.as_slice() {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "wire_bytes mismatch: expected {}, got {}",
                encode_hex(&expected_wire), encode_hex(&actual_wire))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let s = match output.get("wire_bytes") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing wire_bytes"),
    };
    let bytes = decode_hex(s).expect("malformed wire_bytes");
    assert_eq!(bytes.len(), 32);
    encoder.write_bytes(&bytes);
}

fn get_u64(obj: &JsonObject, key: &str) -> Option<u64> {
    let s = match obj.get(key) {
        Some(JsonValue::String(s)) => s,
        _ => return None,
    };
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 { return None; }
    let mut v: u64 = 0;
    for (i, b) in bytes.iter().enumerate() { v |= (*b as u64) << (i * 8); }
    Some(v)
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
