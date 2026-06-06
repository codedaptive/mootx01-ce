// src/primitives/nmf.rs
//
// Non-negative matrix factorization (cookbook § 6.9). Mirror of
// Swift's NMFPrimitive.swift.

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, f32_hex, u32_hex, u64_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_ml::nmf::NMFAlternatingLeastSquares;

pub struct NMFPrimitive;

impl NMFPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "nmf",
            cookbook_section: "§6.9",
            reference_file: "glref-rust-nmf.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        let shapes: [(usize, usize, usize); 4] = [
            (4, 3, 2), (5, 4, 2), (6, 5, 3), (8, 6, 3),
        ];

        for i in 0..case_count {
            let (m, n, rank) = shapes[i % shapes.len()];
            let max_iterations = 20 + (i % 4) * 5;
            let tolerance: f32 = 1e-4;
            let inner_seed = rng.next();

            let mut v: Vec<Vec<f32>> = Vec::with_capacity(m);
            for _ in 0..m {
                let mut row: Vec<f32> = Vec::with_capacity(n);
                for _ in 0..n {
                    let raw = rng.next();
                    let f = (raw >> 40) as f32 / (1u32 << 24) as f32;
                    row.push(f);
                }
                v.push(row);
            }

            let result = NMFAlternatingLeastSquares::factorize(
                &v, rank, max_iterations, tolerance, inner_seed);

            let v_arr: Vec<JsonValue> = v.iter().map(|row| {
                JsonValue::Array(row.iter().map(|f| JsonValue::String(f32_hex(*f))).collect())
            }).collect();
            let w_arr: Vec<JsonValue> = result.w.iter().map(|row| {
                JsonValue::Array(row.iter().map(|f| JsonValue::String(f32_hex(*f))).collect())
            }).collect();
            let h_arr: Vec<JsonValue> = result.h.iter().map(|row| {
                JsonValue::Array(row.iter().map(|f| JsonValue::String(f32_hex(*f))).collect())
            }).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("m".into(), JsonValue::String(u32_hex(m as u32)));
            inputs.insert("n".into(), JsonValue::String(u32_hex(n as u32)));
            inputs.insert("rank".into(), JsonValue::String(u32_hex(rank as u32)));
            inputs.insert("max_iterations".into(),
                          JsonValue::String(u32_hex(max_iterations as u32)));
            inputs.insert("tolerance".into(), JsonValue::String(f32_hex(tolerance)));
            inputs.insert("inner_seed".into(), JsonValue::String(u64_hex(inner_seed)));
            inputs.insert("v".into(), JsonValue::Array(v_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("iterations".into(),
                          JsonValue::String(u32_hex(result.iterations as u32)));
            output.insert("final_error".into(),
                          JsonValue::String(f32_hex(result.final_error)));
            output.insert("w".into(), JsonValue::Array(w_arr));
            output.insert("h".into(), JsonValue::Array(h_arr));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!("m={}, n={}, rank={}, maxIter={}",
                                     m, n, rank, max_iterations),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "nmf".to_string(),
            cookbook_section: "§6.9".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-nmf.rs".to_string(),
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
    let rank = match parse_u32(c.inputs.get("rank")) { Some(v) => v as usize,
        None => return fail_case(c, "missing rank") };
    let max_iterations = match parse_u32(c.inputs.get("max_iterations")) { Some(v) => v as usize,
        None => return fail_case(c, "missing max_iterations") };
    let tolerance = match parse_f32(c.inputs.get("tolerance")) { Some(f) => f,
        None => return fail_case(c, "missing tolerance") };
    let inner_seed = match parse_u64(c.inputs.get("inner_seed")) { Some(v) => v,
        None => return fail_case(c, "missing inner_seed") };

    let v_rows = match c.inputs.get("v") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing v"),
    };
    let mut v: Vec<Vec<f32>> = Vec::with_capacity(v_rows.len());
    for row in v_rows {
        match row {
            JsonValue::Array(cells) => {
                let mut r: Vec<f32> = Vec::with_capacity(cells.len());
                for cell in cells {
                    match cell {
                        JsonValue::String(s) => match parse_f32_hex(s) {
                            Some(f) => r.push(f),
                            None => return fail_case(c, "v cell malformed"),
                        },
                        _ => return fail_case(c, "v cell not string"),
                    }
                }
                v.push(r);
            }
            _ => return fail_case(c, "v row not array"),
        }
    }

    let result = NMFAlternatingLeastSquares::factorize(
        &v, rank, max_iterations, tolerance, inner_seed);

    let expected_iterations = match parse_u32(c.expected_output.get("iterations")) {
        Some(v) => v as usize, None => return fail_case(c, "missing expected iterations") };
    let expected_final_error = match parse_f32(c.expected_output.get("final_error")) {
        Some(f) => f, None => return fail_case(c, "missing expected final_error") };

    let exp_w_rows = match c.expected_output.get("w") {
        Some(JsonValue::Array(a)) => a, _ => return fail_case(c, "missing expected w") };
    let exp_h_rows = match c.expected_output.get("h") {
        Some(JsonValue::Array(a)) => a, _ => return fail_case(c, "missing expected h") };

    encoder.write_u32(result.iterations as u32);
    encoder.write_f32(result.final_error);
    for row in &result.w { for f in row { encoder.write_f32(*f); } }
    for row in &result.h { for f in row { encoder.write_f32(*f); } }

    if result.iterations != expected_iterations {
        return fail_case(c, &format!("iterations mismatch: expected {}, got {}",
                                      expected_iterations, result.iterations));
    }
    if result.final_error.to_bits() != expected_final_error.to_bits() {
        return fail_case(c, &format!("final_error mismatch: expected {}, got {}",
                                      f32_hex(expected_final_error), f32_hex(result.final_error)));
    }
    if let Some(err) = compare_matrix(&result.w, exp_w_rows, "W") {
        return fail_case(c, &err);
    }
    if let Some(err) = compare_matrix(&result.h, exp_h_rows, "H") {
        return fail_case(c, &err);
    }

    CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let iterations = parse_u32(output.get("iterations"))
        .expect("expected_output missing iterations");
    let final_error = parse_f32(output.get("final_error"))
        .expect("expected_output missing final_error");
    encoder.write_u32(iterations);
    encoder.write_f32(final_error);

    for key in ["w", "h"] {
        let rows = match output.get(key) {
            Some(JsonValue::Array(a)) => a,
            _ => panic!("expected_output missing {}", key),
        };
        for row in rows {
            if let JsonValue::Array(cells) = row {
                for cell in cells {
                    if let JsonValue::String(s) = cell {
                        let f = parse_f32_hex(s).expect("matrix cell malformed");
                        encoder.write_f32(f);
                    } else {
                        panic!("{} cell not string", key);
                    }
                }
            } else {
                panic!("{} row not array", key);
            }
        }
    }
}

fn compare_matrix(actual: &[Vec<f32>], exp_rows: &[JsonValue], name: &str) -> Option<String> {
    if actual.len() != exp_rows.len() {
        return Some(format!("{} row count mismatch: {} vs {}",
                             name, actual.len(), exp_rows.len()));
    }
    for i in 0..actual.len() {
        let cells = match &exp_rows[i] {
            JsonValue::Array(a) => a,
            _ => return Some(format!("{}[{}] not array", name, i)),
        };
        if actual[i].len() != cells.len() {
            return Some(format!("{}[{}] col count mismatch", name, i));
        }
        for j in 0..actual[i].len() {
            let s = match &cells[j] {
                JsonValue::String(s) => s,
                _ => return Some(format!("{}[{}][{}] not string", name, i, j)),
            };
            let f = match parse_f32_hex(s) {
                Some(f) => f,
                None => return Some(format!("{}[{}][{}] malformed", name, i, j)),
            };
            if actual[i][j].to_bits() != f.to_bits() {
                return Some(format!(
                    "{}[{}][{}] mismatch: expected {}, got {}",
                    name, i, j, f32_hex(f), f32_hex(actual[i][j])));
            }
        }
    }
    None
}

fn fail_case(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.into()) }
}

fn parse_u32(v: Option<&JsonValue>) -> Option<u32> {
    let s = match v? { JsonValue::String(s) => s, _ => return None };
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 4 { return None; }
    let mut x: u32 = 0;
    for (i, b) in bytes.iter().enumerate() { x |= (*b as u32) << (i * 8); }
    Some(x)
}

fn parse_u64(v: Option<&JsonValue>) -> Option<u64> {
    let s = match v? { JsonValue::String(s) => s, _ => return None };
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 { return None; }
    let mut x: u64 = 0;
    for (i, b) in bytes.iter().enumerate() { x |= (*b as u64) << (i * 8); }
    Some(x)
}

fn parse_f32(v: Option<&JsonValue>) -> Option<f32> {
    let s = match v? { JsonValue::String(s) => s, _ => return None };
    parse_f32_hex(s)
}

fn parse_f32_hex(s: &str) -> Option<f32> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 4 { return None; }
    let mut bits: u32 = 0;
    for (i, b) in bytes.iter().enumerate() { bits |= (*b as u32) << (i * 8); }
    Some(f32::from_bits(bits))
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
