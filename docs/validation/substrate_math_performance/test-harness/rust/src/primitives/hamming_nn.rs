// src/primitives/hamming_nn.rs
//
// Mirror of Swift HammingNNPrimitive. Calls real reference at
// glref-rust-hamming_nn.rs via the geniuslocus-reference crate.

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, encode_hex, u32_hex, u8_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::fingerprint256::Fingerprint256;
use substrate_kit::hamming_nn;

pub struct HammingNNPrimitive;

impl HammingNNPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "hamming_nn",
            cookbook_section: "§8.2",
            reference_file: "glref-rust-hamming_nn.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let anchor = Fingerprint256::new(
                rng.next(), rng.next(), rng.next(), rng.next());

            let blocks_mask: u8 = [0xF, 0x3, 0xA, 0x4][i % 4];

            let cohort_size = 16usize;
            // k == cohort_size so the top-K returns the entire
            // cohort; sidesteps tie-breaking ambiguity at the
            // eviction boundary.
            let k = cohort_size;

            let mut cohort_bytes: Vec<[u8; 16]> = Vec::with_capacity(cohort_size);
            let mut cohort_fps: Vec<Fingerprint256> = Vec::with_capacity(cohort_size);
            let mut cohort: Vec<(u128, Fingerprint256)> = Vec::with_capacity(cohort_size);
            for _ in 0..cohort_size {
                let id_bytes = random_id_bytes(&mut rng);
                let fp = Fingerprint256::new(
                    rng.next(), rng.next(), rng.next(), rng.next());
                let row_id = bytes_to_u128(&id_bytes);
                cohort_bytes.push(id_bytes);
                cohort_fps.push(fp);
                cohort.push((row_id, fp));
            }

            let hits = hamming_nn::top_k(&anchor, cohort.clone(), k, blocks_mask);

            // Build u128 -> id_bytes lookup.
            let mut bytes_by_id: BTreeMap<u128, [u8; 16]> = BTreeMap::new();
            for b in &cohort_bytes {
                bytes_by_id.insert(bytes_to_u128(b), *b);
            }

            // Canonicalize: distance asc, id-bytes asc.
            let mut canon: Vec<([u8; 16], u32)> = hits.iter().map(|h| {
                let b = bytes_by_id.get(&h.row_id).copied().unwrap_or([0; 16]);
                (b, h.distance)
            }).collect();
            canon.sort_by(|a, b| {
                a.1.cmp(&b.1).then(a.0.cmp(&b.0))
            });

            let cohort_arr: Vec<JsonValue> = cohort_bytes.iter().enumerate().map(|(idx, b)| {
                let mut o: JsonObject = BTreeMap::new();
                o.insert("id".into(), JsonValue::String(encode_hex(b)));
                o.insert("fingerprint".into(),
                          JsonValue::String(encode_fp_le(&cohort_fps[idx])));
                JsonValue::Object(o)
            }).collect();

            let hits_arr: Vec<JsonValue> = canon.iter().map(|(b, d)| {
                let mut o: JsonObject = BTreeMap::new();
                o.insert("id".into(), JsonValue::String(encode_hex(b)));
                o.insert("distance".into(), JsonValue::String(u32_hex(*d)));
                JsonValue::Object(o)
            }).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("anchor".into(),
                          JsonValue::String(encode_fp_le(&anchor)));
            inputs.insert("blocks_bitmask".into(),
                          JsonValue::String(u8_hex(blocks_mask)));
            inputs.insert("k".into(),
                          JsonValue::String(u32_hex(k as u32)));
            inputs.insert("cohort".into(), JsonValue::Array(cohort_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("hits".into(), JsonValue::Array(hits_arr));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!(
                    "blocks=0x{:x}, k={}, |cohort|={}", blocks_mask, k, cohort_size),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "hamming_nn".to_string(),
            cookbook_section: "§8.2".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-hamming_nn.rs".to_string(),
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
    let anchor = match c.inputs.get("anchor") {
        Some(JsonValue::String(s)) => match parse_fp_le(s) {
            Some(f) => f, None => return fail_case(c, "malformed anchor"),
        },
        _ => return fail_case(c, "missing anchor"),
    };
    let bm_bytes = match c.inputs.get("blocks_bitmask") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 1 => b,
            _ => return fail_case(c, "malformed blocks_bitmask"),
        },
        _ => return fail_case(c, "missing blocks_bitmask"),
    };
    let blocks_mask = bm_bytes[0];

    let k_bytes = match c.inputs.get("k") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 4 => b,
            _ => return fail_case(c, "malformed k"),
        },
        _ => return fail_case(c, "missing k"),
    };
    let mut k_raw: u32 = 0;
    for j in 0..4 { k_raw |= (k_bytes[j] as u32) << (j * 8); }
    let k = k_raw as usize;

    let cohort_arr = match c.inputs.get("cohort") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing cohort"),
    };
    let mut cohort: Vec<(u128, Fingerprint256)> = Vec::with_capacity(cohort_arr.len());
    let mut bytes_by_id: BTreeMap<u128, [u8; 16]> = BTreeMap::new();
    for v in cohort_arr {
        match v {
            JsonValue::Object(o) => {
                let id_bytes_vec = match o.get("id") {
                    Some(JsonValue::String(s)) => match decode_hex(s) {
                        Ok(b) if b.len() == 16 => b,
                        _ => return fail_case(c, "malformed cohort id"),
                    },
                    _ => return fail_case(c, "missing cohort id"),
                };
                let mut id_bytes = [0u8; 16];
                id_bytes.copy_from_slice(&id_bytes_vec);
                let fp = match o.get("fingerprint") {
                    Some(JsonValue::String(s)) => match parse_fp_le(s) {
                        Some(f) => f, None => return fail_case(c, "malformed cohort fp"),
                    },
                    _ => return fail_case(c, "missing cohort fp"),
                };
                let row_id = bytes_to_u128(&id_bytes);
                cohort.push((row_id, fp));
                bytes_by_id.insert(row_id, id_bytes);
            }
            _ => return fail_case(c, "cohort element not object"),
        }
    }

    let hits = hamming_nn::top_k(&anchor, cohort, k, blocks_mask);
    let mut canon: Vec<([u8; 16], u32)> = hits.iter().map(|h| {
        let b = bytes_by_id.get(&h.row_id).copied().unwrap_or([0; 16]);
        (b, h.distance)
    }).collect();
    canon.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.cmp(&b.0)));

    let hits_arr = match c.expected_output.get("hits") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing expected hits"),
    };
    let mut expected: Vec<([u8; 16], u32)> = Vec::with_capacity(hits_arr.len());
    for v in hits_arr {
        match v {
            JsonValue::Object(o) => {
                let id_vec = match o.get("id") {
                    Some(JsonValue::String(s)) => match decode_hex(s) {
                        Ok(b) if b.len() == 16 => b,
                        _ => return fail_case(c, "malformed expected id"),
                    },
                    _ => return fail_case(c, "missing expected id"),
                };
                let mut id_bytes = [0u8; 16];
                id_bytes.copy_from_slice(&id_vec);
                let d_vec = match o.get("distance") {
                    Some(JsonValue::String(s)) => match decode_hex(s) {
                        Ok(b) if b.len() == 4 => b,
                        _ => return fail_case(c, "malformed expected distance"),
                    },
                    _ => return fail_case(c, "missing expected distance"),
                };
                let mut d: u32 = 0;
                for j in 0..4 { d |= (d_vec[j] as u32) << (j * 8); }
                expected.push((id_bytes, d));
            }
            _ => return fail_case(c, "expected hit not object"),
        }
    }

    if canon.len() != expected.len() {
        return fail_case(c, &format!(
            "hits length mismatch: {} vs {}", canon.len(), expected.len()));
    }

    for (b, d) in &canon {
        encoder.write_bytes(b);
        encoder.write_u32(*d);
    }

    for j in 0..canon.len() {
        if canon[j].0 != expected[j].0 {
            return fail_case(c, &format!("hits[{}] id mismatch", j));
        }
        if canon[j].1 != expected[j].1 {
            return fail_case(c, &format!(
                "hits[{}] distance mismatch: expected {}, got {}",
                j, expected[j].1, canon[j].1));
        }
    }

    CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let arr = match output.get("hits") {
        Some(JsonValue::Array(a)) => a,
        _ => panic!("expected_output missing hits"),
    };
    for v in arr {
        if let JsonValue::Object(o) = v {
            let id_bytes = match o.get("id") {
                Some(JsonValue::String(s)) => decode_hex(s).expect("bad id"),
                _ => panic!("missing hit id"),
            };
            assert_eq!(id_bytes.len(), 16);
            let d_bytes = match o.get("distance") {
                Some(JsonValue::String(s)) => decode_hex(s).expect("bad distance"),
                _ => panic!("missing hit distance"),
            };
            assert_eq!(d_bytes.len(), 4);
            let mut d: u32 = 0;
            for j in 0..4 { d |= (d_bytes[j] as u32) << (j * 8); }
            encoder.write_bytes(&id_bytes);
            encoder.write_u32(d);
        } else {
            panic!("hit not object");
        }
    }
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

fn bytes_to_u128(bytes: &[u8; 16]) -> u128 {
    let mut acc: u128 = 0;
    for i in 0..16 { acc |= (bytes[i] as u128) << (i * 8); }
    acc
}

fn encode_fp_le(fp: &Fingerprint256) -> String {
    let mut bytes = [0u8; 32];
    let blocks = [fp.block0, fp.block1, fp.block2, fp.block3];
    for (i, w) in blocks.iter().enumerate() {
        for j in 0..8 { bytes[i * 8 + j] = ((w >> (j * 8)) & 0xFF) as u8; }
    }
    encode_hex(&bytes)
}

fn parse_fp_le(s: &str) -> Option<Fingerprint256> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 32 { return None; }
    let mut blocks = [0u64; 4];
    for i in 0..4 {
        let mut w: u64 = 0;
        for j in 0..8 { w |= (bytes[i * 8 + j] as u64) << (j * 8); }
        blocks[i] = w;
    }
    Some(Fingerprint256::new(blocks[0], blocks[1], blocks[2], blocks[3]))
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
