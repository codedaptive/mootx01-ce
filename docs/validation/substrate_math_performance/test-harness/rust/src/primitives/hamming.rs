// src/primitives/hamming.rs
//
// Mirror of the Swift HammingPrimitive.swift. Calls the real
// reference at glref-rust-hamming.rs via the geniuslocus-reference
// crate dependency.
//
// Input schema (pair-at-a-time cases, 32 of them):
//   a              : Fingerprint256 (32-byte hex, LE)
//   b              : Fingerprint256
//   blocks_bitmask : u8 in 0..16 (bit 0=block0, bit 1=block1, ...)
//
// Output schema (pair):
//   distance : u32
//
// Input schema (batched cases, 8 of them, one per batch_size in
//   {0, 1, 2, 4, 8, 16, 32, 64}). Batched cases test the
//   `hamming_distance_batch` trait method (always all 4 blocks):
//
//   probe      : Fingerprint256
//   candidates : [Fingerprint256]   (length = batch_size)
//
// Output schema (batched):
//   distances  : [u32]              (length = batch_size)
//
// Per the kernel-learned-dispatch decision
// (DECISION_KERNEL_LEARNED_DISPATCH_2026-05-17), batched output
// MUST equal sequential output byte-for-byte in at-rest
// little-endian canonical form. The conformance gate enforces
// this.

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, u32_hex, u8_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_types::fingerprint256::Fingerprint256 as RealFingerprint256;
use substrate_types::hamming as real_hamming;

pub struct HammingPrimitive;

impl HammingPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "hamming",
            cookbook_section: "§8.2",
            reference_file: "glref-rust-hamming.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let pair_count = 32;
        let batched_sizes: [usize; 8] = [0, 1, 2, 4, 8, 16, 32, 64];
        let mut cases = Vec::with_capacity(pair_count + batched_sizes.len());

        // ----- Pair-at-a-time cases (unchanged from prior versions).
        for i in 0..pair_count {
            let a = RealFingerprint256 {
                block0: rng.next(), block1: rng.next(),
                block2: rng.next(), block3: rng.next(),
            };
            let b = RealFingerprint256 {
                block0: rng.next(), block1: rng.next(),
                block2: rng.next(), block3: rng.next(),
            };

            // Same cycle as Swift: {0x1, 0x3, 0x7, 0xF}.
            let blocks_bitmask: u8 = [0x1u8, 0x3, 0x7, 0xF][i % 4];

            let distance = real_hamming::distance(&a, &b, blocks_bitmask);

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("a".into(), JsonValue::String(encode_fingerprint(&a)));
            inputs.insert("b".into(), JsonValue::String(encode_fingerprint(&b)));
            inputs.insert(
                "blocks_bitmask".into(),
                JsonValue::String(u8_hex(blocks_bitmask)),
            );

            let mut output: JsonObject = BTreeMap::new();
            output.insert(
                "distance".into(),
                JsonValue::String(u32_hex(distance as u32)),
            );

            let description = format!(
                "blocks_bitmask 0x{:01X}, distance {}", blocks_bitmask, distance);
            let id = format!("case_{:03}", i);
            cases.push(VectorCase {
                id,
                description,
                inputs,
                expected_output: output,
            });
        }

        // ----- Batched cases (one per batch_size in batched_sizes).
        //
        // The batched API tests `SubstrateKernel::hamming_distance_batch`,
        // which always uses all 4 blocks (no per-call mask). Output is
        // a Vec<u32> of distances in candidate order. Per the
        // kernel-learned-dispatch decision, this output MUST byte-equal
        // a pair-at-a-time loop in at-rest LE form.
        let kernel = crate::harness::kernel_selector::current();
        for (k, &batch_size) in batched_sizes.iter().enumerate() {
            let probe = RealFingerprint256 {
                block0: rng.next(), block1: rng.next(),
                block2: rng.next(), block3: rng.next(),
            };
            let candidates: Vec<RealFingerprint256> = (0..batch_size)
                .map(|_| RealFingerprint256 {
                    block0: rng.next(), block1: rng.next(),
                    block2: rng.next(), block3: rng.next(),
                })
                .collect();

            let mut distances = vec![0u32; batch_size];
            kernel.hamming_distance_batch(&probe, &candidates, &mut distances);

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("probe".into(), JsonValue::String(encode_fingerprint(&probe)));
            inputs.insert(
                "candidates".into(),
                JsonValue::Array(
                    candidates.iter()
                        .map(|c| JsonValue::String(encode_fingerprint(c)))
                        .collect(),
                ),
            );

            let mut output: JsonObject = BTreeMap::new();
            output.insert(
                "distances".into(),
                JsonValue::Array(
                    distances.iter()
                        .map(|d| JsonValue::String(u32_hex(*d)))
                        .collect(),
                ),
            );

            let description = format!(
                "batched, batch_size {}, sum_distance {}",
                batch_size,
                distances.iter().sum::<u32>());
            let id = format!("case_{:03}", pair_count + k);
            cases.push(VectorCase {
                id,
                description,
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "hamming".to_string(),
            cookbook_section: "§8.2".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-hamming.rs".to_string(),
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
        let crc_ok = crc_actual == file.output_crc32;
        Ok(ValidationResult {
            passed: all_passed && crc_ok,
            case_results,
            crc_expected: file.output_crc32,
            crc_actual,
        })
    }
}

fn validate_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    // Batched cases have a `distances` array in expected_output.
    // Pair-at-a-time cases have a single `distance` scalar.
    if c.expected_output.contains_key("distances") {
        return validate_batched_case(c, encoder);
    }
    validate_pair_case(c, encoder)
}

