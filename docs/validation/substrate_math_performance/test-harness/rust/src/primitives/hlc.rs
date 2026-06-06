// src/primitives/hlc.rs
//
// Mirror of Swift HLCPrimitive.swift. Calls real reference at
// glref-rust-hlc.rs via the geniuslocus-reference crate.
//
// Input schema:
//   a : HLC wire bytes (32-char hex, 16 bytes LE: 8 phys + 4 log + 4 node)
//   b : HLC wire bytes
//
// Output schema:
//   ordering : i8 (-1, 0, +1)

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, encode_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_types::hlc::HLC;

pub struct HLCPrimitive;

impl HLCPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "hlc",
            cookbook_section: "§5.2",
            reference_file: "glref-rust-hlc.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let shape = i % 3;
            let a = random_hlc(&mut rng);
            let b = match shape {
                1 => a,
                2 => {
                    let new_node = if a.node_id == i32::MAX {
                        a.node_id - 1
                    } else {
                        a.node_id + 1
                    };
                    HLC::new(a.physical_time, a.logical_count, new_node)
                }
                _ => random_hlc(&mut rng),
            };

            let ordering: i8 = match a.cmp(&b) {
                std::cmp::Ordering::Less => -1,
                std::cmp::Ordering::Greater => 1,
                std::cmp::Ordering::Equal => 0,
            };

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("a".into(), JsonValue::String(encode_hex(&a.wire_bytes())));
            inputs.insert("b".into(), JsonValue::String(encode_hex(&b.wire_bytes())));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("ordering".into(), JsonValue::Integer(ordering as i64));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!("shape {}, ordering {}", shape, ordering),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "hlc".to_string(),
            cookbook_section: "§5.2".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-hlc.rs".to_string(),
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
    let a = match c.inputs.get("a") {
        Some(JsonValue::String(s)) => match parse_hlc(s) {
            Some(h) => h,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed a".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing a".into()) },
    };
    let b = match c.inputs.get("b") {
        Some(JsonValue::String(s)) => match parse_hlc(s) {
            Some(h) => h,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed b".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing b".into()) },
    };

    let actual: i8 = match a.cmp(&b) {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Greater => 1,
        std::cmp::Ordering::Equal => 0,
    };

    let expected = match c.expected_output.get("ordering") {
        Some(JsonValue::Integer(i)) => *i as i8,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected ordering".into()) },
    };

    encoder.write_i8(actual);

    if actual == expected {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "ordering mismatch: expected {}, got {}", expected, actual)),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let raw = match output.get("ordering") {
        Some(JsonValue::Integer(i)) => *i as i8,
        _ => panic!("expected_output missing ordering"),
    };
    encoder.write_i8(raw);
}

fn random_hlc(rng: &mut SplitMix64) -> HLC {
    let phys_raw = rng.next();
    let log_raw  = rng.next();
    let node_raw = rng.next();
    let physical_time = (phys_raw & 0x0000_FFFF_FFFF_FFFF) as i64;
    let logical_count = (log_raw  & 0x0000_FFFF) as i32;
    let node_id       = (node_raw & 0x0000_00FF) as i32;
    HLC::new(physical_time, logical_count, node_id)
}

fn parse_hlc(s: &str) -> Option<HLC> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 16 { return None; }
    HLC::from_wire_bytes(&bytes).ok()
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
