// src/primitives/jaccard.rs
//
// Mirror of the Swift JaccardPrimitive.swift. Calls the production
// reference at substrate_types::jaccard (cookbook §8.21, W2.5 Track
// M1 activation) — the production code is the conformance subject,
// like shingle_similarity and NMF.
//
// Determinism: similarity = popcount(a AND b) / popcount(a OR b).
// Both popcounts are exact small integers; the single f64 division
// of exact integers is IEEE-754-identical across ports, so outputs
// are gated on bit-pattern equality (f64 hex), not tolerance.
//
// Empty-union convention (pinned by case_032/case_033): both-empty
// or either-empty-versus-anything unions of zero yield similarity
// 0.0, NEVER 1.0 — an all-zero fingerprint carries no evidence and
// must not read as a perfect match in a retrieval lane.
//
// Input schema (34 cases):
//   a : Fingerprint256 (32-byte hex, LE — same encoding as hamming)
//   b : Fingerprint256
//
// Case construction cycles i % 4 over the 32 seeded cases:
//   0 : independent random pair          (typical partial overlap)
//   1 : b = a                            (identical -> 1.0)
//   2 : b = complement of a              (disjoint -> 0.0)
//   3 : b = a AND random mask            (subset partial overlap)
// plus two fixed edge cases: case_032 both-zero, case_033 zero vs
// random (both -> 0.0 by the empty-union convention).
//
// Output schema:
//   similarity : f64 hex (IEEE-754 bit pattern, LE)
//   distance   : f64 hex (1 - similarity)

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

use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::jaccard as real_jaccard;

pub struct JaccardPrimitive;

