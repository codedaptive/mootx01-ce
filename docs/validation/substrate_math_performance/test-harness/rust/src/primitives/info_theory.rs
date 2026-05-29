// src/primitives/info_theory.rs
//
// Information theory entropy (cookbook § 8.11). Mirror of
// Swift's InfoTheoryPrimitive.swift.
//
// Input schema:
//   probabilities : array of f32
//
// Output schema:
//   entropy : f32

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, f32_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::info_theory::InformationTheory;

pub struct InfoTheoryPrimitive;

impl InfoTheoryPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "info_theory",
            cookbook_section: "§8.11",
            reference_file: "glref-rust-info_theory.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let k = 1usize << ((i % 4) + 1);
            let probs = random_probability_distribution(&mut rng, k);
            let h = InformationTheory::entropy(&probs);

            let probs_arr: Vec<JsonValue> = probs.iter()
                .map(|p| JsonValue::String(f32_hex(*p))).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("probabilities".into(), JsonValue::Array(probs_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("entropy".into(), JsonValue::String(f32_hex(h)));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!("cardinality {}, entropy {}", k, h),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "info_theory".to_string(),
            cookbook_section: "§8.11".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-info_theory.rs".to_string(),
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
    let arr = match c.inputs.get("probabilities") {
        Some(JsonValue::Array(a)) => a,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing probabilities".into()) },
    };
    let mut probs: Vec<f32> = Vec::with_capacity(arr.len());
    for v in arr {
        match v {
            JsonValue::String(s) => match parse_f32_hex(s) {
                Some(p) => probs.push(p),
                None => return CaseResult { id: c.id.clone(), passed: false,
                    diagnostic: Some("malformed probability element".into()) },
            },
            _ => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("non-string probability element".into()) },
        }
    }

    let actual = InformationTheory::entropy(&probs);

    let expected = match c.expected_output.get("entropy") {
        Some(JsonValue::String(s)) => match parse_f32_hex(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed expected entropy".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected entropy".into()) },
    };

    encoder.write_f32(actual);

    if actual.to_bits() == expected.to_bits() {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "entropy mismatch: expected {}, got {}",
                f32_hex(expected), f32_hex(actual))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let s = match output.get("entropy") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing entropy"),
    };
    let f = parse_f32_hex(s).expect("malformed entropy hex");
    encoder.write_f32(f);
}

fn parse_f32_hex(s: &str) -> Option<f32> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 4 { return None; }
    let mut bits: u32 = 0;
    for (i, b) in bytes.iter().enumerate() { bits |= (*b as u32) << (i * 8); }
    Some(f32::from_bits(bits))
}

/// Build a probability distribution of length k that sums to 1.0
/// in f32. Same construction as Swift's
/// randomProbabilityDistribution.
fn random_probability_distribution(rng: &mut SplitMix64, k: usize) -> Vec<f32> {
    let mut weights: Vec<f32> = Vec::with_capacity(k);
    let mut total: f32 = 0.0;
    for _ in 0..k {
        let raw = rng.next();
        let w = (raw >> 40) as f32 / (1u32 << 24) as f32;
        let nudged = w + 0.001_f32;
        weights.push(nudged);
        total += nudged;
    }
    for i in 0..k {
        weights[i] /= total;
    }
    weights
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
