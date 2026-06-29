// src/primitives/merkle_commitment.rs
//
// Canonical Merkle/commitment vectors for NT-P0. Mirrors the Swift
// MerkleCommitmentPrimitive and validates the byte contract in
// substrate-kernel.

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, encode_hex, f32_hex, u32_hex},
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_kernel::merkle_commitment::{
    self, MerkleChild, MerkleVectorPayload,
};
use substrate_types::MerkleRoot;

pub struct MerkleCommitmentPrimitive;

impl MerkleCommitmentPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "merkle_commitment",
            cookbook_section: "NT-P0",
            reference_file: "SubstrateKernel/MerkleCommitment.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let cases = canonical_cases()?;
        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases {
            encode_output(&c.expected_output, &mut encoder)?;
        }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "merkle_commitment".to_string(),
            cookbook_section: "NT-P0".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "SubstrateKernel/MerkleCommitment.rs".to_string(),
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

fn canonical_cases() -> Result<Vec<VectorCase>, PrimitiveError> {
    let leaf_plain_id = uuid_hex("11111111111141118111111111111111")?;
    let leaf_vector_id = uuid_hex("22222222222242228222222222222222")?;
    let tombstone_id = uuid_hex("33333333333343338333333333333333")?;

    let zeta_values = [3.5f32, -0.0];
    let alpha_one_values = [1.25f32, -2.5, 0.0];
    let alpha_zero_values = [0.5f32];
    let vectors = vec![
        MerkleVectorPayload::new("zeta-v1", 2, &zeta_values),
        MerkleVectorPayload::new("alpha-v1", 1, &alpha_one_values),
        MerkleVectorPayload::new("alpha-v1", 0, &alpha_zero_values),
    ];

    let plain_payload = merkle_commitment::canonical_leaf_payload(
        leaf_plain_id,
        b"hello moot",
        &[],
    );
    let vector_payload = merkle_commitment::canonical_leaf_payload(
        leaf_vector_id,
        "Caf\u{00E9}".as_bytes(),
        &vectors,
    );
    let plain_digest = merkle_commitment::hash_leaf_payload(&plain_payload).wire_bytes();
    let vector_digest = merkle_commitment::hash_leaf_payload(&vector_payload).wire_bytes();

    let child_low = uuid_hex("00000000000040008000000000000001")?;
    let child_high = uuid_hex("ffffffffffff4fff8fffffffffffffff")?;
    let interior_root = merkle_commitment::interior_root(&[
        MerkleChild::new(child_high, MerkleRoot::new(vector_digest)),
        MerkleChild::new(child_low, MerkleRoot::new(plain_digest)),
    ]);
    let tombstone = merkle_commitment::tombstone_hash(tombstone_id);
    let key = b"nt-p0 canonical key".to_vec();
    let commitment = merkle_commitment::keyed_commitment_for_canonical_leaf_payload(
        &vector_payload,
        &key,
        7,
    );

    Ok(vec![
        VectorCase {
            id: "leaf_empty_vectors".to_string(),
            description: "leaf hash with NFC content and zero vectors".to_string(),
            inputs: leaf_inputs("leaf", leaf_plain_id, "hello moot", &[]),
            expected_output: digest_output(&plain_digest),
        },
        VectorCase {
            id: "leaf_vector_order".to_string(),
            description: "leaf hash with vectors sorted by modelID bytes then vectorIndex".to_string(),
            inputs: leaf_inputs("leaf", leaf_vector_id, "Caf\u{00E9}", &vectors),
            expected_output: digest_output(&vector_digest),
        },
        VectorCase {
            id: "interior_sorted_children".to_string(),
            description: "interior root with children sorted by raw UUID bytes".to_string(),
            inputs: {
                let mut obj = BTreeMap::new();
                obj.insert("op".to_string(), JsonValue::String("interior".to_string()));
                obj.insert(
                    "children".to_string(),
                    JsonValue::Array(vec![
                        JsonValue::Object(child_input(child_high, MerkleRoot::new(vector_digest))),
                        JsonValue::Object(child_input(child_low, MerkleRoot::new(plain_digest))),
                    ]),
                );
                obj
            },
            expected_output: digest_output(interior_root.as_bytes()),
        },
        VectorCase {
            id: "tombstone".to_string(),
            description: "tombstone hash over domain tag and drawer id".to_string(),
            inputs: {
                let mut obj = BTreeMap::new();
                obj.insert("op".to_string(), JsonValue::String("tombstone".to_string()));
                obj.insert("drawer_id".to_string(), JsonValue::String(encode_hex(&tombstone_id)));
                obj
            },
            expected_output: digest_output(tombstone.as_bytes()),
        },
        VectorCase {
            id: "empty_root".to_string(),
            description: "empty subtree root over the empty-root domain tag".to_string(),
            inputs: {
                let mut obj = BTreeMap::new();
                obj.insert("op".to_string(), JsonValue::String("empty_root".to_string()));
                obj
            },
            expected_output: digest_output(merkle_commitment::empty_root().as_bytes()),
        },
        VectorCase {
            id: "keyed_commitment".to_string(),
            description: "HMAC commitment over the canonical leaf payload with key version".to_string(),
            inputs: keyed_inputs(leaf_vector_id, "Caf\u{00E9}", &vectors, &key, 7),
            expected_output: {
                let mut obj = BTreeMap::new();
                obj.insert("digest".to_string(), JsonValue::String(encode_hex(commitment.as_bytes())));
                obj.insert("key_version".to_string(), JsonValue::String(u32_hex(commitment.key_version)));
                obj
            },
        },
    ])
}

