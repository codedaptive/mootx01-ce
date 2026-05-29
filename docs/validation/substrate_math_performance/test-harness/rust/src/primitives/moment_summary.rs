// src/primitives/moment_summary.rs
//
// Moment-summary fingerprint (cookbook §8.7) — promotes the
// `moment_summary` reference into the conformance harness per
// the "Pending future work" entry in primitive-catalog.md.
//
// Mirror of Swift's MomentSummaryPrimitive.swift. Calls the real
// reference at glref-rust-moment_summary.rs via the substrate-kit
// crate. Rust uses RowLite (fingerprint + capture_hlc) directly;
// Swift's full Row type is bridged in its harness via an index
// counter closure. Both languages produce bit-identical summary
// fingerprints because the filter + OR-reduce composition is
// integer-only and order-deterministic.
//
// Input schema:
//   rows   : array of {capture_hlc: HLC-32hex, fingerprint: Fingerprint256-64hex}
//   window : {end: HLC-32hex, start: HLC-32hex}
//
// Output schema:
//   summary : Fingerprint256 (64-hex, 32 wire bytes)
//
// Binary canonical encoding (alphabetical key order, single field):
//   summary : 32 bytes (4 × u64 LE per Fingerprint256.to_bytes)

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

use substrate_kit::fingerprint256::Fingerprint256;
use substrate_kit::hlc::HLC;
use substrate_kit::moment_summary::{MomentSummary, RowLite, TimeRange};

pub struct MomentSummaryPrimitive;

impl MomentSummaryPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "moment_summary",
            cookbook_section: "§8.7",
            reference_file: "glref-rust-moment_summary.rs",
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
            let summary = compute_summary(&spec.rows, spec.window);

            let rows_arr: Vec<JsonValue> = spec.rows.iter().map(|r| {
                let mut o: JsonObject = BTreeMap::new();
                o.insert("capture_hlc".into(),
                         JsonValue::String(encode_hex(&hlc_wire_bytes(r.capture_hlc))));
                o.insert("fingerprint".into(),
                         JsonValue::String(encode_hex(&r.fingerprint.wire_bytes())));
                JsonValue::Object(o)
            }).collect();

            let mut window_obj: JsonObject = BTreeMap::new();
            window_obj.insert("end".into(),
                              JsonValue::String(encode_hex(&hlc_wire_bytes(spec.window.end))));
            window_obj.insert("start".into(),
                              JsonValue::String(encode_hex(&hlc_wire_bytes(spec.window.start))));

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("rows".into(),   JsonValue::Array(rows_arr));
            inputs.insert("window".into(), JsonValue::Object(window_obj));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("summary".into(),
                          JsonValue::String(encode_hex(&summary.wire_bytes())));

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
            primitive: "moment_summary".to_string(),
            cookbook_section: "§8.7".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-moment_summary.rs".to_string(),
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

struct CaseSpec {
    rows: Vec<RowLite>,
    window: TimeRange,
    description: String,
}

fn validate_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let rows_arr = match c.inputs.get("rows") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail(c, "missing rows"),
    };
    let mut rows: Vec<RowLite> = Vec::with_capacity(rows_arr.len());
    for (idx, rv) in rows_arr.iter().enumerate() {
        let rd = match rv {
            JsonValue::Object(o) => o,
            _ => return fail(c, &format!("row[{}] not an object", idx)),
        };
        let fp = match rd.get("fingerprint") {
            Some(JsonValue::String(s)) => match parse_fingerprint(s) {
                Some(f) => f,
                None => return fail(c, &format!("row[{}] malformed fingerprint", idx)),
            },
            _ => return fail(c, &format!("row[{}] missing fingerprint", idx)),
        };
        let h = match rd.get("capture_hlc") {
            Some(JsonValue::String(s)) => match parse_hlc(s) {
                Some(h) => h,
                None => return fail(c, &format!("row[{}] malformed capture_hlc", idx)),
            },
            _ => return fail(c, &format!("row[{}] missing capture_hlc", idx)),
        };
        rows.push(RowLite { fingerprint: fp, capture_hlc: h });
    }
    let wd = match c.inputs.get("window") {
        Some(JsonValue::Object(o)) => o,
        _ => return fail(c, "missing window"),
    };
    let start = match wd.get("start") {
        Some(JsonValue::String(s)) => match parse_hlc(s) {
            Some(h) => h,
            None => return fail(c, "malformed window.start"),
        },
        _ => return fail(c, "missing window.start"),
    };
    let end = match wd.get("end") {
        Some(JsonValue::String(s)) => match parse_hlc(s) {
            Some(h) => h,
            None => return fail(c, "malformed window.end"),
        },
        _ => return fail(c, "missing window.end"),
    };
    let window = TimeRange::new(start, end);

    let actual = compute_summary(&rows, window);

    let expected = match c.expected_output.get("summary") {
        Some(JsonValue::String(s)) => match parse_fingerprint(s) {
            Some(f) => f,
            None => return fail(c, "malformed expected summary"),
        },
        _ => return fail(c, "missing expected summary"),
    };

    encoder.write_bytes(&actual.wire_bytes());

    if actual == expected {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(), passed: false,
            diagnostic: Some(format!(
                "summary mismatch: expected {}, got {}",
                encode_hex(&expected.wire_bytes()),
                encode_hex(&actual.wire_bytes()))),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let s = match output.get("summary") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing summary"),
    };
    let fp = parse_fingerprint(s).expect("malformed summary hex");
    encoder.write_bytes(&fp.wire_bytes());
}

fn fail(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.to_string()) }
}

fn compute_summary(rows: &[RowLite], window: TimeRange) -> Fingerprint256 {
    MomentSummary::summarize(rows, window, MomentSummary::captured_during)
}

