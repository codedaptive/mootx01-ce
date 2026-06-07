// src/primitives/anomaly.rs
//
// Anomaly detection (cookbook § 8.13) — rolling z-score. Mirror
// of Swift's AnomalyPrimitive.swift. Calls the real reference at
// glref-rust-anomaly.rs via the geniuslocus-reference crate.
//
// Vector regeneration note: the Path 1 stub was f64-based and
// computed the rolling z-score formula inline; the real reference
// is f32. Documented in test-vector-format.md.
//
// Input schema:
//   current : f32
//   window  : array of f32
//
// Output schema:
//   z_score : f32

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

use substrate_ml::anomaly::AnomalyDetection;

pub struct AnomalyPrimitive;

impl AnomalyPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "anomaly",
            cookbook_section: "§8.13",
            reference_file: "glref-rust-anomaly.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let window_size = 1usize << ((i % 4) + 2);
            let mut window: Vec<f32> = Vec::with_capacity(window_size);
            for _ in 0..window_size {
                window.push(f32_from_u64_signed(rng.next(), 100.0));
            }
            let current = f32_from_u64_signed(rng.next(), 100.0);

            // estate="" + ts=0.0: telemetry off — harness is a conformance
            // oracle and must not emit VizGraph signals, only compute and compare.
            let z = AnomalyDetection::rolling_z_score(&window, current, "", 0.0);

            let window_arr: Vec<JsonValue> = window.iter()
                .map(|v| JsonValue::String(f32_hex(*v))).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("current".into(), JsonValue::String(f32_hex(current)));
            inputs.insert("window".into(), JsonValue::Array(window_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("z_score".into(), JsonValue::String(f32_hex(z)));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!(
                    "window size {}, current {:.4}", window_size, current),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "anomaly".to_string(),
            cookbook_section: "§8.13".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-anomaly.rs".to_string(),
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
    let w_arr = match c.inputs.get("window") {
        Some(JsonValue::Array(a)) => a,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing window".into()) },
    };
    let mut window: Vec<f32> = Vec::with_capacity(w_arr.len());
    for v in w_arr {
        match v {
            JsonValue::String(s) => match parse_f32_hex(s) {
                Some(f) => window.push(f),
                None => return CaseResult { id: c.id.clone(), passed: false,
                    diagnostic: Some("malformed window element".into()) },
            },
            _ => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("non-string window element".into()) },
        }
    }
    let current = match c.inputs.get("current") {
        Some(JsonValue::String(s)) => match parse_f32_hex(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed current".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing current".into()) },
    };

    // estate="" + ts=0.0: telemetry off — harness must not emit signals.
    let actual = AnomalyDetection::rolling_z_score(&window, current, "", 0.0);

    let expected = match c.expected_output.get("z_score") {
        Some(JsonValue::String(s)) => match parse_f32_hex(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed expected z_score".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected z_score".into()) },
    };

    encoder.write_f32(actual);

    if actual.to_bits() == expected.to_bits() {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "z_score mismatch: expected {}, got {}",
                f32_hex(expected), f32_hex(actual))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let s = match output.get("z_score") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing z_score"),
    };
    let f = parse_f32_hex(s).expect("malformed z_score hex");
    encoder.write_f32(f);
}

fn parse_f32_hex(s: &str) -> Option<f32> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 4 { return None; }
    let mut bits: u32 = 0;
    for (i, b) in bytes.iter().enumerate() { bits |= (*b as u32) << (i * 8); }
    Some(f32::from_bits(bits))
}

/// Map a u64 to a signed f32 in [-scale, +scale]. Matches Swift's
/// f32FromUInt64Signed so the same RNG seed produces the same
/// f32 values in both languages.
fn f32_from_u64_signed(raw: u64, scale: f32) -> f32 {
    let normalized = ((raw >> 40) as f32 / (1u32 << 24) as f32) * 2.0 - 1.0;
    normalized * scale
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
