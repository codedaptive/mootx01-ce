// src/primitives/eigenvalue_centrality.rs
//
// Power-iteration eigenvalue centrality (cookbook §7.2) — promotes
// the `eigenvalue_centrality` reference into the conformance
// harness per the "Pending future work" entry in
// primitive-catalog.md.
//
// Mirror of Swift's EigenvalueCentralityPrimitive.swift. Calls the
// real reference at glref-rust-eigenvalue_centrality.rs via the
// substrate-kit crate.
//
// Input schema:
//   n              : u32  (decimal integer)
//   edges          : array of {dst: u32, src: u32, weight: f64}
//   max_iterations : u32  (decimal integer)
//   tolerance      : f64  (16-hex IEEE-754 bit pattern, LE)
//
// Output schema:
//   centrality : array of f64
//
// Binary canonical encoding (alphabetical key order):
//   centrality : u32 LE length + N × 8 bytes f64 LE
//
// Cross-language bit-identity: uses sqrt() which is IEEE-754
// mandated correctly-rounded (unlike exp() in matrix_decay where
// libm agreement had to be verified empirically). The
// accumulation `x_next[j] += w * x[i]` proceeds in the same loop
// order in both languages, so bit-identity is conservative.

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, f64_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_ml::eigenvalue_centrality::EigenvalueCentrality;

pub struct EigenvalueCentralityPrimitive;

impl EigenvalueCentralityPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "eigenvalue_centrality",
            cookbook_section: "§7.2",
            reference_file: "glref-rust-eigenvalue_centrality.rs",
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
            let adjacency = build_adjacency(spec.n, &spec.edges);
            // estate="" + ts=0.0: telemetry off — harness must not emit VizGraph signals.
            let centrality = EigenvalueCentrality::compute(
                &adjacency, spec.max_iterations, spec.tolerance, "", 0.0);

            let edges_arr: Vec<JsonValue> = spec.edges.iter().map(|edge| {
                let mut o: JsonObject = BTreeMap::new();
                o.insert("dst".into(),    JsonValue::Integer(edge.dst as i64));
                o.insert("src".into(),    JsonValue::Integer(edge.src as i64));
                o.insert("weight".into(), JsonValue::String(f64_hex(edge.weight)));
                JsonValue::Object(o)
            }).collect();
            let centrality_arr: Vec<JsonValue> = centrality.iter()
                .map(|v| JsonValue::String(f64_hex(*v))).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("n".into(),              JsonValue::Integer(spec.n as i64));
            inputs.insert("edges".into(),          JsonValue::Array(edges_arr));
            inputs.insert("max_iterations".into(), JsonValue::Integer(spec.max_iterations as i64));
            inputs.insert("tolerance".into(),      JsonValue::String(f64_hex(spec.tolerance)));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("centrality".into(), JsonValue::Array(centrality_arr));

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
            primitive: "eigenvalue_centrality".to_string(),
            cookbook_section: "§7.2".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-eigenvalue_centrality.rs".to_string(),
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

#[derive(Clone, Copy)]
struct Edge { src: usize, dst: usize, weight: f64 }

struct CaseSpec {
    n: usize,
    edges: Vec<Edge>,
    max_iterations: usize,
    tolerance: f64,
    description: String,
}

fn validate_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let n = match c.inputs.get("n") {
        Some(JsonValue::Integer(v)) if *v >= 0 => *v as usize,
        _ => return fail(c, "missing or invalid n"),
    };
    let max_iter = match c.inputs.get("max_iterations") {
        Some(JsonValue::Integer(v)) if *v > 0 => *v as usize,
        _ => return fail(c, "missing or invalid max_iterations"),
    };
    let tolerance = match c.inputs.get("tolerance") {
        Some(JsonValue::String(s)) => match parse_f64_hex(s) {
            Some(f) => f,
            None => return fail(c, "malformed tolerance"),
        },
        _ => return fail(c, "missing tolerance"),
    };
    let edges_arr = match c.inputs.get("edges") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail(c, "missing edges"),
    };
    let mut edges: Vec<Edge> = Vec::with_capacity(edges_arr.len());
    for e in edges_arr {
        let obj = match e {
            JsonValue::Object(o) => o,
            _ => return fail(c, "edge not an object"),
        };
        let src = match obj.get("src") {
            Some(JsonValue::Integer(v)) if *v >= 0 && (*v as usize) < n => *v as usize,
            _ => return fail(c, "missing or invalid edge.src"),
        };
        let dst = match obj.get("dst") {
            Some(JsonValue::Integer(v)) if *v >= 0 && (*v as usize) < n => *v as usize,
            _ => return fail(c, "missing or invalid edge.dst"),
        };
        let weight = match obj.get("weight") {
            Some(JsonValue::String(s)) => match parse_f64_hex(s) {
                Some(f) => f,
                None => return fail(c, "malformed edge.weight"),
            },
            _ => return fail(c, "missing edge.weight"),
        };
        edges.push(Edge { src, dst, weight });
    }

    let adjacency = build_adjacency(n, &edges);
    // estate="" + ts=0.0: telemetry off — harness must not emit VizGraph signals.
    let actual = EigenvalueCentrality::compute(&adjacency, max_iter, tolerance, "", 0.0);

    let expected_arr = match c.expected_output.get("centrality") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail(c, "missing expected centrality"),
    };
    if expected_arr.len() != n {
        return fail(c, "expected centrality length mismatch");
    }
    if actual.len() != n {
        return fail(c, "computed centrality length mismatch");
    }

    encoder.write_u32(actual.len() as u32);
    for v in &actual { encoder.write_f64(*v); }

    for (idx, ev) in expected_arr.iter().enumerate() {
        let s = match ev {
            JsonValue::String(s) => s,
            _ => return fail(c, "non-string expected centrality element"),
        };
        let expected = match parse_f64_hex(s) {
            Some(f) => f,
            None => return fail(c, "malformed expected centrality element"),
        };
        if actual[idx].to_bits() != expected.to_bits() {
            return CaseResult {
                id: c.id.clone(), passed: false,
                diagnostic: Some(format!(
                    "centrality[{}] mismatch: expected {}, got {}",
                    idx, f64_hex(expected), f64_hex(actual[idx]))),
            };
        }
    }
    CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let arr = match output.get("centrality") {
        Some(JsonValue::Array(a)) => a,
        _ => panic!("expected_output missing centrality"),
    };
    encoder.write_u32(arr.len() as u32);
    for v in arr {
        let s = match v {
            JsonValue::String(s) => s,
            _ => panic!("non-string centrality element"),
        };
        let f = parse_f64_hex(s).expect("malformed centrality hex");
        encoder.write_f64(f);
    }
}

