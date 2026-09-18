//! `RerankDirective` — the cross-encoder portion of a recall strategy
//! decision, carried on the recall request.
//!
//! It lives in CorpusKit so GeniusLocusKit (which consumes it) and the ARIA
//! surfaces (which will one day construct it) share one type. The directive
//! says WHETHER to rerank and WITH WHICH packaged profile; it carries no
//! benchmark type, gold answer, expected identifier or difficulty guess. An
//! absent directive means bypass.
//!
//! Mirror of Swift `RerankDirective.swift`.

use serde::{Deserialize, Serialize};

use super::cross_encoder_profile::CrossEncoderProfile;

/// The requested action.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RerankAction {
    /// Leave the recall order as fused; the stage does not run.
    Bypass,
    /// Run the pair scorer over the head of the final pool and fuse.
    Apply,
}

/// Execution contract for an apply request.  The default preserves the
/// best-effort stage used by ordinary recall; transcript recall asks for the
/// fail-closed source/span contract explicitly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum RerankRequirement {
    #[default]
    BestEffort,
    StrictTranscript,
}

/// Whether the recall request asks for cross-encoder reranking.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RerankDirective {
    /// Bypass or apply.
    pub action: RerankAction,
    /// The packaged profile to apply (`CrossEncoderProfile::model_id`). The
    /// stage degrades with reason `profile_unknown` when it names a profile
    /// this build does not package.
    #[serde(rename = "profile_id")]
    pub profile_id: String,
    /// Optional diagnostic code from whoever decided; echoed in the recall
    /// report, never interpreted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Whether a missing or degraded lower seam is an ordinary degradation or
    /// an operational unavailability for this request.
    #[serde(default, skip_serializing_if = "is_best_effort")]
    pub requirement: RerankRequirement,
}

fn is_best_effort(value: &RerankRequirement) -> bool {
    *value == RerankRequirement::BestEffort
}

impl RerankDirective {
    /// `apply` with the one qualified profile.
    pub fn apply(reason: Option<&str>) -> Self {
        Self {
            action: RerankAction::Apply,
            profile_id: CrossEncoderProfile::minilm_l6().model_id,
            reason: reason.map(str::to_string),
            requirement: RerankRequirement::BestEffort,
        }
    }

    /// `bypass` with the one qualified profile.
    pub fn bypass(reason: Option<&str>) -> Self {
        Self {
            action: RerankAction::Bypass,
            profile_id: CrossEncoderProfile::minilm_l6().model_id,
            reason: reason.map(str::to_string),
            requirement: RerankRequirement::BestEffort,
        }
    }

    /// The transcript operation's fixed recipe.  It is intentionally a
    /// distinct typed request: generic applies retain their degradation and
    /// fallback behaviour.
    pub fn strict_transcript(reason: Option<&str>) -> Self {
        Self {
            action: RerankAction::Apply,
            profile_id: CrossEncoderProfile::minilm_l6().model_id,
            reason: reason.map(str::to_string),
            requirement: RerankRequirement::StrictTranscript,
        }
    }

    pub fn is_strict_transcript(&self) -> bool {
        self.requirement == RerankRequirement::StrictTranscript
    }
}