fn generate_case_spec(i: usize, rng: &mut SplitMix64) -> CaseSpec {
    match i {
        0 => CaseSpec {
            rows: vec![],
            window: TimeRange::new(hlc(0, 0, 0), hlc(1000, 0, 0)),
            description: "empty rows -> zero fingerprint".to_string(),
        },
        1 => {
            let fp = Fingerprint256 { block0: 0xCAFEBABE, block1: 0xDEAD, block2: 0xBEEF, block3: 0x1234 };
            CaseSpec {
                rows: vec![RowLite { fingerprint: fp, capture_hlc: hlc(500, 0, 0) }],
                window: TimeRange::new(hlc(0, 0, 0), hlc(1000, 0, 0)),
                description: "single row inside window".to_string(),
            }
        }
        2 => {
            let fp = Fingerprint256 { block0: 0xFFFF, block1: 0, block2: 0, block3: 0 };
            CaseSpec {
                rows: vec![RowLite { fingerprint: fp, capture_hlc: hlc(2000, 0, 0) }],
                window: TimeRange::new(hlc(0, 0, 0), hlc(1000, 0, 0)),
                description: "single row outside window -> zero".to_string(),
            }
        }
        3 => {
            let mut rows = Vec::new();
            for k in 0..5 {
                let fp = random_fingerprint(rng);
                rows.push(RowLite { fingerprint: fp,
                                     capture_hlc: hlc(100 * (k + 1) as i64, 0, 1) });
            }
            CaseSpec {
                rows,
                window: TimeRange::new(hlc(0, 0, 0), hlc(10_000, 0, 0)),
                description: "all 5 rows in window".to_string(),
            }
        }
        4 => {
            let fp = Fingerprint256 { block0: 0x1, block1: 0, block2: 0, block3: 0 };
            CaseSpec {
                rows: vec![RowLite { fingerprint: fp, capture_hlc: hlc(100, 0, 1) }],
                window: TimeRange::new(hlc(100, 0, 1), hlc(200, 0, 1)),
                description: "row at window.start (inclusive)".to_string(),
            }
        }
        5 => {
            let fp = Fingerprint256 { block0: 0x2, block1: 0, block2: 0, block3: 0 };
            CaseSpec {
                rows: vec![RowLite { fingerprint: fp, capture_hlc: hlc(200, 0, 1) }],
                window: TimeRange::new(hlc(100, 0, 1), hlc(200, 0, 1)),
                description: "row at window.end (inclusive)".to_string(),
            }
        }
        6 => {
            let fp = Fingerprint256 { block0: 0x4, block1: 0, block2: 0, block3: 0 };
            CaseSpec {
                rows: vec![RowLite { fingerprint: fp, capture_hlc: hlc(99, 0, 1) }],
                window: TimeRange::new(hlc(100, 0, 1), hlc(200, 0, 1)),
                description: "row just before window.start -> excluded".to_string(),
            }
        }
        7 => {
            let fp = Fingerprint256 { block0: 0x8, block1: 0, block2: 0, block3: 0 };
            CaseSpec {
                rows: vec![RowLite { fingerprint: fp, capture_hlc: hlc(201, 0, 1) }],
                window: TimeRange::new(hlc(100, 0, 1), hlc(200, 0, 1)),
                description: "row just after window.end -> excluded".to_string(),
            }
        }
        _ => {
            let row_count = 1 + (rng.next() % 16) as usize;
            let mut rows = Vec::with_capacity(row_count);
            for _ in 0..row_count {
                let fp = random_fingerprint(rng);
                let phys = (rng.next() & 0x0000_FFFF_FFFF_FFFF) as i64;
                let log  = (rng.next() & 0x0000_FFFF) as i32;
                let node = (rng.next() & 0x0000_00FF) as i32;
                rows.push(RowLite { fingerprint: fp, capture_hlc: hlc(phys, log, node) });
            }
            let w_start_phys = (rng.next() & 0x0000_FFFF_FFFF_FFFF) as i64;
            let w_end_offset = (rng.next() & 0x0000_FFFF_FFFF) as i64;
            let window = TimeRange::new(
                hlc(w_start_phys, 0, 0),
                hlc(w_start_phys.wrapping_add(w_end_offset), 0, i32::MAX));
            CaseSpec {
                rows,
                window,
                description: format!("random {} rows, window spans 0x..{:x}", row_count, w_end_offset),
            }
        }
    }
}

fn parse_fingerprint(s: &str) -> Option<Fingerprint256> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 32 { return None; }
    Fingerprint256::from_wire_bytes(&bytes).ok()
}

fn parse_hlc(s: &str) -> Option<HLC> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 16 { return None; }
    let mut phys: i64 = 0;
    for i in 0..8 { phys |= (bytes[i] as i64) << (i * 8); }
    let mut log: i32 = 0;
    for i in 0..4 { log  |= (bytes[8 + i] as i32) << (i * 8); }
    let mut node: i32 = 0;
    for i in 0..4 { node |= (bytes[12 + i] as i32) << (i * 8); }
    Some(HLC { physical_time: phys, logical_count: log, node_id: node })
}

fn hlc_wire_bytes(h: HLC) -> Vec<u8> {
    let mut out = Vec::with_capacity(16);
    out.extend_from_slice(&h.physical_time.to_le_bytes());
    out.extend_from_slice(&h.logical_count.to_le_bytes());
    out.extend_from_slice(&h.node_id.to_le_bytes());
    out
}

fn hlc(phys: i64, log: i32, node: i32) -> HLC {
    HLC { physical_time: phys, logical_count: log, node_id: node }
}

fn random_fingerprint(rng: &mut SplitMix64) -> Fingerprint256 {
    Fingerprint256 { block0: rng.next(), block1: rng.next(), block2: rng.next(), block3: rng.next() }
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
