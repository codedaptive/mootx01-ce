// src/primitives/simhash.rs
//
// Mirror of the Swift harness's SimHashPrimitive.swift.
//
// Input schema (pair-at-a-time cases, 32 of them):
//   block_index        : u8 in 0..4
//   hyperplane_seed    : u64
//   hyperplane_density : f64 (canonical bit pattern)
//   input_bit_length   : u32 (192 if block_index==0, 64 otherwise)
//   input_vector_words : [u64]
//
// Output schema (pair):
//   block_value : u64
//
// Input schema (batched cases, 8 of them, one per batch_size in
//   {0, 1, 2, 4, 8, 16, 32, 64}). Batched cases test the
//   `simhash_block_batch` trait method: one family applied to
//   many input vectors. All inputs in a batched case share the
//   same family (block_index, hyperplane_seed, density,
//   input_bit_length); only the input_vector_words varies.
//
//   block_index              : u8
//   hyperplane_seed          : u64
//   hyperplane_density       : f64
//   input_bit_length         : u32
//   input_vector_words_batch : [[u64]]   (length = batch_size)
//
// Output schema (batched):
//   block_values : [u64]                 (length = batch_size)
//
// Per the kernel-learned-dispatch decision
//, batched output
// MUST equal sequential output byte-for-byte in at-rest
// little-endian canonical form. The conformance gate enforces
// this.

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, f64_hex, u64_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};


pub struct SimHashPrimitive;

