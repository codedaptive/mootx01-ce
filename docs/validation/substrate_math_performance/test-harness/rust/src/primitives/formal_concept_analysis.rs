// src/primitives/formal_concept_analysis.rs
//
// Validation primitive for FormalConceptAnalysis.
//
// Input schema per case:
//   rows            : array of arrays of attribute objects
//                     { namespace: string, key: string, value: string }
//   min_support     : integer
//   max_intent_size : integer
//   max_concepts    : integer
//
// Output schema per case:
//   concepts : array of {
//     extent  : [u32]   — sorted row indices ascending
//     intent  : [{ namespace, key, value }]   — sorted attributes ascending
//     support : integer
//   }
//   (stability is always None in v1 and is not encoded)
//
// Canonical binary encoding per output:
//   u64 concept_count
//   per concept:
//     u64 extent_len; per row: u32 row_id
//     u64 intent_len; per attr: write_string(namespace) write_string(key) write_string(value)
//     u64 support
//     u8  stability_tag = 0 (None, always in v1)
//
// Vectors live at:
//   docs/validation/substrate_math_performance/test-harness/vectors/
//   formal_concept_analysis.json

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    vector_file::{JsonObject, JsonValue, VectorCase, VectorFile},
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_ml::formal_concept_analysis::{
    BoundedConceptMiner, FormalAttribute, FormalContext,
};

pub struct FormalConceptAnalysisPrimitive;

impl FormalConceptAnalysisPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "formal_concept_analysis",
            cookbook_section: "§8 (pure engine)",
            reference_file: "SubstrateML/Sources/SubstrateML/FormalConceptAnalysis.swift",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(_seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        // FCA vectors are hand-specified (deterministic, no RNG needed).
        // The canonical cases match FormalConceptAnalysisTests.swift exactly.
        Err("formal_concept_analysis vectors are hand-crafted; re-read formal_concept_analysis.json from vectors/".into())
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
            // CRC gate: case-level checks verify numeric correctness; the CRC
            // gates the output encoding. A CRC mismatch means the serialised
            // output drifted from the canonical form even if all per-case
            // values are correct — catching encoding bugs that per-case
            // comparisons can miss. All other validators use this pattern.
            passed: case_results.iter().all(|r| r.passed) && crc_actual == vf.output_crc32,
            case_results,
            crc_expected: vf.output_crc32,
            crc_actual,
        })
    }

    fn validate_case(case: &VectorCase, crc: &mut CRC32) -> CaseResult {
        let inputs = &case.inputs;

        // Parse rows: array of arrays of attribute objects.
        let rows = parse_rows(inputs);

        let min_support = parse_usize(inputs, "min_support");
        let max_intent_size = parse_usize(inputs, "max_intent_size");
        let max_concepts = parse_usize(inputs, "max_concepts");

        let context = FormalContext::new(&rows);
        let miner = BoundedConceptMiner::new(min_support, max_intent_size, max_concepts);
        let actual_concepts = miner.mine(&context);

        // Parse expected concepts from the expected_output object.
        let expected_concepts = parse_expected_concepts(&case.expected_output);

        // Compare.
        let passed = actual_concepts.len() == expected_concepts.len()
            && actual_concepts.iter().zip(expected_concepts.iter()).all(|(a, e)| {
                a.extent == e.extent
                    && a.intent == e.intent
                    && a.support == e.support
            });

        // Encode actual output into CRC.
        let mut enc = CanonicalBinaryEncoder::new();
        enc.write_u64(actual_concepts.len() as u64);
        for c in &actual_concepts {
            enc.write_u64(c.extent.len() as u64);
            for &row in &c.extent {
                enc.write_u32(row);
            }
            enc.write_u64(c.intent.len() as u64);
            for attr in &c.intent {
                enc.write_string(&attr.namespace);
                enc.write_string(&attr.key);
                enc.write_string(&attr.value);
            }
            enc.write_u64(c.support as u64);
            // stability is always None in v1
            enc.write_u8(0);
        }
        crc.update(&enc.into_bytes());

        let diagnostic = if passed {
            None
        } else {
            Some(format!(
                "expected {} concepts, got {}",
                expected_concepts.len(),
                actual_concepts.len()
            ))
        };

        CaseResult {
            id: case.id.clone(),
            passed,
            diagnostic,
        }
    }
}

// -- Parsed expected concept shape (mirrors FormalConcept but owned).
struct ExpectedConcept {
    extent: Vec<u32>,
    intent: Vec<FormalAttribute>,
    support: usize,
}

fn parse_rows(inputs: &JsonObject) -> Vec<Vec<FormalAttribute>> {
    let Some(JsonValue::Array(rows)) = inputs.get("rows") else {
        return Vec::new();
    };
    rows.iter()
        .map(|row| {
            if let JsonValue::Array(attrs) = row {
                attrs.iter().filter_map(parse_attr).collect()
            } else {
                Vec::new()
            }
        })
        .collect()
}

fn parse_attr(val: &JsonValue) -> Option<FormalAttribute> {
    if let JsonValue::Object(obj) = val {
        let namespace = get_str(obj, "namespace")?;
        let key = get_str(obj, "key")?;
        let value = get_str(obj, "value")?;
        Some(FormalAttribute {
            namespace: namespace.to_string(),
            key: key.to_string(),
            value: value.to_string(),
        })
    } else {
        None
    }
}

fn parse_expected_concepts(output: &JsonObject) -> Vec<ExpectedConcept> {
    let Some(JsonValue::Array(concepts)) = output.get("concepts") else {
        return Vec::new();
    };
    concepts
        .iter()
        .filter_map(|c| {
            if let JsonValue::Object(obj) = c {
                let extent = parse_u32_array(obj, "extent");
                let intent = parse_intent_array(obj);
                let support = parse_usize(obj, "support");
                Some(ExpectedConcept { extent, intent, support })
            } else {
                None
            }
        })
        .collect()
}

fn parse_u32_array(obj: &JsonObject, key: &str) -> Vec<u32> {
    let Some(JsonValue::Array(arr)) = obj.get(key) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|v| {
            if let JsonValue::Integer(n) = v {
                Some(*n as u32)
            } else {
                None
            }
        })
        .collect()
}

fn parse_intent_array(obj: &JsonObject) -> Vec<FormalAttribute> {
    let Some(JsonValue::Array(arr)) = obj.get("intent") else {
        return Vec::new();
    };
    arr.iter().filter_map(parse_attr).collect()
}

fn parse_usize(obj: &JsonObject, key: &str) -> usize {
    match obj.get(key) {
        Some(JsonValue::Integer(n)) => *n as usize,
        _ => 0,
    }
}

fn get_str<'a>(obj: &'a JsonObject, key: &str) -> Option<&'a str> {
    if let Some(JsonValue::String(s)) = obj.get(key) {
        Some(s.as_str())
    } else {
        None
    }
}
