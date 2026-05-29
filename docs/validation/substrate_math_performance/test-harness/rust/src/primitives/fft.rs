// src/primitives/fft.rs
//
// FFT magnitude spectrum (cookbook § 8.10). Mirror of Swift's
// FFTPrimitive.swift.

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

use substrate_kit::fft;

pub struct FFTPrimitive;

impl FFTPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "fft",
            cookbook_section: "§8.10",
            reference_file: "glref-rust-fft.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let n = 1usize << ((i % 4) + 2);
            let mut signal: Vec<f64> = Vec::with_capacity(n);
            for _ in 0..n {
                let raw = rng.next();
                let v = ((raw >> 11) as f64 / (1u64 << 53) as f64) * 2.0 - 1.0;
                signal.push(v);
            }

            let spectrum = fft::magnitude_spectrum(&signal);

            let signal_arr: Vec<JsonValue> = signal.iter()
                .map(|v| JsonValue::String(f64_hex(*v))).collect();
            let spectrum_arr: Vec<JsonValue> = spectrum.iter()
                .map(|v| JsonValue::String(f64_hex(*v))).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("signal".into(), JsonValue::Array(signal_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("spectrum".into(), JsonValue::Array(spectrum_arr));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!("n={}", n),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "fft".to_string(),
            cookbook_section: "§8.10".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-fft.rs".to_string(),
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
    let arr = match c.inputs.get("signal") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing signal"),
    };
    let mut signal: Vec<f64> = Vec::with_capacity(arr.len());
    for v in arr {
        match v {
            JsonValue::String(s) => match parse_f64_hex(s) {
                Some(f) => signal.push(f),
                None => return fail_case(c, "malformed signal element"),
            },
            _ => return fail_case(c, "non-string signal element"),
        }
    }

    let actual = fft::magnitude_spectrum(&signal);

    let exp_arr = match c.expected_output.get("spectrum") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing expected spectrum"),
    };
    let mut expected: Vec<f64> = Vec::with_capacity(exp_arr.len());
    for v in exp_arr {
        match v {
            JsonValue::String(s) => match parse_f64_hex(s) {
                Some(f) => expected.push(f),
                None => return fail_case(c, "malformed expected spectrum element"),
            },
            _ => return fail_case(c, "non-string expected spectrum element"),
        }
    }

    if actual.len() != expected.len() {
        return fail_case(c, &format!("spectrum length mismatch: {} vs {}",
                                      actual.len(), expected.len()));
    }

    for f in &actual { encoder.write_f64(*f); }

    for k in 0..actual.len() {
        if actual[k].to_bits() != expected[k].to_bits() {
            return CaseResult {
                id: c.id.clone(),
                passed: false,
                diagnostic: Some(format!(
                    "spectrum[{}] mismatch: expected {}, got {}",
                    k, f64_hex(expected[k]), f64_hex(actual[k]))),
            };
        }
    }

    CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let arr = match output.get("spectrum") {
        Some(JsonValue::Array(a)) => a,
        _ => panic!("expected_output missing spectrum"),
    };
    for v in arr {
        if let JsonValue::String(s) = v {
            let f = parse_f64_hex(s).expect("malformed spectrum hex");
            encoder.write_f64(f);
        } else {
            panic!("non-string spectrum element");
        }
    }
}

fn fail_case(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.into()) }
}

fn parse_f64_hex(s: &str) -> Option<f64> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 { return None; }
    let mut bits: u64 = 0;
    for (i, b) in bytes.iter().enumerate() { bits |= (*b as u64) << (i * 8); }
    Some(f64::from_bits(bits))
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