fn validate_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let op = match c.inputs.get("op") {
        Some(JsonValue::String(op)) => op.as_str(),
        _ => return fail(c, "missing op"),
    };

    let computed: Result<([u8; 32], Option<u32>), PrimitiveError> = match op {
        "leaf" => {
            let payload = leaf_payload(&c.inputs);
            payload.map(|p| (merkle_commitment::hash_leaf_payload(&p).wire_bytes(), None))
        }
        "interior" => interior_root(&c.inputs).map(|r| (r.wire_bytes(), None)),
        "tombstone" => require_uuid(&c.inputs, "drawer_id")
            .map(|id| (merkle_commitment::tombstone_hash(id).wire_bytes(), None)),
        "empty_root" => Ok((merkle_commitment::empty_root().wire_bytes(), None)),
        "keyed_commitment" => {
            let payload = leaf_payload(&c.inputs);
            let key = require_hex(&c.inputs, "key");
            let version = require_u32(&c.inputs, "key_version");
            match (payload, key, version) {
                (Ok(payload), Ok(key), Ok(version)) => {
                    let commitment =
                        merkle_commitment::keyed_commitment_for_canonical_leaf_payload(
                            &payload,
                            &key,
                            version,
                        );
                    Ok((commitment.wire_bytes(), Some(commitment.key_version)))
                }
                (Err(e), _, _) | (_, Err(e), _) | (_, _, Err(e)) => Err(e),
            }
        }
        other => return fail(c, &format!("unknown op {other}")),
    };

    let (actual_digest, actual_version) = match computed {
        Ok(v) => v,
        Err(e) => return fail(c, &e.to_string()),
    };

    if let Err(e) = encode_digest(&actual_digest, actual_version, encoder) {
        return fail(c, &format!("actual output encode failed: {e}"));
    }

    let expected_digest = match require_digest(&c.expected_output, "digest") {
        Ok(v) => v,
        Err(e) => return fail(c, &format!("missing or malformed expected digest: {e}")),
    };
    if actual_digest != expected_digest {
        return fail(
            c,
            &format!(
                "digest mismatch: expected {}, got {}",
                encode_hex(&expected_digest),
                encode_hex(&actual_digest)
            ),
        );
    }

    if let Some(version) = actual_version {
        let expected = match require_u32(&c.expected_output, "key_version") {
            Ok(v) => v,
            Err(e) => return fail(c, &format!("missing or malformed expected key_version: {e}")),
        };
        if version != expected {
            return fail(c, &format!("key_version mismatch: expected {expected}, got {version}"));
        }
    }

    CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
}