fn validate_pair_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let a = match c.inputs.get("a") {
        Some(JsonValue::String(s)) => match parse_fingerprint(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed a".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing a".into()) },
    };
    let b = match c.inputs.get("b") {
        Some(JsonValue::String(s)) => match parse_fingerprint(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed b".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing b".into()) },
    };
    let mask = match c.inputs.get("blocks_bitmask") {
        Some(JsonValue::String(s)) => match parse_u8(s) {
            Some(m) => m,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed blocks_bitmask".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing blocks_bitmask".into()) },
    };

    let actual = real_hamming::distance(&a, &b, mask) as u32;
    let expected = match c.expected_output.get("distance") {
        Some(JsonValue::String(s)) => match parse_u32(s) {
            Some(v) => v,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed expected distance".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected distance".into()) },
    };

    encoder.write_u32(actual);

    if actual == expected {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "distance mismatch: expected {}, got {}",
                u32_hex(expected), u32_hex(actual))),
        }
    }
}

fn validate_batched_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let probe = match c.inputs.get("probe") {
        Some(JsonValue::String(s)) => match parse_fingerprint(s) {
            Some(f) => f,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed probe".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing probe".into()) },
    };
    let candidates = match c.inputs.get("candidates") {
        Some(JsonValue::Array(arr)) => {
            let mut parsed = Vec::with_capacity(arr.len());
            for item in arr {
                match item {
                    JsonValue::String(s) => match parse_fingerprint(s) {
                        Some(f) => parsed.push(f),
                        None => return CaseResult { id: c.id.clone(), passed: false,
                            diagnostic: Some("malformed candidate".into()) },
                    },
                    _ => return CaseResult { id: c.id.clone(), passed: false,
                        diagnostic: Some("candidate not a string".into()) },
                }
            }
            parsed
        }
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing candidates".into()) },
    };
    let expected = match c.expected_output.get("distances") {
        Some(JsonValue::Array(arr)) => {
            let mut parsed = Vec::with_capacity(arr.len());
            for item in arr {
                match item {
                    JsonValue::String(s) => match parse_u32(s) {
                        Some(v) => parsed.push(v),
                        None => return CaseResult { id: c.id.clone(), passed: false,
                            diagnostic: Some("malformed expected distance".into()) },
                    },
                    _ => return CaseResult { id: c.id.clone(), passed: false,
                        diagnostic: Some("expected distance not a string".into()) },
                }
            }
            parsed
        }
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected distances".into()) },
    };

    if candidates.len() != expected.len() {
        return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some(format!(
                "length mismatch: {} candidates vs {} expected",
                candidates.len(), expected.len())) };
    }

    let kernel = crate::harness::kernel_selector::current();
    let mut actual = vec![0u32; candidates.len()];
    kernel.hamming_distance_batch(&probe, &candidates, &mut actual);

    // Canonical binary encoding: u32 LE length prefix + N u32 LE values.
    // Per the kernel-learned-dispatch decision, this byte stream must
    // exactly equal a sequential loop of pair-at-a-time u32 LE writes.
    encoder.write_u32(actual.len() as u32);
    for v in &actual { encoder.write_u32(*v); }

    if actual == expected {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        let first_diff = actual.iter().zip(expected.iter())
            .position(|(a, b)| a != b).unwrap_or(0);
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "batched distance mismatch at index {}: expected {}, got {}",
                first_diff,
                u32_hex(expected[first_diff]),
                u32_hex(actual[first_diff]))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    // Dispatch on which schema this case uses. Order MUST match
    // validate_case so generator and validator produce identical
    // canonical byte streams.
    if let Some(JsonValue::Array(arr)) = output.get("distances") {
        encoder.write_u32(arr.len() as u32);
        for item in arr {
            let s = match item {
                JsonValue::String(s) => s,
                _ => panic!("distances element not a string"),
            };
            let v = parse_u32(s).expect("malformed batched distance hex");
            encoder.write_u32(v);
        }
        return;
    }

    let s = match output.get("distance") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing distance"),
    };
    let v = parse_u32(s).expect("malformed distance hex");
    encoder.write_u32(v);
}

fn encode_fingerprint(fp: &RealFingerprint256) -> String {
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

fn parse_fingerprint(s: &str) -> Option<RealFingerprint256> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 32 { return None; }
    let mut blocks = [0u64; 4];
    for i in 0..4 {
        let mut w: u64 = 0;
        for j in 0..8 { w |= (bytes[i * 8 + j] as u64) << (j * 8); }
        blocks[i] = w;
    }
    Some(RealFingerprint256 {
        block0: blocks[0], block1: blocks[1],
        block2: blocks[2], block3: blocks[3],
    })
}

fn parse_u32(s: &str) -> Option<u32> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 4 { return None; }
    let mut v: u32 = 0;
    for (i, b) in bytes.iter().enumerate() { v |= (*b as u32) << (i * 8); }
    Some(v)
}

fn parse_u8(s: &str) -> Option<u8> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 1 { return None; }
    Some(bytes[0])
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
