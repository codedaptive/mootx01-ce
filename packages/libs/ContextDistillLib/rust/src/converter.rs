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
//! V22's selectable recipe is retired. CompleteFormV6 is the complete-content
//! renderer; v23.2 remains an explicit older recipe.

use serde::{Deserialize, Serialize};

/// Identifies which converter produced a distillation record.
///
/// Mirrors Python's CONVERTER_VERSION / RULESET_VERSION / INTENT_SPAN_VERSION
/// constants in distill_plus_converter.py.  The enum is harness-facing; values
/// are stable identifiers, not implementation details.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContextDistillConverter {
    /// Complete-content format compaction; no passage selection or ordering.
    CompleteFormV6,

    /// The intent-span@v23.2 attributed peer-dialogue converter.
    ///
    /// Preserves v22 selection for all existing modes, adds strict named-peer
    /// transcript detection, and renders selected peer turns as attributed
    /// prose. Selection details carry a `rendering` key with value
    /// `"inline-attributed-prose"` when peer mode fires, `"source-exact"` otherwise.
    IntentSpanV23Attributed,
}

impl ContextDistillConverter {
    /// Stable composite identifier for this converter.
    ///
    /// CompleteFormV6: `"complete-form@complete-form-visible-v6"`.
    /// Mirrors Python: `f"{candidate}@{candidate_ruleset}"`.
    pub fn id(&self) -> &'static str {
        match self {
            Self::CompleteFormV6 => "complete-form@complete-form-visible-v6",
            Self::IntentSpanV23Attributed =>
                "intent-span-v23-attributed@intent-span-v23.2-attributed-prose",
        }
    }

    /// The `converter_version` string embedded in output records.
    ///
    /// Always `"distill-plus-v1"` for all current converters.
    /// Mirrors Python constant `CONVERTER_VERSION = "distill-plus-v1"`.
    pub fn converter_version(&self) -> &'static str {
        match self {
            Self::CompleteFormV6
                | Self::IntentSpanV23Attributed => "distill-plus-v1",
        }
    }

    /// The `ruleset_version` string embedded in output records.
    ///
    /// CompleteFormV6: `"complete-form-visible-v6"`.
    /// Mirrors Python INTENT_SPAN_VERSION / RULESET_VERSION.
    pub fn ruleset_version(&self) -> &'static str {
        match self {
            Self::CompleteFormV6 => "complete-form-visible-v6",
            Self::IntentSpanV23Attributed => "intent-span-v23.2-attributed-prose",
        }
    }

    /// The `schema_version` integer embedded in output records.
    ///
    /// Always `1` for all current converters.
    /// Mirrors Python `"schema_version": 1`.
    pub fn schema_version(&self) -> u32 {
        match self {
            Self::CompleteFormV6
                | Self::IntentSpanV23Attributed => 1,
        }
    }
}