fn fail(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult {
        id: c.id.clone(), passed: false,
        diagnostic: Some(msg.to_string()),
    }
}

fn build_adjacency(n: usize, edges: &[Edge]) -> Vec<Vec<(usize, f64)>> {
    let mut adj: Vec<Vec<(usize, f64)>> = vec![Vec::new(); n];
    for e in edges {
        adj[e.src].push((e.dst, e.weight));
    }
    adj
}

fn generate_case_spec(i: usize, rng: &mut SplitMix64) -> CaseSpec {
    match i {
        0 => CaseSpec {
            n: 0, edges: vec![],
            max_iterations: 100, tolerance: 1.0e-6,
            description: "empty graph (n=0)".to_string(),
        },
        1 => CaseSpec {
            n: 1,
            edges: vec![Edge { src: 0, dst: 0, weight: 1.0 }],
            max_iterations: 100, tolerance: 1.0e-6,
            description: "single node, self-loop weight 1.0".to_string(),
        },
        2 => CaseSpec {
            n: 5, edges: vec![],
            max_iterations: 100, tolerance: 1.0e-6,
            description: "isolated graph n=5 (no edges) -> uniform 1/sqrt(n)".to_string(),
        },
        3 => CaseSpec {
            n: 3,
            edges: vec![
                Edge { src: 0, dst: 1, weight: 1.0 },
                Edge { src: 1, dst: 0, weight: 1.0 },
                Edge { src: 1, dst: 2, weight: 1.0 },
                Edge { src: 2, dst: 1, weight: 1.0 },
                Edge { src: 0, dst: 2, weight: 1.0 },
                Edge { src: 2, dst: 0, weight: 1.0 },
            ],
            max_iterations: 200, tolerance: 1.0e-9,
            description: "symmetric triangle (3 nodes, 6 directed edges)".to_string(),
        },
        4..=7 => {
            let n = 3 + 2 * (i - 4);
            let mut edges = Vec::new();
            for leaf in 1..n {
                edges.push(Edge { src: 0, dst: leaf, weight: 1.0 });
                edges.push(Edge { src: leaf, dst: 0, weight: 1.0 });
            }
            CaseSpec {
                n, edges,
                max_iterations: 200, tolerance: 1.0e-9,
                description: format!("symmetric star n={} (hub=0, {} leaves)", n, n - 1),
            }
        }
        _ => {
            let n = 4 + (rng.next() % 26) as usize;        // n in [4, 29]
            let edge_count = std::cmp::max(n, n + (rng.next() % (3 * n as u64)) as usize);
            let mut edges = Vec::with_capacity(edge_count);
            for _ in 0..edge_count {
                let src = (rng.next() % n as u64) as usize;
                let dst = (rng.next() % n as u64) as usize;
                let w = f64_from_u64_pos(rng.next(), 5.0) + 0.1;
                edges.push(Edge { src, dst, weight: w });
            }
            let max_iter = if i % 3 == 0 { 50 } else if i % 3 == 1 { 200 } else { 500 };
            let tol = if i % 4 == 0 { 1.0e-4 } else if i % 4 == 1 { 1.0e-6 } else { 1.0e-9 };
            CaseSpec {
                n, edges,
                max_iterations: max_iter,
                tolerance: tol,
                description: format!(
                    "random sparse n={}, edges={}, maxIter={}, tol={}",
                    n, edge_count, max_iter, tol),
            }
        }
    }
}

fn parse_f64_hex(s: &str) -> Option<f64> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 { return None; }
    let mut bits: u64 = 0;
    for (i, b) in bytes.iter().enumerate() { bits |= (*b as u64) << (i * 8); }
    Some(f64::from_bits(bits))
}

/// Map u64 to positive f64 in [0, scale). Mirror of Swift's
/// f64FromUInt64Pos so RNG-derived weights match across ports.
fn f64_from_u64_pos(raw: u64, scale: f64) -> f64 {
    let normalized = (raw >> 11) as f64 / (1u64 << 53) as f64;
    normalized * scale
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