fn leaf_payload(inputs: &JsonObject) -> Result<Vec<u8>, PrimitiveError> {
    let drawer_id = require_uuid(inputs, "drawer_id")?;
    let content = match inputs.get("content") {
        Some(JsonValue::String(s)) => s.as_str(),
        _ => return Err(PrimitiveError("missing content".to_string())),
    };
    let vectors = parse_vectors(inputs.get("vectors").unwrap_or(&JsonValue::Array(vec![])))?;
    Ok(merkle_commitment::canonical_leaf_payload(
        drawer_id,
        content.as_bytes(),
        &vectors,
    ))
}

fn interior_root(inputs: &JsonObject) -> Result<MerkleRoot, PrimitiveError> {
    let arr = match inputs.get("children") {
        Some(JsonValue::Array(arr)) => arr,
        _ => return Err(PrimitiveError("missing children".to_string())),
    };
    let mut children = Vec::with_capacity(arr.len());
    for child in arr {
        let obj = match child {
            JsonValue::Object(obj) => obj,
            _ => return Err(PrimitiveError("child is not an object".to_string())),
        };
        children.push(MerkleChild::new(
            require_uuid(obj, "child_id")?,
            MerkleRoot::new(require_digest(obj, "root")?),
        ));
    }
    Ok(merkle_commitment::interior_root(&children))
}

