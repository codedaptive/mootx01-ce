// src/primitives/field_presence_matrix_f.rs
//
// Field-presence matrix F (cookbook §6.1) — promotes the
// `field_presence_matrix_f` reference into the conformance
// harness per the "Pending future work" entry in
// primitive-catalog.md.
//
// Mirror of Swift's FieldPresenceMatrixFPrimitive.swift. Calls
// the real reference at glref-rust-matrix_f.rs via the
// substrate-kit crate.
//
// Input schema:
//   initial_cells : array of i64 (length 216) — initial F state
//   operations    : array of {bit_presence: 54-hex (27 bytes), delta: i64}
//
// Output schema:
//   final_cells : array of i64 (length 216) — F after all ops
//
// Binary canonical encoding (alphabetical key order, single field):
//   final_cells : u32 LE length (216) + 216 × 8 bytes i64 LE
//
// Cross-language bit-identity: integer-only. apply_row uses
// wrapping_add (Rust) / &+= (Swift), which have identical
// two's-complement semantics. No floats. No transcendentals.

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, encode_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::matrix_f::MatrixF;

const BIT_PRESENCE_BYTES: usize = 27; // 216 bits / 8

pub struct FieldPresenceMatrixFPrimitive;

impl FieldPresenceMatrixFPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "field_presence_matrix_f",
            cookbook_section: "§6.1",
            reference_file: "glref-rust-matrix_f.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let spec = generate_case_spec(i, &mut rng);
            let final_cells = apply_ops(&spec.initial_cells, &spec.operations);

            let initial_arr: Vec<JsonValue> = spec.initial_cells.iter()
                .map(|v| JsonValue::Integer(*v)).collect();
            let ops_arr: Vec<JsonValue> = spec.operations.iter().map(|op| {
                let mut o: JsonObject = BTreeMap::new();
                o.insert("bit_presence".into(),
                         JsonValue::String(encode_hex(&op.bit_presence)));
                o.insert("delta".into(),
                         JsonValue::Integer(op.delta));
                JsonValue::Object(o)
            }).collect();
            let final_arr: Vec<JsonValue> = final_cells.iter()
                .map(|v| JsonValue::Integer(*v)).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("initial_cells".into(), JsonValue::Array(initial_arr));
            inputs.insert("operations".into(),    JsonValue::Array(ops_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("final_cells".into(), JsonValue::Array(final_arr));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: spec.description,
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "field_presence_matrix_f".to_string(),
            cookbook_section: "§6.1".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-matrix_f.rs".to_string(),
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

#[derive(Clone)]
struct Operation {
    delta: i64,
    bit_presence: Vec<u8>,
}

struct CaseSpec {
    initial_cells: Vec<i64>,
    operations: Vec<Operation>,
    description: String,
}

fn validate_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let init_arr = match c.inputs.get("initial_cells") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail(c, "missing initial_cells"),
    };
    if init_arr.len() != MatrixF::CELL_COUNT {
        return fail(c, &format!(
            "initial_cells length {} != {}", init_arr.len(), MatrixF::CELL_COUNT));
    }
    let mut initial_cells: Vec<i64> = Vec::with_capacity(MatrixF::CELL_COUNT);
    for (idx, v) in init_arr.iter().enumerate() {
        match v {
            JsonValue::Integer(n) => initial_cells.push(*n),
            _ => return fail(c, &format!("initial_cells[{}] not an integer", idx)),
        }
    }

    let ops_arr = match c.inputs.get("operations") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail(c, "missing operations"),
    };
    let mut ops: Vec<Operation> = Vec::with_capacity(ops_arr.len());
    for (idx, ov) in ops_arr.iter().enumerate() {
        let od = match ov {
            JsonValue::Object(o) => o,
            _ => return fail(c, &format!("operations[{}] not a dict", idx)),
        };
        let delta = match od.get("delta") {
            Some(JsonValue::Integer(n)) => *n,
            _ => return fail(c, &format!("operations[{}] missing delta", idx)),
        };
        let bp = match od.get("bit_presence") {
            Some(JsonValue::String(s)) => match decode_hex(s) {
                Ok(b) if b.len() == BIT_PRESENCE_BYTES => b,
                _ => return fail(c, &format!("operations[{}] malformed bit_presence", idx)),
            },
            _ => return fail(c, &format!("operations[{}] missing bit_presence", idx)),
        };
        ops.push(Operation { delta, bit_presence: bp });
    }

    let actual = apply_ops(&initial_cells, &ops);

    let expected_arr = match c.expected_output.get("final_cells") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail(c, "missing expected final_cells"),
    };
    if expected_arr.len() != MatrixF::CELL_COUNT {
        return fail(c, "expected final_cells length mismatch");
    }

    encoder.write_u32(actual.len() as u32);
    for v in &actual { encoder.write_i64(*v); }

    for (idx, ev) in expected_arr.iter().enumerate() {
        let expected = match ev {
            JsonValue::Integer(n) => *n,
            _ => return fail(c, &format!("expected final_cells[{}] not int", idx)),
        };
        if actual[idx] != expected {
            return CaseResult {
                id: c.id.clone(), passed: false,
                diagnostic: Some(format!(
                    "final_cells[{}] mismatch: expected {}, got {}",
                    idx, expected, actual[idx])),
            };
        }
    }
    CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let arr = match output.get("final_cells") {
        Some(JsonValue::Array(a)) => a,
        _ => panic!("expected_output missing final_cells"),
    };
    encoder.write_u32(arr.len() as u32);
    for v in arr {
        match v {
            JsonValue::Integer(n) => encoder.write_i64(*n),
            _ => panic!("non-integer final_cells element"),
        }
    }
}

