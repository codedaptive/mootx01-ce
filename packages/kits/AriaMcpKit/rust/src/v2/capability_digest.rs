//! Canonical, build-independent capability digests for the ARIA v2 surface.
//!
//! This module deliberately accepts data-only operation definitions.  The
//! selected registry owns conversion from its descriptors and will wire that
//! conversion later; keeping this core free of registry imports avoids making
//! the digest depend on a build id or other runtime state.

use serde_json::Value;
use sha2::{Digest, Sha256};

use super::{
    operation::{V2OperationDescriptor, V2OperationEffect},
    registry::V2EffectiveRegistry,
};

/// The externally visible effect that contributes to a capability digest.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapabilityEffect {
    Read,
    Write,
}

impl CapabilityEffect {
    fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Write => "write",
        }
    }
}

/// Stable operation material supplied by the effective selected registry.
///
/// `availability` is the effective visibility decision, rather than the
/// volatile feature/lane inputs used to make it.  `help` and
/// `recipe_bindings` are optional for descriptors that do not support them;
/// their presence or absence is still represented canonically.
#[derive(Debug, Clone, PartialEq)]
pub struct CapabilityOperationDefinition {
    pub identity: String,
    pub name: String,
    pub effect: CapabilityEffect,
    pub availability: bool,
    pub input_schema: Value,
    pub output_schema: Value,
    pub help: Option<Value>,
    pub recipe_bindings: Vec<String>,
}

/// Return canonical JSON bytes for one arbitrary JSON value.
///
/// Object keys are sorted lexicographically at every depth. Arrays retain
/// their declared order because schema tuples and examples can be ordered.
pub fn canonical_json_bytes(value: &Value) -> Vec<u8> {
    let mut output = Vec::new();
    write_canonical_json(value, &mut output);
    output
}

/// Return the canonical material for effective callable operations.
///
/// Definitions are sorted by public name and then by their complete canonical
/// representation, which makes the result independent of catalog insertion
/// order while remaining deterministic for malformed duplicate names. Build
/// identity and all other runtime-only fields are intentionally absent.
pub fn canonical_capability_bytes(
    definitions: &[CapabilityOperationDefinition],
) -> Vec<u8> {
    let mut operations: Vec<(String, Vec<u8>)> = definitions
        .iter()
        .map(|definition| {
            (
                definition.name.clone(),
                canonical_operation_bytes(definition),
            )
        })
        .collect();
    operations.sort_by(|left, right| {
        left.0
            .cmp(&right.0)
            .then_with(|| left.1.cmp(&right.1))
    });

    let mut output = Vec::from(&b"{\"operations\":["[..]);
    for (index, (_, operation)) in operations.iter().enumerate() {
        if index > 0 {
            output.push(b',');
        }
        output.extend_from_slice(operation);
    }
    output.extend_from_slice(b"]}");
    output
}

/// Produce the lowercase SHA-256 digest for the effective capability contract.
pub fn capability_digest(definitions: &[CapabilityOperationDefinition]) -> String {
    let digest = Sha256::digest(canonical_capability_bytes(definitions));
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Hash the effective callable definitions selected by one registry. Runtime
/// selection inputs such as build id remain outside the material.
pub fn registry_capability_digest(registry: &V2EffectiveRegistry) -> String {
    let definitions = registry
        .operations()
        .map(CapabilityOperationDefinition::from)
        .collect::<Vec<_>>();
    capability_digest(&definitions)
}

impl From<&V2OperationDescriptor> for CapabilityOperationDefinition {
    fn from(descriptor: &V2OperationDescriptor) -> Self {
        let effect = match descriptor.effect {
            V2OperationEffect::Read => CapabilityEffect::Read,
            V2OperationEffect::Write => CapabilityEffect::Write,
        };
        Self {
            identity: descriptor.identity.clone(),
            name: descriptor.public_name.clone(),
            effect,
            availability: true,
            input_schema: descriptor.input_schema.clone(),
            output_schema: descriptor.projection.output_schema.clone(),
            help: Some(serde_json::json!({
                "description": descriptor.help.description,
                "example": descriptor.help.example,
                "intents": descriptor.help.intents,
            })),
            recipe_bindings: descriptor.recipe_bindings.clone(),
        }
    }
}

fn canonical_operation_bytes(definition: &CapabilityOperationDefinition) -> Vec<u8> {
    let mut output = Vec::from(&b"{\"availability\":"[..]);
    output.extend_from_slice(if definition.availability { b"true" } else { b"false" });
    output.extend_from_slice(b",\"effect\":");
    write_json_string(definition.effect.as_str(), &mut output);
    output.extend_from_slice(b",\"help\":");
    match &definition.help {
        Some(help) => write_canonical_json(help, &mut output),
        None => output.extend_from_slice(b"null"),
    }
    output.extend_from_slice(b",\"identity\":");
    write_json_string(&definition.identity, &mut output);
    output.extend_from_slice(b",\"input_schema\":");
    write_canonical_json(&definition.input_schema, &mut output);
    output.extend_from_slice(b",\"name\":");
    write_json_string(&definition.name, &mut output);
    output.extend_from_slice(b",\"output_schema\":");
    write_canonical_json(&definition.output_schema, &mut output);
    output.extend_from_slice(b",\"recipe_bindings\":[");
    let mut bindings = definition.recipe_bindings.iter().collect::<Vec<_>>();
    bindings.sort();
    for (index, binding) in bindings.into_iter().enumerate() {
        if index > 0 {
            output.push(b',');
        }
        write_json_string(binding, &mut output);
    }
    output.extend_from_slice(b"]}");
    output
}

fn write_canonical_json(value: &Value, output: &mut Vec<u8>) {
    match value {
        Value::Null => output.extend_from_slice(b"null"),
        Value::Bool(value) => output.extend_from_slice(if *value { b"true" } else { b"false" }),
        Value::Number(value) => output.extend_from_slice(value.to_string().as_bytes()),
        Value::String(value) => write_json_string(value, output),
        Value::Array(values) => {
            output.push(b'[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                write_canonical_json(value, output);
            }
            output.push(b']');
        }
        Value::Object(values) => {
            let mut entries: Vec<_> = values.iter().collect();
            entries.sort_by(|left, right| left.0.cmp(right.0));
            output.push(b'{');
            for (index, (key, value)) in entries.into_iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                write_json_string(key, output);
                output.push(b':');
                write_canonical_json(value, output);
            }
            output.push(b'}');
        }
    }
}

fn write_json_string(value: &str, output: &mut Vec<u8>) {
    serde_json::to_writer(output, value).expect("writing JSON into Vec cannot fail");
}
