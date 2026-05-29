// src/primitives/bradley_terry.rs
//
// Mirror of Swift's BradleyTerryPrimitive. Calls real reference
// at glref-rust-bradley_terry.rs via the geniuslocus-reference
// crate.
//
// Row IDs are 16-byte synthetic identifiers. Rust uses u128
// (little-endian) to key the estimator's HashMap; the same bytes
// produced by the SplitMix RNG appear as u128 here and as UUID in
// Swift, yielding identical map keys (byte-for-byte) once both
// are serialized back to 16-byte hex.
//
// Input schema:
//   learning_rate : f64
//   l2            : f64
//   pre_theta     : array of {id: 16-byte hex, theta: f64-hex}
//   winner_id     : 16-byte hex
//   losers        : array of 16-byte hex
//   weight        : f64
//
// Output schema:
//   post_theta : array of {id: 16-byte hex, theta: f64-hex} sorted by id

use std::collections::{BTreeMap, HashMap};

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, encode_hex, f64_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::bradley_terry::{
    BradleyTerryEstimator, PreferenceObservation, RowId,
};

pub struct BradleyTerryPrimitive;

impl BradleyTerryPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "bradley_terry",
            cookbook_section: "§8.12",
            reference_file: "glref-rust-bradley_terry.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let population_size = 4usize;
            let mut row_bytes: Vec<[u8; 16]> = Vec::with_capacity(population_size);
            for _ in 0..population_size {
                row_bytes.push(random_id_bytes(&mut rng));
            }

            // pre_theta: small random values keyed by row index.
            let mut pre_theta: Vec<([u8; 16], f64)> = Vec::with_capacity(population_size);
            for k in 0..population_size {
                let raw = rng.next();
                let theta = ((raw >> 40) as f64 / (1u32 << 24) as f64) * 2.0 - 1.0;
                pre_theta.push((row_bytes[k], theta));
            }

            let winner_idx = (rng.next() % population_size as u64) as usize;
            let winner_bytes = row_bytes[winner_idx];
            let mut loser_bytes: Vec<[u8; 16]> = Vec::new();
            for k in 0..population_size {
                if k != winner_idx { loser_bytes.push(row_bytes[k]); }
            }
            let weight: f64 = 1.0;

            let learning_rate: f64 = [0.05, 0.1, 0.025, 0.5][i % 4];
            let l2: f64 = [0.001, 0.01, 0.0, 0.05][i % 4];

            // Build estimator.
            let mut theta_init: HashMap<RowId, f64> = HashMap::new();
            for (bytes, t) in &pre_theta {
                theta_init.insert(bytes_to_rowid(bytes), *t);
            }
            let mut est = BradleyTerryEstimator {
                learning_rate, l2, theta: theta_init,
            };

            let winner_id = bytes_to_rowid(&winner_bytes);
            let losers: Vec<RowId> = loser_bytes.iter()
                .map(|b| bytes_to_rowid(b)).collect();
            let obs = PreferenceObservation::with_weight(
                winner_id, losers, weight);
            est.observe(&obs);

            // Build post-state sorted by id bytes.
            let mut post_sorted: Vec<([u8; 16], f64)> = pre_theta.iter()
                .map(|(bytes, _)| {
                    let id = bytes_to_rowid(bytes);
                    (*bytes, est.theta.get(&id).copied().unwrap_or(0.0))
                })
                .collect();
            post_sorted.sort_by(|a, b| a.0.cmp(&b.0));

            let mut pre_sorted = pre_theta.clone();
            pre_sorted.sort_by(|a, b| a.0.cmp(&b.0));

            let pre_arr: Vec<JsonValue> = pre_sorted.iter().map(|(bytes, t)| {
                let mut o: JsonObject = BTreeMap::new();
                o.insert("id".into(), JsonValue::String(encode_hex(bytes)));
                o.insert("theta".into(), JsonValue::String(f64_hex(*t)));
                JsonValue::Object(o)
            }).collect();
            let post_arr: Vec<JsonValue> = post_sorted.iter().map(|(bytes, t)| {
                let mut o: JsonObject = BTreeMap::new();
                o.insert("id".into(), JsonValue::String(encode_hex(bytes)));
                o.insert("theta".into(), JsonValue::String(f64_hex(*t)));
                JsonValue::Object(o)
            }).collect();
            let losers_arr: Vec<JsonValue> = loser_bytes.iter()
                .map(|b| JsonValue::String(encode_hex(b))).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("learning_rate".into(), JsonValue::String(f64_hex(learning_rate)));
            inputs.insert("l2".into(), JsonValue::String(f64_hex(l2)));
            inputs.insert("pre_theta".into(), JsonValue::Array(pre_arr));
            inputs.insert("winner_id".into(), JsonValue::String(encode_hex(&winner_bytes)));
            inputs.insert("losers".into(), JsonValue::Array(losers_arr));
            inputs.insert("weight".into(), JsonValue::String(f64_hex(weight)));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("post_theta".into(), JsonValue::Array(post_arr));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!("lr={}, l2={}, |losers|={}",
                                     learning_rate, l2, loser_bytes.len()),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "bradley_terry".to_string(),
            cookbook_section: "§8.12".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-bradley_terry.rs".to_string(),
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
    let lr = match get_f64(&c.inputs, "learning_rate") { Some(v) => v,
        None => return fail_case(c, "missing learning_rate") };
    let l2 = match get_f64(&c.inputs, "l2") { Some(v) => v,
        None => return fail_case(c, "missing l2") };
    let weight = match get_f64(&c.inputs, "weight") { Some(v) => v,
        None => return fail_case(c, "missing weight") };

    let pre_arr = match c.inputs.get("pre_theta") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing pre_theta"),
    };
    let winner_bytes = match c.inputs.get("winner_id") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 16 => b,
            _ => return fail_case(c, "malformed winner_id"),
        },
        _ => return fail_case(c, "missing winner_id"),
    };
    let losers_arr = match c.inputs.get("losers") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing losers"),
    };

    let mut theta_init: HashMap<RowId, f64> = HashMap::new();
    let mut id_bytes_all: Vec<[u8; 16]> = Vec::with_capacity(pre_arr.len());
    for v in pre_arr {
        match v {
            JsonValue::Object(o) => {
                let id_bytes = match o.get("id") {
                    Some(JsonValue::String(s)) => match decode_hex(s) {
                        Ok(b) if b.len() == 16 => b,
                        _ => return fail_case(c, "malformed pre_theta id"),
                    },
                    _ => return fail_case(c, "missing pre_theta id"),
                };
                let t = match o.get("theta") {
                    Some(JsonValue::String(s)) => match parse_f64_hex(s) {
                        Some(v) => v,
                        None => return fail_case(c, "malformed pre_theta theta"),
                    },
                    _ => return fail_case(c, "missing pre_theta theta"),
                };
                let mut arr = [0u8; 16];
                arr.copy_from_slice(&id_bytes);
                theta_init.insert(bytes_to_rowid(&arr), t);
                id_bytes_all.push(arr);
            }
            _ => return fail_case(c, "pre_theta element not object"),
        }
    }

    let mut losers: Vec<RowId> = Vec::new();
    for v in losers_arr {
        match v {
            JsonValue::String(s) => match decode_hex(s) {
                Ok(b) if b.len() == 16 => {
                    let mut arr = [0u8; 16];
                    arr.copy_from_slice(&b);
                    losers.push(bytes_to_rowid(&arr));
                }
                _ => return fail_case(c, "malformed loser id"),
            },
            _ => return fail_case(c, "loser element not string"),
        }
    }
    let mut winner_arr = [0u8; 16];
    winner_arr.copy_from_slice(&winner_bytes);
    let winner = bytes_to_rowid(&winner_arr);

    let mut est = BradleyTerryEstimator { learning_rate: lr, l2: l2, theta: theta_init };
    let obs = PreferenceObservation::with_weight(winner, losers, weight);
    est.observe(&obs);

    // Build actual post-state sorted by id.
    let mut actual_post: Vec<([u8; 16], f64)> = id_bytes_all.iter()
        .map(|bytes| {
            let id = bytes_to_rowid(bytes);
            (*bytes, est.theta.get(&id).copied().unwrap_or(0.0))
        })
        .collect();
    actual_post.sort_by(|a, b| a.0.cmp(&b.0));

    let post_arr = match c.expected_output.get("post_theta") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing expected post_theta"),
    };
    if post_arr.len() != actual_post.len() {
        return fail_case(c, "post_theta length mismatch");
    }
    let mut expected_post: Vec<([u8; 16], f64)> = Vec::with_capacity(post_arr.len());
    for v in post_arr {
        match v {
            JsonValue::Object(o) => {
                let id_bytes = match o.get("id") {
                    Some(JsonValue::String(s)) => match decode_hex(s) {
                        Ok(b) if b.len() == 16 => b,
                        _ => return fail_case(c, "malformed post_theta id"),
                    },
                    _ => return fail_case(c, "missing post_theta id"),
                };
                let t = match o.get("theta") {
                    Some(JsonValue::String(s)) => match parse_f64_hex(s) {
                        Some(v) => v,
                        None => return fail_case(c, "malformed post_theta theta"),
                    },
                    _ => return fail_case(c, "missing post_theta theta"),
                };
                let mut arr = [0u8; 16];
                arr.copy_from_slice(&id_bytes);
                expected_post.push((arr, t));
            }
            _ => return fail_case(c, "post_theta element not object"),
        }
    }

    // Encode actual to canonical AND compare element-by-element.
    for (bytes, t) in &actual_post {
        encoder.write_bytes(bytes);
        encoder.write_f64(*t);
    }
    for k in 0..actual_post.len() {
        if actual_post[k].0 != expected_post[k].0 {
            return fail_case(c, &format!("post_theta id mismatch at {}", k));
        }
        if actual_post[k].1.to_bits() != expected_post[k].1.to_bits() {
            return fail_case(c, &format!(
                "post_theta value mismatch at {}: expected {}, got {}",
                k, f64_hex(expected_post[k].1), f64_hex(actual_post[k].1)));
        }
    }

    CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let post_arr = match output.get("post_theta") {
        Some(JsonValue::Array(a)) => a,
        _ => panic!("expected_output missing post_theta"),
    };
    for v in post_arr {
        if let JsonValue::Object(o) = v {
            let id_bytes = match o.get("id") {
                Some(JsonValue::String(s)) => decode_hex(s).expect("bad id"),
                _ => panic!("missing post_theta id"),
            };
            assert_eq!(id_bytes.len(), 16);
            let t = match o.get("theta") {
                Some(JsonValue::String(s)) => parse_f64_hex(s).expect("bad theta"),
                _ => panic!("missing post_theta theta"),
            };
            encoder.write_bytes(&id_bytes);
            encoder.write_f64(t);
        } else {
            panic!("post_theta element not object");
        }
    }
}

fn fail_case(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false,
        diagnostic: Some(msg.into()) }
}

fn get_f64(obj: &JsonObject, key: &str) -> Option<f64> {
    let s = match obj.get(key) {
        Some(JsonValue::String(s)) => s,
        _ => return None,
    };
    parse_f64_hex(s)
}

fn parse_f64_hex(s: &str) -> Option<f64> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 { return None; }
    let mut bits: u64 = 0;
    for (i, b) in bytes.iter().enumerate() { bits |= (*b as u64) << (i * 8); }
    Some(f64::from_bits(bits))
}

fn random_id_bytes(rng: &mut SplitMix64) -> [u8; 16] {
    let lo = rng.next();
    let hi = rng.next();
    let mut bytes = [0u8; 16];
    bytes[0..8].copy_from_slice(&lo.to_le_bytes());
    bytes[8..16].copy_from_slice(&hi.to_le_bytes());
    bytes
}

fn bytes_to_rowid(bytes: &[u8; 16]) -> RowId {
    let mut acc: u128 = 0;
    for i in 0..16 {
        acc |= (bytes[i] as u128) << (i * 8);
    }
    RowId(acc)
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
