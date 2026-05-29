// src/primitives/audit_log_fold.rs
//
// Audit log G-Set projection (cookbook § 5.3 + § 8.15). Mirror of
// Swift's AuditLogFoldPrimitive.swift.

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, encode_hex, u64_hex, u8_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kit::audit_log_fold::AuditLogFold;
use substrate_kit::hlc::HLC;
use substrate_kit::verbs::{AuditEvent, LatticeAnchor, NounType, RowId};

pub struct AuditLogFoldPrimitive;

impl AuditLogFoldPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "audit_log_fold",
            cookbook_section: "§5.3+§8.15",
            reference_file: "glref-rust-audit_log_fold.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        let state_menu: [u8; 10] = [0, 1, 2, 3, 16, 17, 18, 19, 32, 33];

        for i in 0..case_count {
            let estate_bytes = random_uuid_bytes(&mut rng);
            let row_bytes = random_uuid_bytes(&mut rng);
            let noun_raw = (i % 8) as u8;
            let noun = u8_to_noun(noun_raw);

            let n_events = 5 + (rng.next() % 8) as usize;

            let mut raw_events: Vec<SyntheticEvent> = Vec::with_capacity(n_events);
            let mut last_phys: i64 = 0;
            for _ in 0..n_events {
                last_phys += 1 + (rng.next() & 0xFFF) as i64;
                let hlc = HLC::new(last_phys, 0, 0);
                let state_val = state_menu[(rng.next() % state_menu.len() as u64) as usize];
                let adj_top = (rng.next() & 0xFFFFFFFFFFFFFF00) as i64;
                let adj = (state_val as i64) | adj_top;
                let op = rng.next() as i64;
                let prov = rng.next() as i64;
                let udc = rng.next();
                let qid = rng.next() & 0x7FFFFFFFFFFFFFFF;
                raw_events.push(SyntheticEvent {
                    hlc, adjective: adj, operational: op, provenance: prov,
                    udc, qid, verb: "mutate".to_string(),
                });
            }

            // Deterministic Fisher-Yates shuffle matching Swift.
            let mut shuffled = raw_events.clone();
            for k in (1..shuffled.len()).rev() {
                let j = (rng.next() % (k as u64 + 1)) as usize;
                shuffled.swap(k, j);
            }

            let estate_u128 = bytes_to_u128(&estate_bytes);
            let row_u128 = bytes_to_u128(&row_bytes);
            let row_id = RowId(row_u128);
            let estate_id = estate_u128;  // estate_uuid is plain u128
            let audit_events: Vec<AuditEvent> = shuffled.iter().map(|e| {
                AuditEvent {
                    event_id: 0,
                    estate_uuid: estate_id,
                    row_id,
                    hlc: e.hlc,
                    verb: e.verb.clone(),
                    before_bitmaps: None,
                    after_bitmaps: (e.adjective, e.operational, e.provenance),
                    before_lattice_anchor: None,
                    after_lattice_anchor: LatticeAnchor::new(e.udc, e.qid),
                    actor: "harness".to_string(),
                }
            }).collect();

            let state = AuditLogFold::project_current_state(
                row_id, noun, &audit_events)
                .expect("projection returned None");

            let events_arr: Vec<JsonValue> = shuffled.iter().map(|e| {
                let mut o: JsonObject = BTreeMap::new();
                o.insert("hlc".into(), JsonValue::String(encode_hex(&e.hlc.wire_bytes())));
                o.insert("after_adjective".into(), JsonValue::String(u64_hex(e.adjective as u64)));
                o.insert("after_operational".into(), JsonValue::String(u64_hex(e.operational as u64)));
                o.insert("after_provenance".into(), JsonValue::String(u64_hex(e.provenance as u64)));
                o.insert("after_udc".into(), JsonValue::String(u64_hex(e.udc)));
                o.insert("after_qid".into(), JsonValue::String(u64_hex(e.qid)));
                o.insert("verb".into(), JsonValue::String(e.verb.clone()));
                JsonValue::Object(o)
            }).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("row_id".into(), JsonValue::String(encode_hex(&row_bytes)));
            inputs.insert("noun_type".into(), JsonValue::String(u8_hex(noun_raw)));
            inputs.insert("estate_uuid".into(), JsonValue::String(encode_hex(&estate_bytes)));
            inputs.insert("events".into(), JsonValue::Array(events_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("state_raw".into(), JsonValue::String(u8_hex(state.state_raw)));
            output.insert("adjective_bitmap".into(),
                JsonValue::String(u64_hex(state.adjective_bitmap as u64)));
            output.insert("operational_bitmap".into(),
                JsonValue::String(u64_hex(state.operational_bitmap as u64)));
            output.insert("provenance_bitmap".into(),
                JsonValue::String(u64_hex(state.provenance_bitmap as u64)));
            output.insert("udc".into(),
                JsonValue::String(u64_hex(state.lattice_anchor.udc_code)));
            output.insert("qid".into(),
                JsonValue::String(u64_hex(state.lattice_anchor.qid_pointer)));
            output.insert("tombstoned".into(),
                JsonValue::String(u8_hex(if state.tombstoned { 1 } else { 0 })));
            output.insert("last_event_hlc".into(),
                JsonValue::String(encode_hex(&state.last_event_hlc.wire_bytes())));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!(
                    "noun={}, |events|={}, tombstoned={}",
                    noun_raw, n_events, state.tombstoned),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "audit_log_fold".to_string(),
            cookbook_section: "§5.3+§8.15".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-audit_log_fold.rs".to_string(),
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
    let rid_vec = match c.inputs.get("row_id") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 16 => b,
            _ => return fail_case(c, "malformed row_id"),
        },
        _ => return fail_case(c, "missing row_id"),
    };
    let est_vec = match c.inputs.get("estate_uuid") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 16 => b,
            _ => return fail_case(c, "malformed estate_uuid"),
        },
        _ => return fail_case(c, "missing estate_uuid"),
    };
    let nt_vec = match c.inputs.get("noun_type") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 1 => b,
            _ => return fail_case(c, "malformed noun_type"),
        },
        _ => return fail_case(c, "missing noun_type"),
    };
    let noun = u8_to_noun(nt_vec[0]);
    let mut rid_arr = [0u8; 16];
    rid_arr.copy_from_slice(&rid_vec);
    let mut est_arr = [0u8; 16];
    est_arr.copy_from_slice(&est_vec);
    let row_u128 = bytes_to_u128(&rid_arr);
    let est_u128 = bytes_to_u128(&est_arr);
    let row_id = RowId(row_u128);

    let events_arr = match c.inputs.get("events") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing events"),
    };
    let mut audit_events: Vec<AuditEvent> = Vec::with_capacity(events_arr.len());
    for v in events_arr {
        let obj = match v { JsonValue::Object(o) => o,
            _ => return fail_case(c, "event not object") };
        let hlc = match parse_hlc(obj.get("hlc")) {
            Some(h) => h, None => return fail_case(c, "event hlc malformed") };
        let adj = match parse_i64(obj.get("after_adjective")) {
            Some(v) => v, None => return fail_case(c, "after_adjective malformed") };
        let op = match parse_i64(obj.get("after_operational")) {
            Some(v) => v, None => return fail_case(c, "after_operational malformed") };
        let prov = match parse_i64(obj.get("after_provenance")) {
            Some(v) => v, None => return fail_case(c, "after_provenance malformed") };
        let udc = match parse_u64(obj.get("after_udc")) {
            Some(v) => v, None => return fail_case(c, "after_udc malformed") };
        let qid = match parse_u64(obj.get("after_qid")) {
            Some(v) => v, None => return fail_case(c, "after_qid malformed") };
        let verb = match obj.get("verb") {
            Some(JsonValue::String(s)) => s.clone(),
            _ => return fail_case(c, "verb malformed"),
        };

        audit_events.push(AuditEvent {
                    event_id: 0,
            estate_uuid: est_u128,
            row_id,
            hlc,
            verb,
            before_bitmaps: None,
            after_bitmaps: (adj, op, prov),
            before_lattice_anchor: None,
            after_lattice_anchor: LatticeAnchor::new(udc, qid),
            actor: "harness".to_string(),
        });
    }

    let state = match AuditLogFold::project_current_state(row_id, noun, &audit_events) {
        Some(s) => s,
        None => return fail_case(c, "projection returned None"),
    };

    // Parse expected.
    let exp_state_raw = match parse_u8(c.expected_output.get("state_raw")) {
        Some(v) => v, None => return fail_case(c, "missing state_raw") };
    let exp_adj = match parse_i64(c.expected_output.get("adjective_bitmap")) {
        Some(v) => v, None => return fail_case(c, "missing adjective_bitmap") };
    let exp_op = match parse_i64(c.expected_output.get("operational_bitmap")) {
        Some(v) => v, None => return fail_case(c, "missing operational_bitmap") };
    let exp_prov = match parse_i64(c.expected_output.get("provenance_bitmap")) {
        Some(v) => v, None => return fail_case(c, "missing provenance_bitmap") };
    let exp_udc = match parse_u64(c.expected_output.get("udc")) {
        Some(v) => v, None => return fail_case(c, "missing udc") };
    let exp_qid = match parse_u64(c.expected_output.get("qid")) {
        Some(v) => v, None => return fail_case(c, "missing qid") };
    let exp_tomb = match parse_u8(c.expected_output.get("tombstoned")) {
        Some(v) => v, None => return fail_case(c, "missing tombstoned") };
    let exp_hlc = match parse_hlc(c.expected_output.get("last_event_hlc")) {
        Some(h) => h, None => return fail_case(c, "missing last_event_hlc") };

    // Canonical encode.
    encoder.write_u8(state.state_raw);
    encoder.write_i64(state.adjective_bitmap);
    encoder.write_i64(state.operational_bitmap);
    encoder.write_i64(state.provenance_bitmap);
    encoder.write_u64(state.lattice_anchor.udc_code);
    encoder.write_u64(state.lattice_anchor.qid_pointer);
    encoder.write_u8(if state.tombstoned { 1 } else { 0 });
    encoder.write_bytes(&state.last_event_hlc.wire_bytes());

    if state.state_raw != exp_state_raw {
        return fail_case(c, "state_raw mismatch");
    }
    if state.adjective_bitmap != exp_adj { return fail_case(c, "adjective mismatch"); }
    if state.operational_bitmap != exp_op { return fail_case(c, "operational mismatch"); }
    if state.provenance_bitmap != exp_prov { return fail_case(c, "provenance mismatch"); }
    if state.lattice_anchor.udc_code != exp_udc { return fail_case(c, "udc mismatch"); }
    if state.lattice_anchor.qid_pointer != exp_qid { return fail_case(c, "qid mismatch"); }
    let tomb_actual = if state.tombstoned { 1u8 } else { 0u8 };
    if tomb_actual != exp_tomb { return fail_case(c, "tombstoned mismatch"); }
    if state.last_event_hlc != exp_hlc { return fail_case(c, "last_event_hlc mismatch"); }

    CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let state_raw = parse_u8(output.get("state_raw")).expect("missing state_raw");
    let adj = parse_i64(output.get("adjective_bitmap")).expect("missing adj");
    let op = parse_i64(output.get("operational_bitmap")).expect("missing op");
    let prov = parse_i64(output.get("provenance_bitmap")).expect("missing prov");
    let udc = parse_u64(output.get("udc")).expect("missing udc");
    let qid = parse_u64(output.get("qid")).expect("missing qid");
    let tomb = parse_u8(output.get("tombstoned")).expect("missing tomb");
    let hlc = parse_hlc(output.get("last_event_hlc")).expect("missing hlc");

    encoder.write_u8(state_raw);
    encoder.write_i64(adj);
    encoder.write_i64(op);
    encoder.write_i64(prov);
    encoder.write_u64(udc);
    encoder.write_u64(qid);
    encoder.write_u8(tomb);
    encoder.write_bytes(&hlc.wire_bytes());
}

