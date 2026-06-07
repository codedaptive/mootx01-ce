// src/primitives/matrix_decay.rs
//
// Exponential matrix decay (cookbook §6.8 / §8.13) — promotes the
// `matrix_decay` reference into the conformance harness per the
// "Pending future work" entry in primitive-catalog.md.
//
// Mirror of Swift's MatrixDecayPrimitive.swift. Calls the real
// reference at glref-rust-decay.rs via the substrate-kit crate.
//
// Input schema:
//   rows                      : u32  (decimal integer)
//   cols                      : u32  (decimal integer)
//   half_life_seconds         : f64  (16-hex IEEE-754 bit pattern, LE)
//   last_decay_time_seconds   : i64  (decimal integer)
//   now_seconds               : i64  (decimal integer)
//   initial_values            : array of f64 (each 16-hex IEEE-754 LE)
//
// Output schema:
//   final_last_decay_time_seconds : i64
//   final_values                  : array of f64
//
// Binary canonical encoding (alphabetical key order per spec):
//   final_last_decay_time_seconds  (8 bytes i64 LE)
//   final_values                   (u32 LE length + N × 8 bytes f64 LE)
//
// Cross-language bit-identity assumption: on Apple Silicon, Swift's
// Foundation `exp()` and Rust's `f64::exp()` resolve to the same
// libm (Darwin's libsystem_m), so transcendental results agree
// bit-for-bit. Most cases use dt = k × half_life so the decay
// factor is a power of 1/2 (bit-exact). Cases 24..27 are edge
// cases; the remaining cases use arbitrary dt and surface any
// cross-libm divergence as a CRC mismatch.

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

use substrate_ml::decay::{self, DecayingMatrix};

pub struct MatrixDecayPrimitive;

impl MatrixDecayPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "matrix_decay",
            cookbook_section: "§6.8",
            reference_file: "glref-rust-decay.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let (rows, cols) = matrix_shape(i);
            let half_life = half_life_seconds(&mut rng);
            let last_decay_time = last_decay_seconds(&mut rng);
            let now_seconds = now_seconds_for_case(
                i, last_decay_time, half_life, &mut rng);

            let n = rows * cols;
            let mut initial_values: Vec<f64> = Vec::with_capacity(n);
            for _ in 0..n {
                initial_values.push(f64_from_u64_signed(rng.next(), 100.0));
            }

            let mut matrix = DecayingMatrix::new(
                rows, cols, half_life, last_decay_time);
            for r in 0..rows {
                for c in 0..cols {
                    matrix.set(r, c, initial_values[r * cols + c]);
                }
            }

            // estate="" + ts=0.0: telemetry off — harness must not emit VizGraph signals.
            decay::apply(&mut matrix, now_seconds, "", 0.0);

            let initial_arr: Vec<JsonValue> = initial_values.iter()
                .map(|v| JsonValue::String(f64_hex(*v))).collect();
            let final_arr: Vec<JsonValue> = matrix.values.iter()
                .map(|v| JsonValue::String(f64_hex(*v))).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("rows".into(),                    JsonValue::Integer(rows as i64));
            inputs.insert("cols".into(),                    JsonValue::Integer(cols as i64));
            inputs.insert("half_life_seconds".into(),       JsonValue::String(f64_hex(half_life)));
            inputs.insert("last_decay_time_seconds".into(), JsonValue::Integer(last_decay_time));
            inputs.insert("now_seconds".into(),             JsonValue::Integer(now_seconds));
            inputs.insert("initial_values".into(),          JsonValue::Array(initial_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("final_last_decay_time_seconds".into(),
                          JsonValue::Integer(matrix.last_decay_time_seconds));
            output.insert("final_values".into(), JsonValue::Array(final_arr));

            let dt = (now_seconds - last_decay_time) as f64;
            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: case_description(i, rows, cols, half_life, dt),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "matrix_decay".to_string(),
            cookbook_section: "§6.8".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-decay.rs".to_string(),
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
    let rows = match c.inputs.get("rows") {
        Some(JsonValue::Integer(n)) if *n > 0 => *n as usize,
        _ => return fail(c, "missing or invalid rows"),
    };
    let cols = match c.inputs.get("cols") {
        Some(JsonValue::Integer(n)) if *n > 0 => *n as usize,
        _ => return fail(c, "missing or invalid cols"),
    };
    let half_life = match c.inputs.get("half_life_seconds") {
        Some(JsonValue::String(s)) => match parse_f64_hex(s) {
            Some(f) => f,
            None => return fail(c, "malformed half_life_seconds"),
        },
        _ => return fail(c, "missing half_life_seconds"),
    };
    let last_decay_time = match c.inputs.get("last_decay_time_seconds") {
        Some(JsonValue::Integer(n)) => *n,
        _ => return fail(c, "missing last_decay_time_seconds"),
    };
    let now_seconds = match c.inputs.get("now_seconds") {
        Some(JsonValue::Integer(n)) => *n,
        _ => return fail(c, "missing now_seconds"),
    };
    let init_arr = match c.inputs.get("initial_values") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail(c, "missing initial_values"),
    };
    if init_arr.len() != rows * cols {
        return fail(c, "initial_values count mismatch");
    }
    let mut initial_values: Vec<f64> = Vec::with_capacity(rows * cols);
    for v in init_arr {
        match v {
            JsonValue::String(s) => match parse_f64_hex(s) {
                Some(f) => initial_values.push(f),
                None => return fail(c, "malformed initial_values element"),
            },
            _ => return fail(c, "non-string initial_values element"),
        }
    }

    let mut matrix = DecayingMatrix::new(rows, cols, half_life, last_decay_time);
    for r in 0..rows {
        for col in 0..cols {
            matrix.set(r, col, initial_values[r * cols + col]);
        }
    }
    // estate="" + ts=0.0: telemetry off — harness must not emit VizGraph signals.
    decay::apply(&mut matrix, now_seconds, "", 0.0);

    let expected_last_decay = match c.expected_output.get("final_last_decay_time_seconds") {
        Some(JsonValue::Integer(n)) => *n,
        _ => return fail(c, "missing expected final_last_decay_time_seconds"),
    };
    let final_arr = match c.expected_output.get("final_values") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail(c, "missing expected final_values"),
    };
    if final_arr.len() != rows * cols {
        return fail(c, "expected final_values count mismatch");
    }
    let mut expected_final: Vec<f64> = Vec::with_capacity(rows * cols);
    for v in final_arr {
        match v {
            JsonValue::String(s) => match parse_f64_hex(s) {
                Some(f) => expected_final.push(f),
                None => return fail(c, "malformed expected final_values element"),
            },
            _ => return fail(c, "non-string expected final_values element"),
        }
    }

    encoder.write_i64(matrix.last_decay_time_seconds);
    encoder.write_u32(matrix.values.len() as u32);
    for v in &matrix.values { encoder.write_f64(*v); }

    if matrix.last_decay_time_seconds != expected_last_decay {
        return CaseResult {
            id: c.id.clone(), passed: false,
            diagnostic: Some(format!(
                "final_last_decay_time_seconds mismatch: expected {}, got {}",
                expected_last_decay, matrix.last_decay_time_seconds)),
        };
    }
    for (idx, (actual, expected)) in matrix.values.iter().zip(expected_final.iter()).enumerate() {
        if actual.to_bits() != expected.to_bits() {
            return CaseResult {
                id: c.id.clone(), passed: false,
                diagnostic: Some(format!(
                    "final_values[{}] mismatch: expected {}, got {}",
                    idx, f64_hex(*expected), f64_hex(*actual))),
            };
        }
    }
    CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let last_decay = match output.get("final_last_decay_time_seconds") {
        Some(JsonValue::Integer(n)) => *n,
        _ => panic!("expected_output missing final_last_decay_time_seconds"),
    };
    let arr = match output.get("final_values") {
        Some(JsonValue::Array(a)) => a,
        _ => panic!("expected_output missing final_values"),
    };
    encoder.write_i64(last_decay);
    encoder.write_u32(arr.len() as u32);
    for v in arr {
        let s = match v {
            JsonValue::String(s) => s,
            _ => panic!("non-string final_values element"),
        };
        let f = parse_f64_hex(s).expect("malformed final_values hex");
        encoder.write_f64(f);
    }
}