impl JaccardPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "jaccard",
            cookbook_section: "§8.21",
            reference_file: "jaccard.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let seeded_count = 32;
        let mut cases = Vec::with_capacity(seeded_count + 2);

        for i in 0..seeded_count {
            let a = Fingerprint256 {
                block0: rng.next(), block1: rng.next(),
                block2: rng.next(), block3: rng.next(),
            };
            let b = match i % 4 {
                0 => Fingerprint256 {
                    block0: rng.next(), block1: rng.next(),
                    block2: rng.next(), block3: rng.next(),
                },
                1 => a,
                // Complement: intersection with a is empty, union is all
                // 256 bits -> similarity exactly 0.0.
                2 => Fingerprint256 {
                    block0: !a.block0, block1: !a.block1,
                    block2: !a.block2, block3: !a.block3,
                },
                // Subset of a: intersection == b, union == a -> similarity
                // popcount(b)/popcount(a), a genuine interior value.
                _ => Fingerprint256 {
                    block0: a.block0 & rng.next(), block1: a.block1 & rng.next(),
                    block2: a.block2 & rng.next(), block3: a.block3 & rng.next(),
                },
            };
            cases.push(Self::make_case(i, &a, &b));
        }

        // Fixed edge cases pinning the empty-union convention.
        cases.push(Self::make_case(seeded_count, &Fingerprint256::ZERO, &Fingerprint256::ZERO));
        let random_b = Fingerprint256 {
            block0: rng.next(), block1: rng.next(),
            block2: rng.next(), block3: rng.next(),
        };
        cases.push(Self::make_case(seeded_count + 1, &Fingerprint256::ZERO, &random_b));

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases {
            Self::encode_output(&c.expected_output, &mut encoder)?;
        }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "jaccard".to_string(),
            cookbook_section: "§8.21".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "jaccard.rs".to_string(),
            },
            seed,
            generated_at: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            output_crc32: crc,
            cases,
        })
    }

    fn make_case(index: usize, a: &Fingerprint256, b: &Fingerprint256) -> VectorCase {
        let similarity = real_jaccard::similarity(a, b);
        let distance = real_jaccard::distance(a, b);

        let mut inputs = JsonObject::new();
        inputs.insert("a".to_string(), JsonValue::String(Self::encode_fingerprint(a)));
        inputs.insert("b".to_string(), JsonValue::String(Self::encode_fingerprint(b)));

        let mut output = JsonObject::new();
        output.insert("similarity".to_string(), JsonValue::String(f64_hex(similarity)));
        output.insert("distance".to_string(), JsonValue::String(f64_hex(distance)));

        VectorCase {
            id: format!("case_{:03}", index),
            description: format!("similarity {}", similarity),
            inputs,
            expected_output: output,
        }
    }

    pub fn validate(file: &VectorFile) -> Result<ValidationResult, Box<dyn std::error::Error>> {
        let mut case_results = Vec::with_capacity(file.cases.len());
        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &file.cases {
            case_results.push(Self::validate_case(c, &mut encoder));
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

    fn validate_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
        let a = match Self::parse_input_fingerprint(c, "a") {
            Ok(v) => v,
            Err(msg) => return Self::fail(c, msg),
        };
        let b = match Self::parse_input_fingerprint(c, "b") {
            Ok(v) => v,
            Err(msg) => return Self::fail(c, msg),
        };

        let actual_similarity = real_jaccard::similarity(&a, &b);
        let actual_distance = real_jaccard::distance(&a, &b);

        let expected_similarity = match Self::parse_output_f64(c, "similarity") {
            Ok(v) => v,
            Err(msg) => return Self::fail(c, msg),
        };
        let expected_distance = match Self::parse_output_f64(c, "distance") {
            Ok(v) => v,
            Err(msg) => return Self::fail(c, msg),
        };

        encoder.write_f64(actual_similarity);
        encoder.write_f64(actual_distance);

        if actual_similarity.to_bits() == expected_similarity.to_bits()
            && actual_distance.to_bits() == expected_distance.to_bits()
        {
            CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
        } else {
            CaseResult {
                id: c.id.clone(),
                passed: false,
                diagnostic: Some(format!(
                    "mismatch: expected sim {} dist {}, got sim {} dist {}",
                    f64_hex(expected_similarity), f64_hex(expected_distance),
                    f64_hex(actual_similarity), f64_hex(actual_distance)
                )),
            }
        }
    }

    fn encode_output(
        output: &JsonObject,
        encoder: &mut CanonicalBinaryEncoder,
    ) -> Result<(), Box<dyn std::error::Error>> {
        // Order MUST match validate_case (similarity then distance) so
        // generator and validator produce identical canonical byte streams.
        let s = Self::object_f64(output, "similarity")
            .ok_or("expected_output missing or malformed similarity")?;
        let d = Self::object_f64(output, "distance")
            .ok_or("expected_output missing or malformed distance")?;
        encoder.write_f64(s);
        encoder.write_f64(d);
        Ok(())
    }

    // ----- Helpers

    fn fail(c: &VectorCase, msg: &str) -> CaseResult {
        CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.to_string()) }
    }

    /// Hex-encode a Fingerprint256 as 64 lowercase chars (32 bytes LE) —
    /// the same encoding hamming uses, so JSON strings are byte-identical
    /// across languages.
    fn encode_fingerprint(fp: &Fingerprint256) -> String {
        let mut bytes = [0u8; 32];
        for (i, w) in [fp.block0, fp.block1, fp.block2, fp.block3].iter().enumerate() {
            bytes[i * 8..(i + 1) * 8].copy_from_slice(&w.to_le_bytes());
        }
        encode_hex(&bytes)
    }

    fn parse_fingerprint(s: &str) -> Option<Fingerprint256> {
        let bytes = decode_hex(s).ok()?;
        if bytes.len() != 32 {
            return None;
        }
        let mut blocks = [0u64; 4];
        for (i, block) in blocks.iter_mut().enumerate() {
            let mut w = [0u8; 8];
            w.copy_from_slice(&bytes[i * 8..(i + 1) * 8]);
            *block = u64::from_le_bytes(w);
        }
        Some(Fingerprint256 {
            block0: blocks[0], block1: blocks[1],
            block2: blocks[2], block3: blocks[3],
        })
    }

    fn parse_input_fingerprint(c: &VectorCase, key: &str) -> Result<Fingerprint256, &'static str> {
        match c.inputs.get(key) {
            Some(JsonValue::String(s)) => {
                Self::parse_fingerprint(s).ok_or("malformed fingerprint")
            }
            _ => Err("missing fingerprint input"),
        }
    }

    fn parse_output_f64(c: &VectorCase, key: &str) -> Result<f64, &'static str> {
        match c.expected_output.get(key) {
            Some(JsonValue::String(s)) => {
                Self::parse_f64_hex(s).ok_or("malformed expected f64")
            }
            _ => Err("missing expected f64"),
        }
    }

    fn object_f64(output: &JsonObject, key: &str) -> Option<f64> {
        match output.get(key) {
            Some(JsonValue::String(s)) => Self::parse_f64_hex(s),
            _ => None,
        }
    }

    fn parse_f64_hex(s: &str) -> Option<f64> {
        let bytes = decode_hex(s).ok()?;
        if bytes.len() != 8 {
            return None;
        }
        let mut w = [0u8; 8];
        w.copy_from_slice(&bytes);
        Some(f64::from_bits(u64::from_le_bytes(w)))
    }
}
