// src/primitives/qid_adjacency.rs
//
// Mirror of the Swift QIDAdjacencyPrimitive.swift. Q-ID adjacency
// (Wikidata graph) distance — the Q-ID half of cookbook §8.3 lattice
// distance, ruled a canonical primitive 2026-08-20 (S8 wave: live on
// the precise/temporal doors through NeuronKit's QIDClosure-backed
// provider). Calls the production reference at
// substrate_ml::lattice_distance (WikidataGraphDistance).
//
// Each case carries its OWN adjacency graph in the inputs, so the
// vectors gate the §8.3 math — depth-4 BFS, 1 - exp(-len/3)
// normalization, null-Q-ID and unreachable -> 1.0 — independent of
// the vendored QIDClosure artifact. (The pinned artifact is
// provenance-stamped and golden-pinned in LatticeLib; the production
// glue mapping "Q<n>" strings to these integer Q-IDs is NeuronKit's
// QIDClosureAdjacency.)
//
// Input schema (34 cases):
//   a     : u64 hex (integer Q-ID; 0 = null Q-ID)
//   b     : u64 hex
//   edges : { "<u64 hex>": [<u64 hex>, ...] } — undirected adjacency
//           (both directions present, matching the production
//           closure's parent+child neighbor set); values sorted
//           numerically, keys lex-sorted.
//
// Output schema:
//   path_len : u32 hex — BFS shortest path length; 0xffffffff is the
//              NO-PATH sentinel (unreachable within depth 4, or
//              either Q-ID null)
//   distance : f64 hex (WikidataGraphDistance::distance, [0, 1])

use std::collections::{BTreeMap, HashMap, HashSet};

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, f64_hex, u32_hex, u64_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_ml::lattice_distance::{WikidataAdjacencyProvider, WikidataGraphDistance};

/// The no-path sentinel for `path_len`.
const NO_PATH_SENTINEL: u32 = 0xFFFF_FFFF;

/// Case-local adjacency provider over the case's `edges` map — the
/// same shape production builds over the pinned QIDClosure edges.
struct MapAdjacency {
    adj: HashMap<u64, HashSet<u64>>,
}

impl WikidataAdjacencyProvider for MapAdjacency {
    fn neighbors(&self, qid: u64) -> HashSet<u64> {
        self.adj.get(&qid).cloned().unwrap_or_default()
    }
}

pub struct QIDAdjacencyPrimitive;