fn leaf_inputs(
    op: &str,
    drawer_id: [u8; 16],
    content: &str,
    vectors: &[MerkleVectorPayload<'_>],
) -> JsonObject {
    let mut obj = BTreeMap::new();
    obj.insert("op".to_string(), JsonValue::String(op.to_string()));
    obj.insert("drawer_id".to_string(), JsonValue::String(encode_hex(&drawer_id)));
    obj.insert("content".to_string(), JsonValue::String(content.to_string()));
    obj.insert(
        "vectors".to_string(),
        JsonValue::Array(vectors.iter().map(|v| JsonValue::Object(vector_input(v))).collect()),
    );
    obj
}

fn keyed_inputs(
    drawer_id: [u8; 16],
    content: &str,
    vectors: &[MerkleVectorPayload<'_>],
    key: &[u8],
    key_version: u32,
) -> JsonObject {
    let mut obj = leaf_inputs("keyed_commitment", drawer_id, content, vectors);
    obj.insert("key".to_string(), JsonValue::String(encode_hex(key)));
    obj.insert("key_version".to_string(), JsonValue::String(u32_hex(key_version)));
    obj
}

fn vector_input(vector: &MerkleVectorPayload<'_>) -> JsonObject {
    let mut obj = BTreeMap::new();
    obj.insert("model_id".to_string(), JsonValue::String(vector.model_id.to_string()));
    obj.insert("vector_index".to_string(), JsonValue::String(u32_hex(vector.vector_index)));
    obj.insert(
        "values".to_string(),
        JsonValue::Array(
            vector
                .values
                .iter()
                .map(|v| JsonValue::String(f32_hex(*v)))
                .collect(),
        ),
    );
    obj
}

fn child_input(child_id: [u8; 16], root: MerkleRoot) -> JsonObject {
    let mut obj = BTreeMap::new();
    obj.insert("child_id".to_string(), JsonValue::String(encode_hex(&child_id)));
    obj.insert("root".to_string(), JsonValue::String(encode_hex(root.as_bytes())));
    obj
}

fn digest_output(digest: &[u8]) -> JsonObject {
    let mut obj = BTreeMap::new();
    obj.insert("digest".to_string(), JsonValue::String(encode_hex(digest)));
    obj
}

fn parse_vectors(value: &JsonValue) -> Result<Vec<MerkleVectorPayload<'static>>, PrimitiveError> {
    let arr = match value {
        JsonValue::Array(arr) => arr,
        _ => return Err(PrimitiveError("vectors must be an array".to_string())),
    };
    let mut out = Vec::with_capacity(arr.len());
    for item in arr {
        let obj = match item {
            JsonValue::Object(obj) => obj,
            _ => return Err(PrimitiveError("vector is not an object".to_string())),
        };
        let model_id = match obj.get("model_id") {
            Some(JsonValue::String(s)) => s.clone(),
            _ => return Err(PrimitiveError("vector missing model_id".to_string())),
        };
        let vector_index = require_u32(obj, "vector_index")?;
        let raw_values = match obj.get("values") {
            Some(JsonValue::Array(values)) => values,
            _ => return Err(PrimitiveError("vector missing values".to_string())),
        };
        let mut values = Vec::with_capacity(raw_values.len());
        for value in raw_values {
            let hex = match value {
                JsonValue::String(s) => s,
                _ => return Err(PrimitiveError("vector value is not hex".to_string())),
            };
            values.push(parse_f32(hex).ok_or_else(|| PrimitiveError("malformed f32".to_string()))?);
        }
        let leaked_model: &'static str = Box::leak(model_id.into_boxed_str());
        let leaked_values: &'static [f32] = Box::leak(values.into_boxed_slice());
        out.push(MerkleVectorPayload::new(leaked_model, vector_index, leaked_values));
    }
    Ok(out)
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) -> Result<(), PrimitiveError> {
    let digest = require_digest(output, "digest")?;
    let version = if output.contains_key("key_version") {
        Some(require_u32(output, "key_version")?)
    } else {
        None
    };
    encode_digest(&digest, version, encoder)
}

fn encode_digest(
    digest: &[u8; 32],
    key_version: Option<u32>,
    encoder: &mut CanonicalBinaryEncoder,
) -> Result<(), PrimitiveError> {
    encoder.write_bytes(digest);
    if let Some(version) = key_version {
        encoder.write_u32(version);
    }
    Ok(())
}

fn require_uuid(obj: &JsonObject, key: &str) -> Result<[u8; 16], PrimitiveError> {
    let bytes = require_hex(obj, key)?;
    if bytes.len() != 16 {
        return Err(PrimitiveError(format!("{key} must be 16 bytes")));
    }
    let mut out = [0u8; 16];
    out.copy_from_slice(&bytes);
    Ok(out)
}

fn require_digest(obj: &JsonObject, key: &str) -> Result<[u8; 32], PrimitiveError> {
    let bytes = require_hex(obj, key)?;
    if bytes.len() != 32 {
        return Err(PrimitiveError(format!("{key} must be 32 bytes")));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

fn require_hex(obj: &JsonObject, key: &str) -> Result<Vec<u8>, PrimitiveError> {
    let hex = match obj.get(key) {
        Some(JsonValue::String(hex)) => hex,
        _ => return Err(PrimitiveError(format!("missing {key}"))),
    };
    decode_hex(hex).map_err(|e| PrimitiveError(e.to_string()))
}

fn require_u32(obj: &JsonObject, key: &str) -> Result<u32, PrimitiveError> {
    let hex = match obj.get(key) {
        Some(JsonValue::String(hex)) => hex,
        _ => return Err(PrimitiveError(format!("missing {key}"))),
    };
    parse_u32(hex).ok_or_else(|| PrimitiveError(format!("malformed {key}")))
}

fn parse_u32(hex: &str) -> Option<u32> {
    let bytes = decode_hex(hex).ok()?;
    if bytes.len() != 4 {
        return None;
    }
    let mut out = 0u32;
    for (i, b) in bytes.iter().enumerate() {
        out |= (*b as u32) << (i * 8);
    }
    Some(out)
}

fn parse_f32(hex: &str) -> Option<f32> {
    parse_u32(hex).map(f32::from_bits)
}

fn uuid_hex(hex: &str) -> Result<[u8; 16], PrimitiveError> {
    let bytes = decode_hex(hex).map_err(|e| PrimitiveError(e.to_string()))?;
    if bytes.len() != 16 {
        return Err(PrimitiveError("uuid literal must be 16 bytes".to_string()));
    }
    let mut out = [0u8; 16];
    out.copy_from_slice(&bytes);
    Ok(out)
}

fn fail(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult {
        id: c.id.clone(),
        passed: false,
        diagnostic: Some(msg.to_string()),
    }
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

#[derive(Debug, Clone)]
struct PrimitiveError(String);

impl std::fmt::Display for PrimitiveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for PrimitiveError {}
