// src/primitives/shingle_similarity.rs
//
// Character-shingle Jaccard similarity (the substrate-owned recall-
// ranking set primitive). Mirror of Swift's ShingleSimilarityPrimitive.
//
// Wired to the production reference at
// packages/libs/SubstrateML/rust/src/shingle_similarity.rs via the
// substrate_ml crate (validated directly, like NMF).
//
// Determinism: similarity is a pure function of two strings; the value
// is an f32 ratio of two integer set cardinalities, bit-identical
// across Swift and Rust on the same inputs. The generated test strings
// are lowercase ASCII letters and spaces ONLY, so `to_lowercase()`
// (Rust) and `lowercased()` (Swift) are both no-ops and the shingle
// sets are byte-identical.
//
// Input schema:
//   a : string (plain UTF-8, lowercase ASCII + spaces)
//   b : string (plain UTF-8, lowercase ASCII + spaces)
//
// Output schema:
//   similarity : f32 hex

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

use substrate_ml::shingle_similarity;

pub struct ShingleSimilarityPrimitive;

impl ShingleSimilarityPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "shingle_similarity",
            cookbook_section: "§8.20",
            reference_file: "shingle_similarity.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            // Same case construction as the Swift generator: identical,
            // independent, superset-ish, and shared-prefix pairs so the
            // 0.0 / 1.0 / partial branches are all exercised.
            let a = random_phrase(&mut rng);
            let b = match i % 4 {
                0 => a.clone(),                                        // identical -> 1.0
                1 => random_phrase(&mut rng),                          // independent
                2 => format!("{} {}", a, random_phrase(&mut rng)),     // superset-ish
                _ => share_prefix(&a, &mut rng),                       // partial
            };

            let s = shingle_similarity::similarity(&a, &b);

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("a".into(), JsonValue::String(a.clone()));
            inputs.insert("b".into(), JsonValue::String(b.clone()));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("similarity".into(), JsonValue::String(f32_hex(s)));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!("|a|={}, |b|={}, sim={}", a.chars().count(), b.chars().count(), s),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "shingle_similarity".to_string(),
            cookbook_section: "§8.20".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "shingle_similarity.rs".to_string(),
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
        Some(JsonValue::String(s)) => s,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing a".into()) },
    };
    let b = match c.inputs.get("b") {
        Some(JsonValue::String(s)) => s,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing b".into()) },
    };

    let actual = shingle_similarity::similarity(a, b);

    let expected = match c.expected_output.get("similarity") {
        Some(JsonValue::String(s)) => match parse_f32_hex(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed expected similarity".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected similarity".into()) },
    };

    encoder.write_f32(actual);

    if actual.to_bits() == expected.to_bits() {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "similarity mismatch: expected {}, got {}",
                f32_hex(expected), f32_hex(actual))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let s = match output.get("similarity") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing similarity"),
    };
    let f = parse_f32_hex(s).expect("malformed similarity hex");
    encoder.write_f32(f);
}

fn parse_f32_hex(s: &str) -> Option<f32> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 4 { return None; }
    let mut bits: u32 = 0;
    for (i, b) in bytes.iter().enumerate() { bits |= (*b as u32) << (i * 8); }
    Some(f32::from_bits(bits))
}

/// 26 lowercase ASCII letters. Case folding is a no-op on these, so the
/// generated strings are byte-identical between Rust's `to_lowercase()`
/// and Swift's `lowercased()`.
const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz";

/// A random word of 1–8 lowercase-ASCII letters. Identical construction
/// to the Swift generator: `1 + next() % 8` letters, each `next() % 26`.
fn random_word(rng: &mut SplitMix64) -> String {
    let len = 1 + (rng.next() % 8) as usize;
    let mut s = String::with_capacity(len);
    for _ in 0..len {
        let idx = (rng.next() % ALPHABET.len() as u64) as usize;
        s.push(ALPHABET[idx] as char);
    }
    s
}

/// A random phrase of 1–5 space-separated words.
fn random_phrase(rng: &mut SplitMix64) -> String {
    let words = 1 + (rng.next() % 5) as usize;
    let mut parts = Vec::with_capacity(words);
    for _ in 0..words { parts.push(random_word(rng)); }
    parts.join(" ")
}

/// A new phrase that shares `a`'s first word, then diverges.
fn share_prefix(a: &str, rng: &mut SplitMix64) -> String {
    let first = a.split(' ').next().unwrap_or("shared");
    format!("{} {}", first, random_phrase(rng))
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
