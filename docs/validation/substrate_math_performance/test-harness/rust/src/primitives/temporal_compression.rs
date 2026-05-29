// src/primitives/temporal_compression.rs
//
// Mirror of Swift's TemporalCompressionPrimitive. Calls real
// reference at glref-rust-temporal_compression.rs via the
// geniuslocus-reference crate.
//
// Exercises the `rollup` entry point.
//
// Input schema:
//   target_level : u8
//   windows      : array of {start_hlc, end_hlc, level, fingerprint, row_count}
//
// Output schema:
//   start_hlc   : 16-byte hex
//   end_hlc     : 16-byte hex
//   level       : u8
//   fingerprint : 32-byte hex
//   row_count   : u32 hex

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, encode_hex, u32_hex, u8_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::fingerprint256::Fingerprint256;
use substrate_kit::hlc::HLC;
use substrate_kit::temporal_compression::{
    TemporalCompression, TemporalWindow, WindowLevel,
};

pub struct TemporalCompressionPrimitive;

impl TemporalCompressionPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "temporal_compression",
            cookbook_section: "§8.14",
            reference_file: "glref-rust-temporal_compression.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let n_windows = 2 + (rng.next() % 6) as usize;
            let input_level_raw: u8 = (i % 5) as u8;
            let input_level = u8_to_level(input_level_raw);
            let target_level_raw: u8 = ((i % 5) + 1) as u8 % 6;
            let target_level = u8_to_level(target_level_raw);

            let mut windows: Vec<TemporalWindow> = Vec::with_capacity(n_windows);
            for _ in 0..n_windows {
                let start_raw = rng.next();
                let end_raw   = rng.next();
                let fp = Fingerprint256::new(
                    rng.next(), rng.next(), rng.next(), rng.next());
                let row_count = (rng.next() & 0xFFFF) as u32;

                let start_phys = (start_raw & 0x0000_FFFF_FFFF_FFFF) as i64;
                let end_phys   = (end_raw   & 0x0000_FFFF_FFFF_FFFF) as i64;
                let start_hlc = HLC::new(start_phys, 0, 0);
                let end_hlc   = HLC::new(end_phys,   0, 0);
                windows.push(TemporalWindow {
                    start_hlc, end_hlc,
                    level: input_level,
                    fingerprint: fp, row_count,
                });
            }

            let result = TemporalCompression::rollup(&windows, target_level);

            let windows_arr: Vec<JsonValue> = windows.iter().map(|w| {
                let mut o: JsonObject = BTreeMap::new();
                o.insert("start_hlc".into(), JsonValue::String(encode_hex(&w.start_hlc.wire_bytes())));
                o.insert("end_hlc".into(),   JsonValue::String(encode_hex(&w.end_hlc.wire_bytes())));
                o.insert("level".into(),     JsonValue::String(u8_hex(level_to_u8(w.level))));
                o.insert("fingerprint".into(), JsonValue::String(encode_fp(&w.fingerprint)));
                o.insert("row_count".into(),   JsonValue::String(u32_hex(w.row_count)));
                JsonValue::Object(o)
            }).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("target_level".into(), JsonValue::String(u8_hex(target_level_raw)));
            inputs.insert("windows".into(),      JsonValue::Array(windows_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("start_hlc".into(),   JsonValue::String(encode_hex(&result.start_hlc.wire_bytes())));
            output.insert("end_hlc".into(),     JsonValue::String(encode_hex(&result.end_hlc.wire_bytes())));
            output.insert("level".into(),       JsonValue::String(u8_hex(level_to_u8(result.level))));
            output.insert("fingerprint".into(), JsonValue::String(encode_fp(&result.fingerprint)));
            output.insert("row_count".into(),   JsonValue::String(u32_hex(result.row_count)));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!(
                    "n={}, input_level={}, target={}",
                    n_windows, input_level_raw, target_level_raw),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "temporal_compression".to_string(),
            cookbook_section: "§8.14".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-temporal_compression.rs".to_string(),
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
        for c in &file.cases { case_results.push(validate_case(c, &mut encoder)); }
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
    let target_level_raw = match c.inputs.get("target_level") {
        Some(JsonValue::String(s)) => match parse_u8(s) {
            Some(v) => v, None => return fail_case(c, "malformed target_level"),
        },
        _ => return fail_case(c, "missing target_level"),
    };
    let target_level = u8_to_level(target_level_raw);

    let wins_arr = match c.inputs.get("windows") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing windows"),
    };
    let mut windows: Vec<TemporalWindow> = Vec::with_capacity(wins_arr.len());
    for v in wins_arr {
        match v {
            JsonValue::Object(o) => match parse_window(o) {
                Some(w) => windows.push(w),
                None => return fail_case(c, "malformed window"),
            },
            _ => return fail_case(c, "window element not object"),
        }
    }

    let actual = TemporalCompression::rollup(&windows, target_level);
    let expected = match parse_window(&c.expected_output) {
        Some(w) => w,
        None => return fail_case(c, "malformed expected window"),
    };

    write_window(&actual, encoder);

    if window_eq(&actual, &expected) {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some("rollup window mismatch".into()),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let w = parse_window(output).expect("expected_output malformed");
    write_window(&w, encoder);
}

fn write_window(w: &TemporalWindow, encoder: &mut CanonicalBinaryEncoder) {
    encoder.write_bytes(&w.start_hlc.wire_bytes());
    encoder.write_bytes(&w.end_hlc.wire_bytes());
    encoder.write_u8(level_to_u8(w.level));
    encoder.write_u64(w.fingerprint.block0);
    encoder.write_u64(w.fingerprint.block1);
    encoder.write_u64(w.fingerprint.block2);
    encoder.write_u64(w.fingerprint.block3);
    encoder.write_u32(w.row_count);
}

fn window_eq(a: &TemporalWindow, b: &TemporalWindow) -> bool {
    a.start_hlc == b.start_hlc
        && a.end_hlc == b.end_hlc
        && a.level == b.level
        && a.fingerprint.block0 == b.fingerprint.block0
        && a.fingerprint.block1 == b.fingerprint.block1
        && a.fingerprint.block2 == b.fingerprint.block2
        && a.fingerprint.block3 == b.fingerprint.block3
        && a.row_count == b.row_count
}

fn parse_window(obj: &JsonObject) -> Option<TemporalWindow> {
    let s_hex = match obj.get("start_hlc")? { JsonValue::String(s) => s, _ => return None };
    let e_hex = match obj.get("end_hlc")?   { JsonValue::String(s) => s, _ => return None };
    let l_hex = match obj.get("level")?     { JsonValue::String(s) => s, _ => return None };
    let f_hex = match obj.get("fingerprint")? { JsonValue::String(s) => s, _ => return None };
    let rc_hex = match obj.get("row_count")?  { JsonValue::String(s) => s, _ => return None };
    let start_hlc = parse_hlc(s_hex)?;
    let end_hlc   = parse_hlc(e_hex)?;
    let level_raw = parse_u8(l_hex)?;
    let level = u8_to_level(level_raw);
    let fp = parse_fp(f_hex)?;
    let rc = parse_u32(rc_hex)?;
    Some(TemporalWindow {
        start_hlc, end_hlc, level, fingerprint: fp, row_count: rc,
    })
}

fn parse_hlc(s: &str) -> Option<HLC> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 16 { return None; }
    HLC::from_wire_bytes(&bytes).ok()
}

