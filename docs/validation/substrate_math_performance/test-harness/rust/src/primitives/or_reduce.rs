// src/primitives/or_reduce.rs
//
// Mirror of Swift's ORReducePrimitive. Calls real reference at
// glref-rust-or_reduce.rs via the geniuslocus-reference crate.
//
// Input schema (pair-at-a-time cases, 32 of them):
//   count        : u32
//   fingerprints : array of Fingerprint256 (length = count)
//
// Output schema (pair):
//   reduced : Fingerprint256
//
// Input schema (batched cases, 8 of them, one per batch_size in
//   {0, 1, 2, 4, 8, 16, 32, 64}). Batched cases test the
//   `or_reduce_batch` trait method: M independent reductions in
//   one call. Each inner batch is a cohort of fingerprints; the
//   inner cohort size cycles through {1, 2, 4, 8} to give
//   coverage. The outer length is `batch_size`.
//
//   inner_count : u32       (uniform across this case's batches)
//   batches     : [[Fingerprint256]]   (length = batch_size, each
//                                       inner length = inner_count)
//
// Output schema (batched):
//   reduced_batch : [Fingerprint256]   (length = batch_size)
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
    hex::{decode_hex, u32_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::fingerprint256::Fingerprint256 as RealFingerprint256;
use substrate_kit::or_reduce as real_or_reduce;

pub struct ORReducePrimitive;

impl ORReducePrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "or_reduce",
            cookbook_section: "§8.5",
            reference_file: "glref-rust-or_reduce.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let pair_count = 32usize;
        let batched_sizes: [usize; 8] = [0, 1, 2, 4, 8, 16, 32, 64];
        let mut cases = Vec::with_capacity(pair_count + batched_sizes.len());

        // ----- Pair-at-a-time cases (unchanged from prior versions).
        for i in 0..pair_count {
            let count: usize = [1usize, 2, 4, 8][i % 4];
            let mut cohort: Vec<RealFingerprint256> = Vec::with_capacity(count);
            for _ in 0..count {
                cohort.push(RealFingerprint256 {
                    block0: rng.next(), block1: rng.next(),
                    block2: rng.next(), block3: rng.next(),
                });
            }

            let reduced = real_or_reduce::reduce(cohort.iter().copied());

            let fp_arr: Vec<JsonValue> = cohort.iter()
                .map(|fp| JsonValue::String(encode_fingerprint(fp))).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("count".into(), JsonValue::String(u32_hex(count as u32)));
            inputs.insert("fingerprints".into(), JsonValue::Array(fp_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("reduced".into(), JsonValue::String(encode_fingerprint(&reduced)));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!("cohort size {}", count),
                inputs,
                expected_output: output,
            });
        }

        // ----- Batched cases (one per batch_size in batched_sizes).
        //
        // Each case picks an inner_count from {1, 2, 4, 8} and
        // builds `batch_size` independent cohorts of that size.
        // The kernel's `or_reduce_batch` produces `batch_size`
        // reduced fingerprints in one call.
        let kernel = crate::harness::kernel_selector::current();
        for (k, &batch_size) in batched_sizes.iter().enumerate() {
            let inner_count: usize = [1usize, 2, 4, 8][k % 4];
            let mut batches: Vec<Vec<RealFingerprint256>> = Vec::with_capacity(batch_size);
            for _ in 0..batch_size {
                let mut cohort: Vec<RealFingerprint256> = Vec::with_capacity(inner_count);
                for _ in 0..inner_count {
                    cohort.push(RealFingerprint256 {
                        block0: rng.next(), block1: rng.next(),
                        block2: rng.next(), block3: rng.next(),
                    });
                }
                batches.push(cohort);
            }

            let batch_slices: Vec<&[RealFingerprint256]> = batches.iter().map(|v| v.as_slice()).collect();
            let mut reduced_batch = vec![RealFingerprint256::ZERO; batch_size];
            kernel.or_reduce_batch(&batch_slices, &mut reduced_batch);

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert(
                "inner_count".into(),
                JsonValue::String(u32_hex(inner_count as u32)),
            );
            let outer_arr: Vec<JsonValue> = batches.iter()
                .map(|cohort| JsonValue::Array(
                    cohort.iter()
                        .map(|fp| JsonValue::String(encode_fingerprint(fp)))
                        .collect(),
                ))
                .collect();
            inputs.insert("batches".into(), JsonValue::Array(outer_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert(
                "reduced_batch".into(),
                JsonValue::Array(
                    reduced_batch.iter()
                        .map(|fp| JsonValue::String(encode_fingerprint(fp)))
                        .collect(),
                ),
            );

            cases.push(VectorCase {
                id: format!("case_{:03}", pair_count + k),
                description: format!(
                    "batched, batch_size {}, inner_count {}",
                    batch_size, inner_count),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "or_reduce".to_string(),
            cookbook_section: "§8.5".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-or_reduce.rs".to_string(),
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
    // Batched cases have a `reduced_batch` array in expected_output.
    // Pair-at-a-time cases have a single `reduced` scalar.
    if c.expected_output.contains_key("reduced_batch") {
        return validate_batched_case(c, encoder);
    }
    validate_pair_case(c, encoder)
}

fn validate_pair_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let fp_arr = match c.inputs.get("fingerprints") {
        Some(JsonValue::Array(a)) => a,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing fingerprints".into()) },
    };
    let mut cohort: Vec<RealFingerprint256> = Vec::with_capacity(fp_arr.len());
    for v in fp_arr {
        match v {
            JsonValue::String(s) => match parse_fingerprint(s) {
                Some(fp) => cohort.push(fp),
                None => return CaseResult { id: c.id.clone(), passed: false,
                    diagnostic: Some("malformed fingerprint".into()) },
            },
            _ => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("non-string fingerprint element".into()) },
        }
    }

    let actual = real_or_reduce::reduce(cohort.iter().copied());

    let expected = match c.expected_output.get("reduced") {
        Some(JsonValue::String(s)) => match parse_fingerprint(s) {
            Some(fp) => fp,
            None => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed expected reduced".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected reduced".into()) },
    };

    write_fingerprint(&actual, encoder);

    if fp_eq(&actual, &expected) {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "reduced mismatch: expected {}, got {}",
                encode_fingerprint(&expected), encode_fingerprint(&actual))),
        }
    }
}