impl SimHashPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "simhash",
            cookbook_section: "§3.6",
            reference_file: "glref-rust-simhash.rs",
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
            let block_index = (i % 4) as u8;
            let input_bit_length: u32 = if block_index == 0 { 192 } else { 64 };
            let input_word_count = ((input_bit_length + 63) / 64) as usize;
            let mut input_words = Vec::with_capacity(input_word_count);
            for _ in 0..input_word_count {
                input_words.push(rng.next());
            }
            let hyperplane_seed = rng.next();
            let density: f64 = 1.0;

            let block_value = reference_simhash(
                &input_words,
                hyperplane_seed,
                block_index,
                input_bit_length as usize,
                density,
            );

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("block_index".into(), JsonValue::Integer(block_index as i64));
            inputs.insert(
                "hyperplane_density".into(),
                JsonValue::String(f64_hex(density)),
            );
            inputs.insert(
                "hyperplane_seed".into(),
                JsonValue::String(u64_hex(hyperplane_seed)),
            );
            inputs.insert(
                "input_bit_length".into(),
                JsonValue::Integer(input_bit_length as i64),
            );
            let words_arr: Vec<JsonValue> = input_words
                .iter()
                .map(|w| JsonValue::String(u64_hex(*w)))
                .collect();
            inputs.insert("input_vector_words".into(), JsonValue::Array(words_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("block_value".into(), JsonValue::String(u64_hex(block_value)));

            let description = format!(
                "block {}, input bit length {}, density {}",
                block_index, input_bit_length, density
            );
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
        // Each batched case fixes one family (block_index,
        // hyperplane_seed, density, input_bit_length) and feeds N
        // input vectors of identical word_count through
        // simhash_block_batch. Output is [u64] of block values.
        let kernel = crate::harness::kernel_selector::current();
        for (k, &batch_size) in batched_sizes.iter().enumerate() {
            let block_index: u8 = (k % 4) as u8;
            let input_bit_length: u32 = if block_index == 0 { 192 } else { 64 };
            let input_word_count = ((input_bit_length + 63) / 64) as usize;
            let hyperplane_seed = rng.next();
            let density: f64 = 1.0;

            let mut input_batch: Vec<Vec<u64>> = Vec::with_capacity(batch_size);
            for _ in 0..batch_size {
                let mut words = Vec::with_capacity(input_word_count);
                for _ in 0..input_word_count {
                    words.push(rng.next());
                }
                input_batch.push(words);
            }

            // Build the family once, dispatch via the trait's
            // batched method. The default impl loops over
            // simhash_block; backends may override.
            let seed_bytes = expand_seed_to_32(hyperplane_seed);
            let family = RealHyperplaneFamily::generate(
                &seed_bytes,
                block_index as usize,
                input_bit_length as usize,
                density,
            );

            let input_slices: Vec<&[u64]> = input_batch.iter().map(|v| v.as_slice()).collect();
            let mut block_values = vec![0u64; batch_size];
            kernel.simhash_block_batch(&input_slices, &family, &mut block_values);

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("block_index".into(), JsonValue::Integer(block_index as i64));
            inputs.insert(
                "hyperplane_density".into(),
                JsonValue::String(f64_hex(density)),
            );
            inputs.insert(
                "hyperplane_seed".into(),
                JsonValue::String(u64_hex(hyperplane_seed)),
            );
            inputs.insert(
                "input_bit_length".into(),
                JsonValue::Integer(input_bit_length as i64),
            );
            let batch_arr: Vec<JsonValue> = input_batch
                .iter()
                .map(|words| JsonValue::Array(
                    words.iter()
                        .map(|w| JsonValue::String(u64_hex(*w)))
                        .collect(),
                ))
                .collect();
            inputs.insert("input_vector_words_batch".into(), JsonValue::Array(batch_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert(
                "block_values".into(),
                JsonValue::Array(
                    block_values.iter()
                        .map(|v| JsonValue::String(u64_hex(*v)))
                        .collect(),
                ),
            );

            let description = format!(
                "batched, block {}, batch_size {}, input bit length {}",
                block_index, batch_size, input_bit_length
            );
            let id = format!("case_{:03}", pair_count + k);
            cases.push(VectorCase {
                id,
                description,
                inputs,
                expected_output: output,
            });
        }

        // CRC over canonical binary serialization of outputs.
        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases {
            encode_output(&c.expected_output, &mut encoder);
        }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "simhash".to_string(),
            cookbook_section: "§3.6".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-simhash.rs".to_string(),
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
            let result = validate_case(c, &mut encoder);
            case_results.push(result);
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
    // Batched cases have a `block_values` array in expected_output.
    // Pair-at-a-time cases have a single `block_value` scalar.
    if c.expected_output.contains_key("block_values") {
        return validate_batched_case(c, encoder);
    }
    validate_pair_case(c, encoder)
}

fn validate_pair_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let block_index = match c.inputs.get("block_index") {
        Some(JsonValue::Integer(i)) => *i as u8,
        _ => {
            return CaseResult {
                id: c.id.clone(),
                passed: false,
                diagnostic: Some("missing block_index".into()),
            }
        }
    };
    let density = match c.inputs.get("hyperplane_density") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 8 => {
                let mut bits = 0u64;
                for (i, byte) in b.iter().enumerate() {
                    bits |= (*byte as u64) << (i * 8);
                }
                f64::from_bits(bits)
            }
            _ => {
                return CaseResult {
                    id: c.id.clone(),
                    passed: false,
                    diagnostic: Some("malformed hyperplane_density".into()),
                }
            }
        },
        _ => {
            return CaseResult {
                id: c.id.clone(),
                passed: false,
                diagnostic: Some("missing hyperplane_density".into()),
            }
        }
    };
    let hyperplane_seed = match c.inputs.get("hyperplane_seed") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 8 => {
                let mut v = 0u64;
                for (i, byte) in b.iter().enumerate() {
                    v |= (*byte as u64) << (i * 8);
                }
                v
            }
            _ => {
                return CaseResult {
                    id: c.id.clone(),
                    passed: false,
                    diagnostic: Some("malformed hyperplane_seed".into()),
                }
            }
        },
        _ => {
            return CaseResult {
                id: c.id.clone(),
                passed: false,
                diagnostic: Some("missing hyperplane_seed".into()),
            }
        }
    };
    let input_bit_length = match c.inputs.get("input_bit_length") {
        Some(JsonValue::Integer(i)) => *i as usize,
        _ => {
            return CaseResult {
                id: c.id.clone(),
                passed: false,
                diagnostic: Some("missing input_bit_length".into()),
            }
        }
    };
    let input_words = match c.inputs.get("input_vector_words") {
        Some(JsonValue::Array(arr)) => {
            let mut out = Vec::with_capacity(arr.len());
            for v in arr {
                if let JsonValue::String(s) = v {
                    match decode_hex(s) {
                        Ok(b) if b.len() == 8 => {
                            let mut w = 0u64;
                            for (i, byte) in b.iter().enumerate() {
                                w |= (*byte as u64) << (i * 8);
                            }
                            out.push(w);
                        }
                        _ => {
                            return CaseResult {
                                id: c.id.clone(),
                                passed: false,
                                diagnostic: Some(
                                    "malformed input_vector_words element".into(),
                                ),
                            }
                        }
                    }
                } else {
                    return CaseResult {
                        id: c.id.clone(),
                        passed: false,
                        diagnostic: Some(
                            "input_vector_words element is not a string".into(),
                        ),
                    };
                }
            }
            out
        }
        _ => {
            return CaseResult {
                id: c.id.clone(),
                passed: false,
                diagnostic: Some("missing input_vector_words".into()),
            }
        }
    };

    let actual = reference_simhash(
        &input_words,
        hyperplane_seed,
        block_index,
        input_bit_length,
        density,
    );

    let expected = match c.expected_output.get("block_value") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 8 => {
                let mut v = 0u64;
                for (i, byte) in b.iter().enumerate() {
                    v |= (*byte as u64) << (i * 8);
                }
                v
            }
            _ => {
                return CaseResult {
                    id: c.id.clone(),
                    passed: false,
                    diagnostic: Some("malformed expected block_value".into()),
                }
            }
        },
        _ => {
            return CaseResult {
                id: c.id.clone(),
                passed: false,
                diagnostic: Some("missing expected block_value".into()),
            }
        }
    };

    encoder.write_u64(actual);

    if actual == expected {
        CaseResult {
            id: c.id.clone(),
            passed: true,
            diagnostic: None,
        }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "block_value mismatch: expected {}, got {}",
                u64_hex(expected),
                u64_hex(actual)
            )),
        }
    }
}