fn parse_fp(s: &str) -> Option<Fingerprint256> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 32 { return None; }
    let mut blocks = [0u64; 4];
    for i in 0..4 {
        let mut w: u64 = 0;
        for j in 0..8 { w |= (bytes[i * 8 + j] as u64) << (j * 8); }
        blocks[i] = w;
    }
    Some(Fingerprint256::new(blocks[0], blocks[1], blocks[2], blocks[3]))
}

fn parse_u8(s: &str) -> Option<u8> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 1 { return None; }
    Some(bytes[0])
}

fn parse_u32(s: &str) -> Option<u32> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 4 { return None; }
    let mut v: u32 = 0;
    for (i, b) in bytes.iter().enumerate() { v |= (*b as u32) << (i * 8); }
    Some(v)
}

fn encode_fp(fp: &Fingerprint256) -> String {
    let mut bytes = [0u8; 32];
    let blocks = [fp.block0, fp.block1, fp.block2, fp.block3];
    for (i, w) in blocks.iter().enumerate() {
        for j in 0..8 { bytes[i * 8 + j] = ((w >> (j * 8)) & 0xFF) as u8; }
    }
    encode_hex(&bytes)
}

fn u8_to_level(raw: u8) -> WindowLevel {
    match raw {
        0 => WindowLevel::Hour,
        1 => WindowLevel::Day,
        2 => WindowLevel::Week,
        3 => WindowLevel::Month,
        4 => WindowLevel::Quarter,
        _ => WindowLevel::Year,
    }
}

fn level_to_u8(level: WindowLevel) -> u8 {
    match level {
        WindowLevel::Hour    => 0,
        WindowLevel::Day     => 1,
        WindowLevel::Week    => 2,
        WindowLevel::Month   => 3,
        WindowLevel::Quarter => 4,
        WindowLevel::Year    => 5,
    }
}

fn fail_case(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.into()) }
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
