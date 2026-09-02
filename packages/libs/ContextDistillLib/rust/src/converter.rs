//! ContextDistillConverter — Rust port of the converter identity layer
//! from distill_plus_converter.py.
//!
//! The converter enum is the harness-facing identity token that lets
//! downstream consumers route outputs without inspecting content.
//! Version strings mirror the Python constants:
//!   CONVERTER_VERSION   = "distill-plus-v1"
//!   RULESET_VERSION     = "mechanical-v8-scoring-corrections"
//!   INTENT_SPAN_VERSION = "intent-span-v22-authority-closure"
//!
//! CDL-01 Part 5 adds IntentSpanV22 as the distiller variant.  The
//! `DistillPlusV1` variant retains the legacy identity for non-intent-span
//! candidates.

use serde::{Deserialize, Serialize};

/// Identifies which converter produced a distillation record.
///
/// Mirrors Python's CONVERTER_VERSION / RULESET_VERSION / INTENT_SPAN_VERSION
/// constants in distill_plus_converter.py.  The enum is harness-facing; values
/// are stable identifiers, not implementation details.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextDistillConverter {
    /// The "distill-plus-v1" converter with "mechanical-v8-scoring-corrections"
    /// ruleset (for p23-current, p23-core, freq-mmr candidates).
    DistillPlusV1,

    /// The intent-span@v22 authority-closure converter.
    ///
    /// Used for the "intent-span" candidate.  Mirrors:
    ///   CONVERTER_VERSION   = "distill-plus-v1"
    ///   INTENT_SPAN_VERSION = "intent-span-v22-authority-closure"
    ///   schema_version      = 1  (integer)
    ///   converter_id        = "intent-span@intent-span-v22-authority-closure"
    IntentSpanV22,
}

impl ContextDistillConverter {
    /// Stable composite identifier for this converter.
    ///
    /// For IntentSpanV22: `"intent-span@intent-span-v22-authority-closure"`.
    /// Mirrors Python: `f"{candidate}@{candidate_ruleset}"`.
    pub fn id(&self) -> &'static str {
        match self {
            Self::DistillPlusV1  => "distill-plus-v1",
            Self::IntentSpanV22  => "intent-span@intent-span-v22-authority-closure",
        }
    }

    /// The `converter_version` string embedded in output records.
    ///
    /// Always `"distill-plus-v1"` for all current converters.
    /// Mirrors Python constant `CONVERTER_VERSION = "distill-plus-v1"`.
    pub fn converter_version(&self) -> &'static str {
        match self {
            Self::DistillPlusV1 | Self::IntentSpanV22 => "distill-plus-v1",
        }
    }

    /// The `ruleset_version` string embedded in output records.
    ///
    /// For IntentSpanV22: `"intent-span-v22-authority-closure"`.
    /// For DistillPlusV1: `"mechanical-v8-scoring-corrections"`.
    /// Mirrors Python INTENT_SPAN_VERSION / RULESET_VERSION.
    pub fn ruleset_version(&self) -> &'static str {
        match self {
            Self::DistillPlusV1 => "mechanical-v8-scoring-corrections",
            Self::IntentSpanV22 => "intent-span-v22-authority-closure",
        }
    }

    /// The `schema_version` integer embedded in output records.
    ///
    /// Always `1` for all current converters.
    /// Mirrors Python `"schema_version": 1`.
    pub fn schema_version(&self) -> u32 {
        match self {
            Self::DistillPlusV1 | Self::IntentSpanV22 => 1,
        }
    }
}
