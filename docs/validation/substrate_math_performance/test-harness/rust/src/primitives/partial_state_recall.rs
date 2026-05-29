// src/primitives/partial_state_recall.rs
//
// Mirror of Swift's PartialStateRecallPrimitive. Calls real
// reference at glref-rust-partial_state_recall.rs via the
// geniuslocus-reference crate.
//
// Input schema:
//   row_fingerprint      : Fingerprint256
//   anchor               : Fingerprint256
//   match_blocks_bitmask : u8
//   differ_blocks_bitmask: u8
//
// Output schema:
//   score : f64

use std::collections::{BTreeMap, HashSet};

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, f64_hex, u8_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::fingerprint256::Fingerprint256;
use substrate_kit::partial_state_recall::PartialStateRecall;

pub struct PartialStateRecallPrimitive;

impl PartialStateRecallPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "partial_state_recall",
            cookbook_section: "§8.8",
            reference_file: "glref-rust-partial_state_recall.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let row = Fingerprint256::new(rng.next(), rng.next(), rng.next(), rng.next());
            let anchor = Fingerprint256::new(rng.next(), rng.next(), rng.next(), rng.next());

            let (m_mask, d_mask): (u8, u8) = [
                (0x3, 0xC),
                (0x5, 0xA),
                (0x9, 0x6),
                (0x1, 0xE),
            ][i % 4];

            let match_set = bitmask_to_blocks(m_mask);
            let differ_set = bitmask_to_blocks(d_mask);
            let score = PartialStateRecall::score(row, anchor, &match_set, &differ_set);

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("row_fingerprint".into(),
                          JsonValue::String(encode_fingerprint(&row)));
            inputs.insert("anchor".into(),
                          JsonValue::String(encode_fingerprint(&anchor)));
            inputs.insert("match_blocks_bitmask".into(),
                          JsonValue::String(u8_hex(m_mask)));
            inputs.insert("differ_blocks_bitmask".into(),
                          JsonValue::String(u8_hex(d_mask)));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("score".into(), JsonValue::String(f64_hex(score)));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!(
                    "match=0x{:01X}, differ=0x{:01X}, score={:.6}",
                    m_mask, d_mask, score),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "partial_state_recall".to_string(),
            cookbook_section: "§8.8".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-partial_state_recall.rs".to_string(),
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
    let row = match c.inputs.get("row_fingerprint") {
        Some(JsonValue::String(s)) => match parse_fingerprint(s) {
            Some(f) => f, None => return fail_case(c, "malformed row_fingerprint"),
        },
        _ => return fail_case(c, "missing row_fingerprint"),
    };
    let anchor = match c.inputs.get("anchor") {
        Some(JsonValue::String(s)) => match parse_fingerprint(s) {
            Some(f) => f, None => return fail_case(c, "malformed anchor"),
        },
        _ => return fail_case(c, "missing anchor"),
    };
    let m_mask = match c.inputs.get("match_blocks_bitmask") {
        Some(JsonValue::String(s)) => match parse_u8(s) {
            Some(m) => m, None => return fail_case(c, "malformed match_blocks_bitmask"),
        },
        _ => return fail_case(c, "missing match_blocks_bitmask"),
    };
    let d_mask = match c.inputs.get("differ_blocks_bitmask") {
        Some(JsonValue::String(s)) => match parse_u8(s) {
            Some(m) => m, None => return fail_case(c, "malformed differ_blocks_bitmask"),
        },
        _ => return fail_case(c, "missing differ_blocks_bitmask"),
    };

    let actual = PartialStateRecall::score(
        row, anchor, &bitmask_to_blocks(m_mask), &bitmask_to_blocks(d_mask));

    let expected = match c.expected_output.get("score") {
        Some(JsonValue::String(s)) => match parse_f64_hex(s) {
            Some(f) => f, None => return fail_case(c, "malformed expected score"),
        },
        _ => return fail_case(c, "missing expected score"),
    };

    encoder.write_f64(actual);

    if actual.to_bits() == expected.to_bits() {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "score mismatch: expected {}, got {}",
                f64_hex(expected), f64_hex(actual))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let s = match output.get("score") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing score"),
    };
    let f = parse_f64_hex(s).expect("malformed score hex");
    encoder.write_f64(f);
}

fn fail_case(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.into()) }
}

fn bitmask_to_blocks(mask: u8) -> HashSet<u8> {
    let mut s = HashSet::new();
    for k in 0..4u8 { if (mask >> k) & 1 == 1 { s.insert(k); } }
    s
}

fn encode_fingerprint(fp: &Fingerprint256) -> String {
    let mut bytes = [0u8; 32];
    let blocks = [fp.block0, fp.block1, fp.block2, fp.block3];
    for (i, w) in blocks.iter().enumerate() {
        for j in 0..8 { bytes[i * 8 + j] = ((w >> (j * 8)) & 0xFF) as u8; }
    }
    let mut out = String::with_capacity(2 + 64);
    out.push_str("0x");
    for b in bytes.iter() { out.push_str(&format!("{:02x}", b)); }
    out
}

fn parse_fingerprint(s: &str) -> Option<Fingerprint256> {
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

fn parse_u8(s: &str) -> Option<u8> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 1 { return None; }
    Some(bytes[0])
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
