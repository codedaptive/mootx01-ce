// src/primitives/lattice.rs
//
// UDC tree distance (cookbook § 8.3). Mirror of
// Swift's LatticePrimitive.swift.
//
// Input schema:
//   a : UDC string
//   b : UDC string
//
// Output schema:
//   distance : f64

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, f64_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::lattice_distance::UDCTreeDistance;

pub struct LatticePrimitive;

impl LatticePrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "lattice",
            cookbook_section: "§8.3",
            reference_file: "glref-rust-lattice_distance.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let shape = i % 4;
            let (a, b) = synth_udc_pair(&mut rng, shape);
            let dist = UDCTreeDistance::distance(&a, &b);

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("a".into(), JsonValue::String(a.clone()));
            inputs.insert("b".into(), JsonValue::String(b.clone()));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("distance".into(), JsonValue::String(f64_hex(dist)));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!(
                    "shape {}, a=\"{}\", b=\"{}\", d={}", shape, a, b, dist),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "lattice".to_string(),
            cookbook_section: "§8.3".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-lattice_distance.rs".to_string(),
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
        Some(JsonValue::String(s)) => s.clone(),
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing a".into()) },
    };
    let b = match c.inputs.get("b") {
        Some(JsonValue::String(s)) => s.clone(),
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing b".into()) },
    };

    let actual = UDCTreeDistance::distance(&a, &b);

    let expected = match c.expected_output.get("distance") {
        Some(JsonValue::String(s)) => match parse_f64_hex(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed expected distance".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected distance".into()) },
    };

    encoder.write_f64(actual);

    if actual.to_bits() == expected.to_bits() {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "distance mismatch: expected {}, got {}",
                f64_hex(expected), f64_hex(actual))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let s = match output.get("distance") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing distance"),
    };
    let f = parse_f64_hex(s).expect("malformed distance hex");
    encoder.write_f64(f);
}

fn parse_f64_hex(s: &str) -> Option<f64> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 { return None; }
    let mut bits: u64 = 0;
    for (i, b) in bytes.iter().enumerate() { bits |= (*b as u64) << (i * 8); }
    Some(f64::from_bits(bits))
}

/// Generate a deterministic UDC string pair. Must match Swift's
/// synthUDCPair byte-for-byte from the same RNG state.
fn synth_udc_pair(rng: &mut SplitMix64, shape: usize) -> (String, String) {
    let a_len = 2 + (rng.next() % 4) as usize;
    let mut a_components: Vec<String> = Vec::with_capacity(a_len);
    for _ in 0..a_len {
        a_components.push((1 + (rng.next() % 9)).to_string());
    }
    let a = a_components.join(".");

    let b = match shape {
        0 => a.clone(),
        1 => {
            let mut bc = a_components.clone();
            bc[a_len - 1] = (1 + (rng.next() % 9)).to_string();
            bc.join(".")
        }
        2 => {
            let trim_to = std::cmp::max(1, a_len - 1 - (rng.next() % 2) as usize);
            a_components[..trim_to].join(".")
        }
        _ => {
            let b_len = 2 + (rng.next() % 4) as usize;
            let mut bc: Vec<String> = Vec::with_capacity(b_len);
            for _ in 0..b_len {
                bc.push((1 + (rng.next() % 9)).to_string());
            }
            bc[0] = (1 + ((rng.next().wrapping_add(5)) % 9)).to_string();
            bc.join(".")
        }
    };
    (a, b)
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