fn fail_case(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.into()) }
}

fn parse_hlc(v: Option<&JsonValue>) -> Option<HLC> {
    let s = match v? { JsonValue::String(s) => s, _ => return None };
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 16 { return None; }
    HLC::from_wire_bytes(&bytes).ok()
}

fn parse_u8(v: Option<&JsonValue>) -> Option<u8> {
    let s = match v? { JsonValue::String(s) => s, _ => return None };
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 1 { return None; }
    Some(bytes[0])
}

fn parse_u64(v: Option<&JsonValue>) -> Option<u64> {
    let s = match v? { JsonValue::String(s) => s, _ => return None };
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 { return None; }
    let mut x: u64 = 0;
    for (i, b) in bytes.iter().enumerate() { x |= (*b as u64) << (i * 8); }
    Some(x)
}

fn parse_i64(v: Option<&JsonValue>) -> Option<i64> {
    parse_u64(v).map(|u| u as i64)
}

fn random_uuid_bytes(rng: &mut SplitMix64) -> [u8; 16] {
    let lo = rng.next();
    let hi = rng.next();
    let mut bytes = [0u8; 16];
    bytes[0..8].copy_from_slice(&lo.to_le_bytes());
    bytes[8..16].copy_from_slice(&hi.to_le_bytes());
    bytes
}

fn bytes_to_u128(bytes: &[u8; 16]) -> u128 {
    let mut acc: u128 = 0;
    for i in 0..16 { acc |= (bytes[i] as u128) << (i * 8); }
    acc
}

fn u8_to_noun(raw: u8) -> NounType {
    match raw {
        0 => NounType::Drawer,
        1 => NounType::Tunnel,
        2 => NounType::KGFact,
        3 => NounType::DiaryEntry,
        4 => NounType::Proposal,
        5 => NounType::Association,
        6 => NounType::LearnedReference,
        _ => NounType::AmbientSample,
    }
}

struct SyntheticEvent {
    hlc: HLC,
    adjective: i64,
    operational: i64,
    provenance: i64,
    udc: u64,
    qid: u64,
    verb: String,
}

impl Clone for SyntheticEvent {
    fn clone(&self) -> Self {
        Self {
            hlc: self.hlc,
            adjective: self.adjective,
            operational: self.operational,
            provenance: self.provenance,
            udc: self.udc,
            qid: self.qid,
            verb: self.verb.clone(),
        }
    }
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
