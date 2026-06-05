// src/primitives/association_rule_mining.rs
//
// Validation primitive for AssociationRuleMining.
//
// Input schema per case:
//   entries           : array of { field_i, value_i, field_j, value_j: u8-hex,
//                                  count: i64 LE-hex }
//   active_row_count  : i64 LE-hex
//   min_support       : f64 LE-hex
//   min_confidence    : f64 LE-hex
//
// Output schema per case:
//   rules : array of {
//     antecedent_field, antecedent_value,
//     consequent_field, consequent_value : u8-hex
//     support, confidence, lift, leverage, conviction : f64 LE-hex
//     (f64::INFINITY encodes as "0x000000000000f07f")
//   }
//
// Vectors live at:
//   docs/validation/substrate_math_performance/test-harness/vectors/
//   association_rule_mining.json

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::decode_hex,
    vector_file::{JsonObject, JsonValue, VectorCase, VectorFile},
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_ml::association_rule_mining::{
    mine_association_rules, Item, MiningThresholds,
};
use substrate_types::{matrix_o::CooccurrenceKey, MatrixO};

pub struct AssociationRuleMiningPrimitive;

impl AssociationRuleMiningPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "association_rule_mining",
            cookbook_section: "§6.3",
            reference_file: "SubstrateML/Sources/SubstrateML/AssociationRuleMining.swift",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(_seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        // ARM vectors are hand-specified (deterministic, no RNG needed).
        // The canonical cases match AssociationRuleMiningTests.swift exactly.
        Err("association_rule_mining vectors are hand-crafted; re-read association_rule_mining.json from vectors/".into())
    }

    pub fn validate(vf: &VectorFile) -> Result<ValidationResult, Box<dyn std::error::Error>> {
        let mut crc = CRC32::new();
        let mut case_results = Vec::new();

        for case in &vf.cases {
            let result = Self::validate_case(case, &mut crc);
            case_results.push(result);
        }

        let crc_actual = crc.finalize();

        Ok(ValidationResult {
            passed: case_results.iter().all(|r| r.passed),
            case_results,
            crc_expected: vf.output_crc32,
            crc_actual,
        })
    }

    fn validate_case(case: &VectorCase, crc: &mut CRC32) -> CaseResult {
        let inputs = &case.inputs;

        // Parse matrix entries.
        let mut matrix = MatrixO::new();
        if let Some(JsonValue::Array(entries)) = inputs.get("entries") {
            for entry in entries {
                if let JsonValue::Object(e) = entry {
                    let fi = parse_u8(e, "field_i");
                    let vi = parse_u8(e, "value_i");
                    let fj = parse_u8(e, "field_j");
                    let vj = parse_u8(e, "value_j");
                    let count = parse_i64(e, "count");
                    matrix.increment(CooccurrenceKey::new(fi, vi, fj, vj), count);
                }
            }
        }

        let active_row_count = parse_i64(inputs, "active_row_count");
        let min_support = parse_f64(inputs, "min_support");
        let min_confidence = parse_f64(inputs, "min_confidence");

        let thresholds = MiningThresholds::new(min_support, min_confidence);
        let actual_rules = mine_association_rules(&matrix, active_row_count, thresholds);

        // Parse expected rules from the expected_output object.
        let expected_rules = parse_rules(&case.expected_output);

        // Compare.
        let passed = actual_rules.len() == expected_rules.len()
            && actual_rules.iter().zip(expected_rules.iter()).all(|(a, e)| {
                a.antecedent == e.antecedent
                    && a.consequent == e.consequent
                    && bits_eq(a.support, e.support)
                    && bits_eq(a.confidence, e.confidence)
                    && bits_eq(a.lift, e.lift)
                    && bits_eq(a.leverage, e.leverage)
                    && bits_eq(a.conviction, e.conviction)
            });

        // Encode actual output into CRC.
        let mut enc = CanonicalBinaryEncoder::new();
        enc.write_u64(actual_rules.len() as u64);
        for r in &actual_rules {
            enc.write_u8(r.antecedent.field);
            enc.write_u8(r.antecedent.value);
            enc.write_u8(r.consequent.field);
            enc.write_u8(r.consequent.value);
            enc.write_f64(r.support);
            enc.write_f64(r.confidence);
            enc.write_f64(r.lift);
            enc.write_f64(r.leverage);
            enc.write_f64(r.conviction);
        }
        crc.update(&enc.into_bytes());

        let diagnostic = if passed {
            None
        } else {
            Some(format!(
                "expected {} rules, got {}",
                expected_rules.len(),
                actual_rules.len()
            ))
        };

        CaseResult {
            id: case.id.clone(),
            passed,
            diagnostic,
        }
    }
}

// Parsed expected rule shape (mirrors AssociationRule but owns its data).
struct ExpectedRule {
    antecedent: Item,
    consequent: Item,
    support: f64,
    confidence: f64,
    lift: f64,
    leverage: f64,
    conviction: f64,
}

fn parse_rules(output: &JsonObject) -> Vec<ExpectedRule> {
    if let Some(JsonValue::Array(arr)) = output.get("rules") {
        arr.iter()
            .filter_map(|v| {
                if let JsonValue::Object(r) = v {
                    Some(ExpectedRule {
                        antecedent: Item::new(parse_u8(r, "antecedent_field"), parse_u8(r, "antecedent_value")),
                        consequent: Item::new(parse_u8(r, "consequent_field"), parse_u8(r, "consequent_value")),
                        support: parse_f64(r, "support"),
                        confidence: parse_f64(r, "confidence"),
                        lift: parse_f64(r, "lift"),
                        leverage: parse_f64(r, "leverage"),
                        conviction: parse_f64(r, "conviction"),
                    })
                } else {
                    None
                }
            })
            .collect()
    } else {
        Vec::new()
    }
}

fn parse_u8(obj: &JsonObject, key: &str) -> u8 {
    match obj.get(key) {
        Some(JsonValue::String(s)) => {
            let bytes = decode_hex(s).unwrap_or_default();
            *bytes.first().unwrap_or(&0)
        }
        _ => 0,
    }
}

fn parse_i64(obj: &JsonObject, key: &str) -> i64 {
    match obj.get(key) {
        Some(JsonValue::String(s)) => {
            let bytes = decode_hex(s).unwrap_or_default();
            if bytes.len() < 8 {
                return 0;
            }
            let mut arr = [0u8; 8];
            arr.copy_from_slice(&bytes[..8]);
            i64::from_le_bytes(arr)
        }
        _ => 0,
    }
}

fn parse_f64(obj: &JsonObject, key: &str) -> f64 {
    match obj.get(key) {
        Some(JsonValue::String(s)) => {
            let bytes = decode_hex(s).unwrap_or_default();
            if bytes.len() < 8 {
                return 0.0;
            }
            let mut arr = [0u8; 8];
            arr.copy_from_slice(&bytes[..8]);
            f64::from_bits(u64::from_le_bytes(arr))
        }
        _ => 0.0,
    }
}

/// Bit-identical float comparison (handles NaN and ±∞ correctly).
fn bits_eq(a: f64, b: f64) -> bool {
    a.to_bits() == b.to_bits()
}