fn fail(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult {
        id: c.id.clone(), passed: false,
        diagnostic: Some(msg.to_string()),
    }
}

fn parse_f64_hex(s: &str) -> Option<f64> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 { return None; }
    let mut bits: u64 = 0;
    for (i, b) in bytes.iter().enumerate() { bits |= (*b as u64) << (i * 8); }
    Some(f64::from_bits(bits))
}

fn f64_from_u64_signed(raw: u64, scale: f64) -> f64 {
    let normalized = ((raw >> 11) as f64 / (1u64 << 53) as f64) * 2.0 - 1.0;
    normalized * scale
}

fn matrix_shape(i: usize) -> (usize, usize) {
    const SHAPES: [(usize, usize); 32] = [
        (1, 1), (1, 1), (1, 1), (1, 1),
        (2, 3), (3, 2), (2, 3), (3, 2),
        (4, 4), (4, 4), (4, 4), (4, 4),
        (1, 8), (8, 1), (5, 5), (3, 4),
        (1, 1), (2, 2), (3, 3), (4, 4),
        (2, 3), (3, 2), (4, 4), (5, 5),
        (1, 1), (1, 1), (1, 1), (1, 1),
        (3, 3), (4, 4), (2, 5), (5, 2),
    ];
    SHAPES[i]
}

fn half_life_seconds(rng: &mut SplitMix64) -> f64 {
    let r = rng.next();
    let normalized = (r >> 11) as f64 / (1u64 << 53) as f64;
    let min_sec = 60.0 * 86400.0;
    let max_sec = 730.0 * 86400.0;
    min_sec + normalized * (max_sec - min_sec)
}

fn last_decay_seconds(rng: &mut SplitMix64) -> i64 {
    let r = rng.next();
    (r % (10 * 365 * 86400)) as i64
}

fn now_seconds_for_case(
    i: usize, last_decay_time: i64,
    half_life: f64, rng: &mut SplitMix64,
) -> i64 {
    match i {
        24 => last_decay_time,
        25 => last_decay_time - 1000,
        26 => last_decay_time + (half_life as i64),
        27 => last_decay_time + (half_life * 2.0) as i64,
        _ => {
            let r = rng.next();
            let normalized = (r >> 11) as f64 / (1u64 << 53) as f64;
            let dt = 1.0 + normalized * 3.0 * half_life;
            last_decay_time + dt as i64
        }
    }
}

fn case_description(i: usize, rows: usize, cols: usize,
                    half_life: f64, dt: f64) -> String {
    let half_life_days = half_life / 86400.0;
    let half_lives_elapsed = dt / half_life;
    format!("case {}: {}x{}, half_life {:.2} days, {:.4} half-lives elapsed",
            i, rows, cols, half_life_days, half_lives_elapsed)
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
