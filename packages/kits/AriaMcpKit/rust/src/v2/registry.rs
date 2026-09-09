//! Effective v2 registry construction.
//!
//! This foundation intentionally has no production operation rows.  A later
//! owner supplies the shared-fixture census and owns the canonical digest
//! algorithm after its JSON rules are frozen across both ports.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{json, Value};

use super::operation::{
    V2AvailabilityInputs, V2DirectoryRecord, V2OperationDescriptor,
};

/// Source data for construction before availability filtering.
#[derive(Debug, Clone, Default)]
pub struct V2CatalogInput {
    pub operations: Vec<V2OperationDescriptor>,
    pub directory_records: Vec<V2DirectoryRecord>,
}

/// Stable material supplied to the later cross-port capability digest step.
#[derive(Debug, Clone, PartialEq)]
pub struct V2CapabilityDigestInput {
    pub build_id: String,
    pub visible_features: BTreeSet<String>,
    pub visible_lanes: BTreeSet<String>,
    pub operations: Vec<Value>,
}

impl V2CapabilityDigestInput {
    /// Deterministic value layout.  Hashing is intentionally deferred until
    /// the shared fixture owns canonical JSON number and key rules.
    pub fn canonical_material(&self) -> Value {
        json!({
            "build_id": self.build_id,
            "visible_features": self.visible_features,
            "visible_lanes": self.visible_lanes,
            "operations": self.operations,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum V2RegistryError {
    DuplicateIdentity(String),
    DuplicatePublicName(String),
    DuplicateDirectoryRecord(String),
}

impl std::fmt::Display for V2RegistryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::DuplicateIdentity(value) => write!(formatter, "duplicate v2 operation identity: {value}"),
            Self::DuplicatePublicName(value) => write!(formatter, "duplicate v2 public tool name: {value}"),
            Self::DuplicateDirectoryRecord(value) => write!(formatter, "duplicate v2 directory record: {value}"),
        }
    }
}

impl std::error::Error for V2RegistryError {}

/// The only callable and directory records visible to the selected surface.
#[derive(Debug, Clone)]
pub struct V2EffectiveRegistry {
    inputs: V2AvailabilityInputs,
    operations: BTreeMap<String, V2OperationDescriptor>,
    directory_records: BTreeMap<String, V2DirectoryRecord>,
}

impl V2EffectiveRegistry {
    pub fn build(
        input: V2CatalogInput,
        inputs: V2AvailabilityInputs,
    ) -> Result<Self, V2RegistryError> {
        let mut identities = BTreeSet::new();
        let mut operations = BTreeMap::new();
        for operation in input.operations {
            if !identities.insert(operation.identity.clone()) {
                return Err(V2RegistryError::DuplicateIdentity(operation.identity));
            }
            if !operation.availability.is_satisfied_by(&inputs) {
                continue;
            }
            if operations
                .insert(operation.public_name.clone(), operation.clone())
                .is_some()
            {
                return Err(V2RegistryError::DuplicatePublicName(operation.public_name));
            }
        }

        let mut directory_records = BTreeMap::new();
        for record in input.directory_records {
            if !record.availability.is_satisfied_by(&inputs) {
                continue;
            }
            if directory_records
                .insert(record.recipe_id.clone(), record.clone())
                .is_some()
            {
                return Err(V2RegistryError::DuplicateDirectoryRecord(record.recipe_id));
            }
        }

        Ok(Self {
            inputs,
            operations,
            directory_records,
        })
    }

    pub fn inputs(&self) -> &V2AvailabilityInputs {
        &self.inputs
    }

    /// Effective callable records only: directory records never enter tools/list.
    pub fn operations(&self) -> impl Iterator<Item = &V2OperationDescriptor> {
        self.operations.values()
    }

    pub fn operation(&self, public_name: &str) -> Option<&V2OperationDescriptor> {
        self.operations.get(public_name)
    }

    pub fn directory_records(&self) -> impl Iterator<Item = &V2DirectoryRecord> {
        self.directory_records.values()
    }

    pub fn digest_input(&self) -> V2CapabilityDigestInput {
        let operations = self
            .operations()
            .map(|operation| {
                json!({
                    "identity": operation.identity,
                    "public_name": operation.public_name,
                    "effect": operation.effect,
                    "input_schema": operation.input_schema,
                    "output_schema": operation.projection.output_schema,
                    "recipe_bindings": operation.recipe_bindings,
                })
            })
            .collect();
        V2CapabilityDigestInput {
            build_id: self.inputs.build_id.clone(),
            visible_features: self.inputs.enabled_features.clone(),
            visible_lanes: self.inputs.visible_lanes.clone(),
            operations,
        }
    }
}
