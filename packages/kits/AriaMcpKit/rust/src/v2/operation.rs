//! Typed, data-only v2 operation definitions.
//!
//! A descriptor owns every property that must remain in agreement for one
//! callable operation.  It deliberately contains no runner references: v2
//! dispatch will call typed services directly rather than parsing a legacy
//! runner's text or JSON output.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The externally visible effect of an operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum V2OperationEffect {
    Read,
    Write,
}

/// Build, lane, and capability inputs used to select a v2 catalog.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct V2AvailabilityInputs {
    pub build_id: String,
    pub enabled_features: BTreeSet<String>,
    pub visible_lanes: BTreeSet<String>,
    pub capabilities: BTreeSet<String>,
}

impl V2AvailabilityInputs {
    pub fn new(build_id: impl Into<String>) -> Self {
        Self {
            build_id: build_id.into(),
            ..Self::default()
        }
    }
}

/// Requirements that must all be present before an operation is visible.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct V2Availability {
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub required_features: BTreeSet<String>,
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub required_lanes: BTreeSet<String>,
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub required_capabilities: BTreeSet<String>,
}

impl V2Availability {
    pub fn is_satisfied_by(&self, inputs: &V2AvailabilityInputs) -> bool {
        self.required_features.is_subset(&inputs.enabled_features)
            && self.required_lanes.is_subset(&inputs.visible_lanes)
            && self.required_capabilities.is_subset(&inputs.capabilities)
    }
}

/// The projection contract for a typed operation result.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct V2ResultProjection {
    /// The data shape is operation-specific rather than a forced memory row.
    pub output_schema: Value,
    /// True when the result can produce compact text alongside structured data.
    pub compact_text: bool,
}

/// Typed help information owned by one operation descriptor.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct V2HelpMetadata {
    pub description: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub intents: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub example: Option<Value>,
}

/// Stable definition of one callable v2 operation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct V2OperationDescriptor {
    /// Stable implementation identity, distinct from the public tool name.
    pub identity: String,
    pub public_name: String,
    pub effect: V2OperationEffect,
    pub availability: V2Availability,
    pub input_schema: Value,
    pub projection: V2ResultProjection,
    pub help: V2HelpMetadata,
    /// Nonempty bindings are later included in the capability digest input.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub recipe_bindings: Vec<String>,
}

/// A help-directory record that is intentionally absent from `tools/list`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct V2DirectoryRecord {
    pub recipe_id: String,
    pub callable_tools: Vec<String>,
    pub availability: V2Availability,
    pub help: V2HelpMetadata,
}

impl V2DirectoryRecord {
    pub const CALLABLE: bool = false;
}