fn validate_batched_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let outer_arr = match c.inputs.get("batches") {
        Some(JsonValue::Array(a)) => a,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing batches".into()) },
    };
    let mut batches: Vec<Vec<RealFingerprint256>> = Vec::with_capacity(outer_arr.len());
    for cohort_val in outer_arr {
        let cohort_arr = match cohort_val {
            JsonValue::Array(a) => a,
            _ => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("batches element not an array".into()) },
        };
        let mut cohort: Vec<RealFingerprint256> = Vec::with_capacity(cohort_arr.len());
        for v in cohort_arr {
            match v {
                JsonValue::String(s) => match parse_fingerprint(s) {
                    Some(fp) => cohort.push(fp),
                    None => return CaseResult { id: c.id.clone(), passed: false,
                        diagnostic: Some("malformed fingerprint in batch".into()) },
                },
                _ => return CaseResult { id: c.id.clone(), passed: false,
                    diagnostic: Some("non-string fingerprint in batch".into()) },
            }
        }
        batches.push(cohort);
    }

    let exp_arr = match c.expected_output.get("reduced_batch") {
        Some(JsonValue::Array(a)) => a,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected reduced_batch".into()) },
    };
    let mut expected: Vec<RealFingerprint256> = Vec::with_capacity(exp_arr.len());
    for v in exp_arr {
        match v {
            JsonValue::String(s) => match parse_fingerprint(s) {
                Some(fp) => expected.push(fp),
                None => return CaseResult { id: c.id.clone(), passed: false,
                    diagnostic: Some("malformed expected reduced".into()) },
            },
            _ => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("expected reduced not a string".into()) },
        }
    }

    if batches.len() != expected.len() {
        return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some(format!(
                "length mismatch: {} batches vs {} expected",
                batches.len(), expected.len())) };
    }

    let kernel = crate::harness::kernel_selector::current();
    let batch_slices: Vec<&[RealFingerprint256]> = batches.iter().map(|v| v.as_slice()).collect();
    let mut actual = vec![RealFingerprint256::ZERO; batches.len()];
    kernel.or_reduce_batch(&batch_slices, &mut actual);

    // Canonical binary encoding: u32 LE length prefix + N Fingerprint256
    // (each as 4 u64 LE = 32 bytes).
    encoder.write_u32(actual.len() as u32);
    for fp in &actual { write_fingerprint(fp, encoder); }

    let mut all_match = true;
    let mut first_diff = 0usize;
    for i in 0..actual.len() {
        if !fp_eq(&actual[i], &expected[i]) {
            all_match = false;
            first_diff = i;
            break;
        }
    }

    if all_match {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "batched reduced mismatch at index {}: expected {}, got {}",
                first_diff,
                encode_fingerprint(&expected[first_diff]),
                encode_fingerprint(&actual[first_diff]))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    // Dispatch on schema. Order MUST match validate_case so generator
    // and validator produce identical canonical byte streams.
    if let Some(JsonValue::Array(arr)) = output.get("reduced_batch") {
        encoder.write_u32(arr.len() as u32);
        for item in arr {
            let s = match item {
                JsonValue::String(s) => s,
                _ => panic!("reduced_batch element not a string"),
            };
            let fp = parse_fingerprint(s).expect("malformed batched reduced hex");
            write_fingerprint(&fp, encoder);
        }
        return;
    }

    let s = match output.get("reduced") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing reduced"),
    };
    let fp = parse_fingerprint(s).expect("malformed reduced hex");
    write_fingerprint(&fp, encoder);
}

fn write_fingerprint(fp: &RealFingerprint256, encoder: &mut CanonicalBinaryEncoder) {
    encoder.write_u64(fp.block0);
    encoder.write_u64(fp.block1);
    encoder.write_u64(fp.block2);
    encoder.write_u64(fp.block3);
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

fn fp_eq(a: &RealFingerprint256, b: &RealFingerprint256) -> bool {
    a.block0 == b.block0 && a.block1 == b.block1
        && a.block2 == b.block2 && a.block3 == b.block3
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