fn fail(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.to_string()) }
}

fn apply_ops(initial: &[i64], ops: &[Operation]) -> Vec<i64> {
    let mut matrix = MatrixF::from_cells(initial.to_vec());
    for op in ops {
        let bp = op.bit_presence.clone();
        matrix.apply_row(op.delta, |field, bit| {
            let pos = field * MatrixF::BITS_PER_FIELD + bit;
            let byte_idx = pos / 8;
            let bit_idx = pos % 8;
            (bp[byte_idx] >> bit_idx) & 1 == 1
        });
    }
    matrix.cells().to_vec()
}

fn generate_case_spec(i: usize, rng: &mut SplitMix64) -> CaseSpec {
    match i {
        0 => CaseSpec {
            initial_cells: vec![0i64; MatrixF::CELL_COUNT],
            operations: vec![],
            description: "empty (no ops on zero matrix)".to_string(),
        },
        1 => CaseSpec {
            initial_cells: vec![0i64; MatrixF::CELL_COUNT],
            operations: vec![Operation { delta: 1, bit_presence: all_bits_set() }],
            description: "+1 with all 216 bits set".to_string(),
        },
        2 => CaseSpec {
            initial_cells: vec![0i64; MatrixF::CELL_COUNT],
            operations: vec![Operation { delta: 1, bit_presence: all_bits_clear() }],
            description: "+1 with no bits set (no-op)".to_string(),
        },
        3 => {
            let pattern = random_bit_pattern(rng);
            CaseSpec {
                initial_cells: vec![0i64; MatrixF::CELL_COUNT],
                operations: vec![
                    Operation { delta: 1, bit_presence: pattern.clone() },
                    Operation { delta: -1, bit_presence: pattern },
                ],
                description: "+1 then -1 inverse pair".to_string(),
            }
        }
        4..=7 => {
            let mut initial = vec![0i64; MatrixF::CELL_COUNT];
            for k in 0..MatrixF::CELL_COUNT {
                initial[k] = rng.next() as i64;
            }
            let pattern = random_bit_pattern(rng);
            let delta = [1i64, -1, 100, -100][i - 4];
            CaseSpec {
                initial_cells: initial,
                operations: vec![Operation { delta, bit_presence: pattern }],
                description: format!("seeded initial, single op delta={}", delta),
            }
        }
        8..=15 => {
            let mut initial = vec![0i64; MatrixF::CELL_COUNT];
            for k in 0..MatrixF::CELL_COUNT {
                initial[k] = (rng.next() & 0xFFFF_FFFF) as i64;
            }
            let pattern1 = random_bit_pattern(rng);
            let pattern2 = random_bit_pattern(rng);
            CaseSpec {
                initial_cells: initial,
                operations: vec![
                    Operation { delta: 5,  bit_presence: pattern1.clone() },
                    Operation { delta: -3, bit_presence: pattern2 },
                    Operation { delta: 1,  bit_presence: pattern1 },
                ],
                description: format!("seeded initial, three mixed ops (case {})", i),
            }
        }
        _ => {
            let mut initial = vec![0i64; MatrixF::CELL_COUNT];
            for k in 0..MatrixF::CELL_COUNT {
                initial[k] = (rng.next() & 0xFFFF) as i64;
            }
            let op_count = 1 + (rng.next() % 12) as usize;
            let mut ops = Vec::with_capacity(op_count);
            for _ in 0..op_count {
                let d_raw = (rng.next() & 0xFFFF_FFFF) as u32 as i32;
                let delta = (d_raw % 200) as i64;
                let pattern = random_bit_pattern(rng);
                ops.push(Operation { delta, bit_presence: pattern });
            }
            CaseSpec {
                initial_cells: initial,
                operations: ops,
                description: format!("random sequence of {} ops", op_count),
            }
        }
    }
}

fn all_bits_set() -> Vec<u8> {
    vec![0xFFu8; BIT_PRESENCE_BYTES]
}

fn all_bits_clear() -> Vec<u8> {
    vec![0u8; BIT_PRESENCE_BYTES]
}

fn random_bit_pattern(rng: &mut SplitMix64) -> Vec<u8> {
    let mut out = vec![0u8; BIT_PRESENCE_BYTES];
    let mut i = 0;
    while i < BIT_PRESENCE_BYTES {
        let word = rng.next();
        for k in 0..8 {
            if i + k >= BIT_PRESENCE_BYTES { break; }
            out[i + k] = ((word >> (k * 8)) & 0xFF) as u8;
        }
        i += 8;
    }
    out
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
