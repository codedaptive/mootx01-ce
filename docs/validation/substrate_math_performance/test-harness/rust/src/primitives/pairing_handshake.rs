// src/primitives/pairing_handshake.rs
//
// Pairing nonce seed derivation (cookbook § 12.2). Mirror of
// Swift's PairingHandshakePrimitive.swift.
//
// Calls real reference at glref-rust-pairing.rs via the
// geniuslocus-reference crate.

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

use substrate_ml::pairing::PairingNonce;

pub struct PairingHandshakePrimitive;

impl PairingHandshakePrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "pairing_handshake",
            cookbook_section: "§12.2",
            reference_file: "glref-rust-pairing.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let mut nonce_bytes = [0u8; 32];
            for j in 0..4 {
                let w = rng.next();
                for k in 0..8 { nonce_bytes[j * 8 + k] = ((w >> (k * 8)) & 0xFF) as u8; }
            }

            let shape = i % 4;
            let (a_bytes, b_bytes): ([u8; 16], [u8; 16]) = match shape {
                1 => {
                    let mut first = random_id_bytes(&mut rng);
                    let mut second = random_id_bytes(&mut rng);
                    first[0] = 0x42;
                    second[0] = 0x42;
                    (first, second)
                }
                2 => {
                    let mut first = random_id_bytes(&mut rng);
                    let mut second = random_id_bytes(&mut rng);
                    first[0]  = 0x0F;
                    second[0] = 0x10;
                    (first, second)
                }
                3 => {
                    let mut first = random_id_bytes(&mut rng);
                    let mut second = random_id_bytes(&mut rng);
                    first[0]  = 0x20;
                    second[0] = 0x30;
                    (first, second)
                }
                _ => (random_id_bytes(&mut rng), random_id_bytes(&mut rng)),
            };

            let nonce = PairingNonce::new(nonce_bytes);
            let seed_val = nonce.seed_with(a_bytes, b_bytes);

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("nonce".into(), JsonValue::String(encode_hex(&nonce_bytes)));
            inputs.insert("estate_a".into(), JsonValue::String(encode_hex(&a_bytes)));
            inputs.insert("estate_b".into(), JsonValue::String(encode_hex(&b_bytes)));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("seed".into(), JsonValue::String(u64_hex(seed_val)));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!("shape {}, seed {}", shape, u64_hex(seed_val)),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "pairing_handshake".to_string(),
            cookbook_section: "§12.2".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-pairing.rs".to_string(),
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
    let nonce_vec = match c.inputs.get("nonce") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 32 => b,
            _ => return fail_case(c, "malformed nonce"),
        },
        _ => return fail_case(c, "missing nonce"),
    };
    let a_vec = match c.inputs.get("estate_a") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 16 => b,
            _ => return fail_case(c, "malformed estate_a"),
        },
        _ => return fail_case(c, "missing estate_a"),
    };
    let b_vec = match c.inputs.get("estate_b") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 16 => b,
            _ => return fail_case(c, "malformed estate_b"),
        },
        _ => return fail_case(c, "missing estate_b"),
    };

    let mut nonce_bytes = [0u8; 32];
    nonce_bytes.copy_from_slice(&nonce_vec);
    let mut a_bytes = [0u8; 16];
    a_bytes.copy_from_slice(&a_vec);
    let mut b_bytes = [0u8; 16];
    b_bytes.copy_from_slice(&b_vec);

    let nonce = PairingNonce::new(nonce_bytes);
    let actual = nonce.seed_with(a_bytes, b_bytes);

    let exp_vec = match c.expected_output.get("seed") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 8 => b,
            _ => return fail_case(c, "malformed expected seed"),
        },
        _ => return fail_case(c, "missing expected seed"),
    };
    let mut expected: u64 = 0;
    for j in 0..8 { expected |= (exp_vec[j] as u64) << (j * 8); }

    encoder.write_u64(actual);

    if actual == expected {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "seed mismatch: expected {}, got {}",
                u64_hex(expected), u64_hex(actual))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let s = match output.get("seed") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing seed"),
    };
    let bytes = decode_hex(s).expect("malformed seed hex");
    assert_eq!(bytes.len(), 8);
    let mut v: u64 = 0;
    for j in 0..8 { v |= (bytes[j] as u64) << (j * 8); }
    encoder.write_u64(v);
}

fn fail_case(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.into()) }
}

fn random_id_bytes(rng: &mut SplitMix64) -> [u8; 16] {
    let lo = rng.next();
    let hi = rng.next();
    let mut bytes = [0u8; 16];
    bytes[0..8].copy_from_slice(&lo.to_le_bytes());
    bytes[8..16].copy_from_slice(&hi.to_le_bytes());
    bytes
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