fn validate_batched_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    // Family fields (same shape as pair case).
    let block_index = match c.inputs.get("block_index") {
        Some(JsonValue::Integer(i)) => *i as u8,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing block_index".into()) },
    };
    let density = match c.inputs.get("hyperplane_density") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 8 => {
                let mut bits = 0u64;
                for (i, byte) in b.iter().enumerate() { bits |= (*byte as u64) << (i * 8); }
                f64::from_bits(bits)
            }
            _ => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed hyperplane_density".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing hyperplane_density".into()) },
    };
    let hyperplane_seed = match c.inputs.get("hyperplane_seed") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 8 => {
                let mut v = 0u64;
                for (i, byte) in b.iter().enumerate() { v |= (*byte as u64) << (i * 8); }
                v
            }
            _ => return CaseResult { id: c.id.clone(), passed: false,
                diagnostic: Some("malformed hyperplane_seed".into()) },
        },
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing hyperplane_seed".into()) },
    };
    let input_bit_length = match c.inputs.get("input_bit_length") {
        Some(JsonValue::Integer(i)) => *i as usize,
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing input_bit_length".into()) },
    };

    // Parse the input batch.
    let input_batch: Vec<Vec<u64>> = match c.inputs.get("input_vector_words_batch") {
        Some(JsonValue::Array(arr)) => {
            let mut out = Vec::with_capacity(arr.len());
            for words_val in arr {
                let words = match words_val {
                    JsonValue::Array(warr) => {
                        let mut ws = Vec::with_capacity(warr.len());
                        for v in warr {
                            if let JsonValue::String(s) = v {
                                match decode_hex(s) {
                                    Ok(b) if b.len() == 8 => {
                                        let mut w = 0u64;
                                        for (i, byte) in b.iter().enumerate() {
                                            w |= (*byte as u64) << (i * 8);
                                        }
                                        ws.push(w);
                                    }
                                    _ => return CaseResult { id: c.id.clone(), passed: false,
                                        diagnostic: Some("malformed batched input word".into()) },
                                }
                            } else {
                                return CaseResult { id: c.id.clone(), passed: false,
                                    diagnostic: Some("batched input word not a string".into()) };
                            }
                        }
                        ws
                    }
                    _ => return CaseResult { id: c.id.clone(), passed: false,
                        diagnostic: Some("batched input element not an array".into()) },
                };
                out.push(words);
            }
            out
        }
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing input_vector_words_batch".into()) },
    };

    let expected: Vec<u64> = match c.expected_output.get("block_values") {
        Some(JsonValue::Array(arr)) => {
            let mut out = Vec::with_capacity(arr.len());
            for v in arr {
                if let JsonValue::String(s) = v {
                    match decode_hex(s) {
                        Ok(b) if b.len() == 8 => {
                            let mut w = 0u64;
                            for (i, byte) in b.iter().enumerate() { w |= (*byte as u64) << (i * 8); }
                            out.push(w);
                        }
                        _ => return CaseResult { id: c.id.clone(), passed: false,
                            diagnostic: Some("malformed expected block_value".into()) },
                    }
                } else {
                    return CaseResult { id: c.id.clone(), passed: false,
                        diagnostic: Some("expected block_value not a string".into()) };
                }
            }
            out
        }
        _ => return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some("missing expected block_values".into()) },
    };

    if input_batch.len() != expected.len() {
        return CaseResult { id: c.id.clone(), passed: false,
            diagnostic: Some(format!(
                "length mismatch: {} inputs vs {} expected",
                input_batch.len(), expected.len())) };
    }

    // Build family once, dispatch through trait's batched method.
    let seed_bytes = expand_seed_to_32(hyperplane_seed);
    let family = RealHyperplaneFamily::generate(
        &seed_bytes, block_index as usize, input_bit_length, density);
    let kernel = crate::harness::kernel_selector::current();
    let input_slices: Vec<&[u64]> = input_batch.iter().map(|v| v.as_slice()).collect();
    let mut actual = vec![0u64; input_batch.len()];
    kernel.simhash_block_batch(&input_slices, &family, &mut actual);

    // Canonical binary encoding: u32 LE length prefix + N u64 LE values.
    encoder.write_u32(actual.len() as u32);
    for v in &actual { encoder.write_u64(*v); }

    if actual == expected {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        let first_diff = actual.iter().zip(expected.iter())
            .position(|(a, b)| a != b).unwrap_or(0);
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some(format!(
                "batched block_value mismatch at index {}: expected {}, got {}",
                first_diff,
                u64_hex(expected[first_diff]),
                u64_hex(actual[first_diff]))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    // Dispatch on schema. Order MUST match validate_case so generator
    // and validator produce identical canonical byte streams.
    if let Some(JsonValue::Array(arr)) = output.get("block_values") {
        encoder.write_u32(arr.len() as u32);
        for item in arr {
            let s = match item {
                JsonValue::String(s) => s,
                _ => panic!("block_values element not a string"),
            };
            let bytes = decode_hex(s).expect("malformed batched block_value hex");
            assert_eq!(bytes.len(), 8, "batched block_value must be 8 bytes");
            let mut v: u64 = 0;
            for (i, b) in bytes.iter().enumerate() { v |= (*b as u64) << (i * 8); }
            encoder.write_u64(v);
        }
        return;
    }

    let s = match output.get("block_value") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing block_value"),
    };
    let bytes = decode_hex(s).expect("malformed block_value hex");
    assert_eq!(bytes.len(), 8, "block_value must be 8 bytes");
    let mut v: u64 = 0;
    for (i, b) in bytes.iter().enumerate() {
        v |= (*b as u64) << (i * 8);
    }
    encoder.write_u64(v);
}