impl QIDAdjacencyPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "qid_adjacency",
            cookbook_section: "§8.3",
            reference_file: "lattice_distance.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let seeded_count = 32;
        let mut cases = Vec::with_capacity(seeded_count + 2);

        for i in 0..seeded_count {
            // Random connected graph: nodes 1..=n as integer Q-IDs
            // (0 is reserved as the null Q-ID), a spanning tree plus
            // random extra edges, symmetrized. RNG draw order matches
            // the Swift generator exactly.
            let n = 8 + (rng.next() % 25) as usize;
            let mut adj: BTreeMap<u64, HashSet<u64>> = BTreeMap::new();
            for k in 1..=n {
                adj.insert(k as u64, HashSet::new());
            }
            for k in 2..=n {
                let p = 1 + (rng.next() % (k as u64 - 1));
                adj.get_mut(&(k as u64)).unwrap().insert(p);
                adj.get_mut(&p).unwrap().insert(k as u64);
            }
            let extra = (rng.next() % n as u64) as usize;
            for _ in 0..extra {
                let u = 1 + (rng.next() % n as u64);
                let v = 1 + (rng.next() % n as u64);
                if u != v {
                    adj.get_mut(&u).unwrap().insert(v);
                    adj.get_mut(&v).unwrap().insert(u);
                }
            }

            let (a, b) = match i % 4 {
                0 => {
                    let a = 1 + (rng.next() % n as u64);
                    let b = 1 + (rng.next() % n as u64);
                    (a, b)
                }
                1 => {
                    let a = 1 + (rng.next() % n as u64);
                    (a, a)
                }
                2 => (0, 1 + (rng.next() % n as u64)),
                _ => {
                    let a = 1 + (rng.next() % n as u64);
                    let isolated = (n + 1) as u64;
                    adj.insert(isolated, HashSet::new());
                    (a, isolated)
                }
            };
            cases.push(Self::make_case(i, a, b, &adj));
        }

        // Fixed case: direct neighbors — path length exactly 1.
        let direct: BTreeMap<u64, HashSet<u64>> = BTreeMap::from([
            (1, HashSet::from([2])),
            (2, HashSet::from([1])),
        ]);
        cases.push(Self::make_case(seeded_count, 1, 2, &direct));
        // Fixed case: 6-chain, ends 5 apart — beyond the depth-4 budget,
        // pinning MAX_DEPTH (unreachable -> sentinel, 1.0).
        let chain: BTreeMap<u64, HashSet<u64>> = BTreeMap::from([
            (1, HashSet::from([2])),
            (2, HashSet::from([1, 3])),
            (3, HashSet::from([2, 4])),
            (4, HashSet::from([3, 5])),
            (5, HashSet::from([4, 6])),
            (6, HashSet::from([5])),
        ]);
        cases.push(Self::make_case(seeded_count + 1, 1, 6, &chain));

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases {
            Self::encode_output(&c.expected_output, &mut encoder)?;
        }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "qid_adjacency".to_string(),
            cookbook_section: "§8.3".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "lattice_distance.rs".to_string(),
            },
            seed,
            generated_at: chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            output_crc32: crc,
            cases,
        })
    }

    fn compute(a: u64, b: u64, adj: &BTreeMap<u64, HashSet<u64>>) -> (u32, f64) {
        let provider = MapAdjacency {
            adj: adj.iter().map(|(k, v)| (*k, v.clone())).collect(),
        };
        let distance = WikidataGraphDistance::distance(
            a, b, &provider, WikidataGraphDistance::MAX_DEPTH);
        // The distance function never runs the BFS for null Q-IDs; the
        // path output uses the sentinel for that case too.
        let path_len = if a == 0 || b == 0 {
            NO_PATH_SENTINEL
        } else {
            match WikidataGraphDistance::shortest_path_length(
                a, b, &provider, WikidataGraphDistance::MAX_DEPTH) {
                Some(len) => len as u32,
                None => NO_PATH_SENTINEL,
            }
        };
        (path_len, distance)
    }

    fn make_case(index: usize, a: u64, b: u64,
                 adj: &BTreeMap<u64, HashSet<u64>>) -> VectorCase {
        let (path_len, distance) = Self::compute(a, b, adj);

        let mut edges_obj: JsonObject = BTreeMap::new();
        for (node, neighbors) in adj {
            let mut sorted: Vec<u64> = neighbors.iter().copied().collect();
            sorted.sort_unstable();
            edges_obj.insert(
                u64_hex(*node),
                JsonValue::Array(sorted.into_iter().map(|v| JsonValue::String(u64_hex(v))).collect()),
            );
        }
        let mut inputs: JsonObject = BTreeMap::new();
        inputs.insert("a".into(), JsonValue::String(u64_hex(a)));
        inputs.insert("b".into(), JsonValue::String(u64_hex(b)));
        inputs.insert("edges".into(), JsonValue::Object(edges_obj));

        let mut output: JsonObject = BTreeMap::new();
        output.insert("path_len".into(), JsonValue::String(u32_hex(path_len)));
        output.insert("distance".into(), JsonValue::String(f64_hex(distance)));

        let path_description = if path_len == NO_PATH_SENTINEL {
            "none".to_string()
        } else {
            path_len.to_string()
        };
        VectorCase {
            id: format!("case_{:03}", index),
            description: format!("path {}, distance {}", path_description, distance),
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
        let a = match Self::input_u64(c, "a") {
            Ok(v) => v,
            Err(msg) => return Self::fail(c, msg),
        };
        let b = match Self::input_u64(c, "b") {
            Ok(v) => v,
            Err(msg) => return Self::fail(c, msg),
        };
        let edges_obj = match c.inputs.get("edges") {
            Some(JsonValue::Object(o)) => o,
            _ => return Self::fail(c, "missing edges"),
        };
        let mut adj: BTreeMap<u64, HashSet<u64>> = BTreeMap::new();
        for (key, value) in edges_obj {
            let node = match Self::parse_u64(key) {
                Some(v) => v,
                None => return Self::fail(c, "malformed edges key"),
            };
            let arr = match value {
                JsonValue::Array(a) => a,
                _ => return Self::fail(c, "malformed edges entry"),
            };
            let mut neighbors = HashSet::new();
            for item in arr {
                match item {
                    JsonValue::String(s) => match Self::parse_u64(s) {
                        Some(v) => {
                            neighbors.insert(v);
                        }
                        None => return Self::fail(c, "malformed neighbor"),
                    },
                    _ => return Self::fail(c, "malformed neighbor"),
                }
            }
            adj.insert(node, neighbors);
        }

        let (actual_path, actual_distance) = Self::compute(a, b, &adj);

        let expected_path = match c.expected_output.get("path_len") {
            Some(JsonValue::String(s)) => match Self::parse_u32(s) {
                Some(v) => v,
                None => return Self::fail(c, "malformed expected path_len"),
            },
            _ => return Self::fail(c, "missing expected path_len"),
        };
        let expected_distance = match c.expected_output.get("distance") {
            Some(JsonValue::String(s)) => match Self::parse_f64_hex(s) {
                Some(v) => v,
                None => return Self::fail(c, "malformed expected distance"),
            },
            _ => return Self::fail(c, "missing expected distance"),
        };

        encoder.write_u32(actual_path);
        encoder.write_f64(actual_distance);

        if actual_path == expected_path
            && actual_distance.to_bits() == expected_distance.to_bits()
        {
            CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
        } else {
            CaseResult {
                id: c.id.clone(),
                passed: false,
                diagnostic: Some(format!(
                    "mismatch: expected path {} dist {}, got path {} dist {}",
                    u32_hex(expected_path), f64_hex(expected_distance),
                    u32_hex(actual_path), f64_hex(actual_distance)
                )),
            }
        }
    }

    fn encode_output(
        output: &JsonObject,
        encoder: &mut CanonicalBinaryEncoder,
    ) -> Result<(), Box<dyn std::error::Error>> {
        // Order MUST match validate_case (path_len then distance) so
        // generator and validator produce identical canonical byte streams.
        let p = match output.get("path_len") {
            Some(JsonValue::String(s)) => Self::parse_u32(s)
                .ok_or("expected_output malformed path_len")?,
            _ => return Err("expected_output missing path_len".into()),
        };
        let d = match output.get("distance") {
            Some(JsonValue::String(s)) => Self::parse_f64_hex(s)
                .ok_or("expected_output malformed distance")?,
            _ => return Err("expected_output missing distance".into()),
        };
        encoder.write_u32(p);
        encoder.write_f64(d);
        Ok(())
    }

    // ----- Helpers

    fn fail(c: &VectorCase, msg: &str) -> CaseResult {
        CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.to_string()) }
    }

    fn input_u64(c: &VectorCase, key: &str) -> Result<u64, &'static str> {
        match c.inputs.get(key) {
            Some(JsonValue::String(s)) => Self::parse_u64(s).ok_or("malformed u64 input"),
            _ => Err("missing u64 input"),
        }
    }

    fn parse_u64(s: &str) -> Option<u64> {
        let bytes = decode_hex(s).ok()?;
        if bytes.len() != 8 {
            return None;
        }
        let mut w = [0u8; 8];
        w.copy_from_slice(&bytes);
        Some(u64::from_le_bytes(w))
    }

    fn parse_u32(s: &str) -> Option<u32> {
        let bytes = decode_hex(s).ok()?;
        if bytes.len() != 4 {
            return None;
        }
        let mut w = [0u8; 4];
        w.copy_from_slice(&bytes);
        Some(u32::from_le_bytes(w))
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
