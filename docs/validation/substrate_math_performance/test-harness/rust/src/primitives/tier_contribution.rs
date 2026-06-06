// src/primitives/tier_contribution.rs
//
// Tier contribution fingerprint (cookbook § 12.3). Mirror of
// Swift's TierContributionPrimitive.swift.

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, encode_hex, u32_hex, u64_hex},
    splitmix64::SplitMix64,
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLC;
use substrate_ml::tier_contribution::{
    FederationCase, TierContributionFingerprint,
};

pub struct TierContributionPrimitive;

impl TierContributionPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "tier_contribution",
            cookbook_section: "§12.3",
            reference_file: "glref-rust-tier_contribution.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let mut rng = SplitMix64::new(seed);
        let case_count = 32usize;
        let mut cases = Vec::with_capacity(case_count);

        for i in 0..case_count {
            let estate_bytes = random_uuid_bytes(&mut rng);
            let federation_case_raw: u32 = (1 + (i % 3)) as u32;
            let federation_case = FederationCase::from_raw(federation_case_raw)
                .unwrap_or(FederationCase::Household);
            let hlc_packed = rng.next();
            let hlc = HLC::from_packed(hlc_packed);

            let cohort_size = i % 8;
            let mut cohort: Vec<Fingerprint256> = Vec::with_capacity(cohort_size);
            for _ in 0..cohort_size {
                cohort.push(Fingerprint256::new(
                    rng.next(), rng.next(), rng.next(), rng.next()));
            }

            let contrib = TierContributionFingerprint::build(
                estate_bytes, federation_case, &cohort, hlc);
            let wire_bytes = TierContributionFingerprint::encode(&contrib);

            let cohort_arr: Vec<JsonValue> = cohort.iter()
                .map(|fp| JsonValue::String(encode_fp_le(fp))).collect();

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("estate_uuid".into(),
                          JsonValue::String(encode_hex(&estate_bytes)));
            inputs.insert("federation_case".into(),
                          JsonValue::String(u32_hex(federation_case_raw)));
            inputs.insert("hlc_packed".into(),
                          JsonValue::String(u64_hex(hlc_packed)));
            inputs.insert("shareable".into(), JsonValue::Array(cohort_arr));

            let mut output: JsonObject = BTreeMap::new();
            output.insert("wire_bytes".into(),
                          JsonValue::String(encode_hex(&wire_bytes)));
            output.insert("row_count".into(),
                          JsonValue::String(u32_hex(contrib.row_count)));
            output.insert("aggregate".into(),
                          JsonValue::String(encode_fp_le(&contrib.aggregate)));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: format!(
                    "case={}, |cohort|={}", federation_case_raw, cohort_size),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases { encode_output(&c.expected_output, &mut encoder); }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "tier_contribution".to_string(),
            cookbook_section: "§12.3".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "glref-rust-tier_contribution.rs".to_string(),
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
    let estate_bytes_vec = match c.inputs.get("estate_uuid") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 16 => b,
            _ => return fail_case(c, "malformed estate_uuid"),
        },
        _ => return fail_case(c, "missing estate_uuid"),
    };
    let mut estate_bytes = [0u8; 16];
    estate_bytes.copy_from_slice(&estate_bytes_vec);

    let fc_bytes = match c.inputs.get("federation_case") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 4 => b,
            _ => return fail_case(c, "malformed federation_case"),
        },
        _ => return fail_case(c, "missing federation_case"),
    };
    let mut fc_raw: u32 = 0;
    for j in 0..4 { fc_raw |= (fc_bytes[j] as u32) << (j * 8); }
    let fc = match FederationCase::from_raw(fc_raw) {
        Some(f) => f,
        None => return fail_case(c, "unknown federation_case"),
    };

    let hlc_bytes = match c.inputs.get("hlc_packed") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 8 => b,
            _ => return fail_case(c, "malformed hlc_packed"),
        },
        _ => return fail_case(c, "missing hlc_packed"),
    };
    let mut hlc_packed: u64 = 0;
    for j in 0..8 { hlc_packed |= (hlc_bytes[j] as u64) << (j * 8); }
    let hlc = HLC::from_packed(hlc_packed);

    let cohort_arr = match c.inputs.get("shareable") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing shareable"),
    };
    let mut cohort: Vec<Fingerprint256> = Vec::with_capacity(cohort_arr.len());
    for v in cohort_arr {
        match v {
            JsonValue::String(s) => match parse_fp_le(s) {
                Some(fp) => cohort.push(fp),
                None => return fail_case(c, "malformed shareable element"),
            },
            _ => return fail_case(c, "non-string shareable element"),
        }
    }

    let contrib = TierContributionFingerprint::build(
        estate_bytes, fc, &cohort, hlc);
    let actual_wire = TierContributionFingerprint::encode(&contrib);

    let expected_wire = match c.expected_output.get("wire_bytes") {
        Some(JsonValue::String(s)) => match decode_hex(s) {
            Ok(b) if b.len() == 64 => b,
            _ => return fail_case(c, "malformed expected wire_bytes"),
        },
        _ => return fail_case(c, "missing expected wire_bytes"),
    };

    // Roundtrip check
    let roundtripped = match TierContributionFingerprint::decode(&actual_wire) {
        Some(r) => r,
        None => return fail_case(c, "decode failed"),
    };
    if roundtripped.estate_uuid != contrib.estate_uuid
        || roundtripped.federation_case as u32 != contrib.federation_case as u32
        || roundtripped.row_count != contrib.row_count {
        return fail_case(c, "decode roundtrip mismatch");
    }

    encoder.write_bytes(&actual_wire);

    if actual_wire == expected_wire.as_slice() {
        CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
    } else {
        CaseResult {
            id: c.id.clone(),
            passed: false,
            diagnostic: Some("wire_bytes mismatch".into()),
        }
    }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let s = match output.get("wire_bytes") {
        Some(JsonValue::String(s)) => s,
        _ => panic!("expected_output missing wire_bytes"),
    };
    let bytes = decode_hex(s).expect("malformed wire_bytes hex");
    assert_eq!(bytes.len(), 64);
    encoder.write_bytes(&bytes);
}

fn fail_case(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.into()) }
}

fn random_uuid_bytes(rng: &mut SplitMix64) -> [u8; 16] {
    let lo = rng.next();
    let hi = rng.next();
    let mut bytes = [0u8; 16];
    bytes[0..8].copy_from_slice(&lo.to_le_bytes());
    bytes[8..16].copy_from_slice(&hi.to_le_bytes());
    bytes
}

fn encode_fp_le(fp: &Fingerprint256) -> String {
    let mut bytes = [0u8; 32];
    let blocks = [fp.block0, fp.block1, fp.block2, fp.block3];
    for (i, w) in blocks.iter().enumerate() {
        for j in 0..8 { bytes[i * 8 + j] = ((w >> (j * 8)) & 0xFF) as u8; }
    }
    encode_hex(&bytes)
}

fn parse_fp_le(s: &str) -> Option<Fingerprint256> {
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

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