// ============================================================
// Reference — calls into the real `geniuslocus-reference` crate
// ============================================================
//
// Path 2 wire-up. The previous stub (deterministic XOR mix) is
// retained below the live function as documentation but is no
// longer invoked. CRCs in vectors/simhash.json must be
// regenerated after this wire-up: the stub-derived baseline
// (0xcafd725b) is replaced by the real-reference-derived value.
//
// The real impl takes a `HyperplaneFamily` not a bare seed. The
// harness still parameterizes cases by `hyperplane_seed`; we
// expand that u64 to a 32-byte seed via SplitMix-style avalanche
// (matching the Swift mirror) before constructing the family.

use substrate_types::hyperplane::HyperplaneFamily as RealHyperplaneFamily;
use substrate_types::simhash as real_simhash;

fn reference_simhash(
    input_words: &[u64],
    hyperplane_seed: u64,
    block_index: u8,
    input_bit_length: usize,
    density: f64,
) -> u64 {
    let seed_bytes = expand_seed_to_32(hyperplane_seed);
    let family = RealHyperplaneFamily::generate(
        &seed_bytes,
        block_index as usize,
        input_bit_length,
        density,
    );
    real_simhash::block(input_words, &family)
}

/// Expand a 64-bit seed to 32 bytes via 4 rounds of SplitMix64-
/// style avalanche. Same construction as the reference crate's
/// `expand_seed_to_32` (pairing.rs) and the Swift mirror's
/// `expandSeedTo32` (PairingHandshake.swift); kept locally here
/// so the harness does not depend on a private helper.
fn expand_seed_to_32(seed: u64) -> [u8; 32] {
    let mut out = [0u8; 32];
    let mut s = seed;
    for i in 0..4 {
        s = s.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = s;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^= z >> 31;
        out[i * 8..(i + 1) * 8].copy_from_slice(&z.to_le_bytes());
    }
    out
}

// ============================================================
// Historical reference stub (Path 1, kept for documentation)
// ============================================================
//
// The stub below was used to validate the harness conformance
// machinery before the real references compiled. It produced
// CRC 0xcafd725b for seed 0xCAFEBABEDEADBEEF. Replaced above by
// the real-reference call.
//
//   let mix_seed = hyperplane_seed ^ (block_index as u64) ^ (input_bit_length as u64);
//   let mut rng = SplitMix64::new(mix_seed);
//   let mut result: u64 = 0;
//   for word in input_words { result ^= word.wrapping_mul(rng.next()); }
//   return result;


// ============================================================
// Helpers
// ============================================================

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
