//! CognitionKit's single recipe error type — Rust port of the Swift
//! `RecipeError` enum in
//! `CognitionKit/Sources/CognitionKit/RecipeError.swift`.
//!
//! The behavioural meaning of each case lives in COGNITIONKIT_SPEC § 5;
//! this is the shipped shape. `Display` strings mirror the Swift
//! `description` so a caller sees the same message across ports.

use crate::capability::NeuronKitCapability;
use std::fmt;

/// Errors raised by CognitionKit recipes and the decision core.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecipeError {
    /// A required NeuronKit capability is unavailable. Raised by
    /// `verify_capabilities` BEFORE any execution begins (spec § 2, B-5).
    MissingCapability(NeuronKitCapability),

    /// A recipe deriving competing branches got fewer inputs than the
    /// minimum it needs to run a meaningful comparison.
    InsufficientBranches { minimum: i64, provided: i64 },

    /// Two or more plans share a name. Plan names key the branch map and
    /// the confirmation step, so a duplicate would silently collide and
    /// leak a derived branch; the recipe rejects it before deriving any.
    DuplicatePlanName(String),

    /// A migration plan's branch silently lost at least one origin concept
    /// (its lost set was non-empty). Non-recoverable; promoting a
    /// disqualified branch raises this (spec C-5). `branch_id` is the
    /// string form of the branch UUID (estate-side identity; empty on the
    /// pure path where no branch exists).
    SilentConceptLoss {
        branch_id: String,
        lost_concepts: Vec<String>,
    },

    /// A tournament produced no rankable survivor (every branch
    /// disqualified, or the input set empty).
    TournamentNoWinner { disqualified_count: i64 },

    /// A recipe reached a step requiring explicit human confirmation and
    /// none was provided. Recipes never auto-confirm (spec B-3).
    UserConfirmationRequired { action: String },
}

impl fmt::Display for RecipeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RecipeError::MissingCapability(cap) => write!(
                f,
                "RecipeError.missingCapability: NeuronKit capability '{}' is not available; recipe cannot run.",
                cap.raw_value()
            ),
            RecipeError::InsufficientBranches { minimum, provided } => write!(
                f,
                "RecipeError.insufficientBranches: need at least {} branches, got {}.",
                minimum, provided
            ),
            RecipeError::DuplicatePlanName(name) => write!(
                f,
                "RecipeError.duplicatePlanName: plan name '{}' appears more than once; plan names must be unique.",
                name
            ),
            RecipeError::SilentConceptLoss {
                branch_id,
                lost_concepts,
            } => write!(
                f,
                "RecipeError.silentConceptLoss: branch {} lost {} concept(s): {}.",
                branch_id,
                lost_concepts.len(),
                lost_concepts.join(", ")
            ),
            RecipeError::TournamentNoWinner { disqualified_count } => write!(
                f,
                "RecipeError.tournamentNoWinner: no rankable survivor ({} branch(es) disqualified).",
                disqualified_count
            ),
            RecipeError::UserConfirmationRequired { action } => write!(
                f,
                "RecipeError.userConfirmationRequired: '{}' requires explicit human confirmation.",
                action
            ),
        }
    }
}

impl std::error::Error for RecipeError {}

/// A failure of a substrate operation behind the `RecipeSubstrate` seam
/// (derive / capture / benchmark / recall). Substrate-agnostic: the live
/// adapter maps the underlying GLK / estate error into `operation` +
/// `detail`; the deterministic test fake never errors. Swift's `RecipeError`
/// has no such case — its untyped `throws` lets the underlying error
/// propagate; this type is the Rust encoding of that propagated arm.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubstrateError {
    /// The seam operation that failed (e.g. "derive_branch", "capture",
    /// "benchmark", "recall").
    pub operation: String,
    /// Textual cause from the underlying substrate error.
    pub detail: String,
}

impl SubstrateError {
    /// Construct a substrate error from an operation name and any displayable
    /// underlying cause.
    pub fn new(operation: impl Into<String>, detail: impl Into<String>) -> Self {
        Self { operation: operation.into(), detail: detail.into() }
    }
}

impl fmt::Display for SubstrateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SubstrateError.{}: {}", self.operation, self.detail)
    }
}

impl std::error::Error for SubstrateError {}

/// The result of running a recipe: either a recipe-level `RecipeError` (the
/// closed, parity-gated guard set) or a propagated `SubstrateError`. This is
/// the Rust encoding of the Swift recipes' heterogeneous untyped `throws` —
/// `RecipeError` for the recipe's own guards, the underlying substrate error
/// otherwise. `RecipeError` stays closed and unchanged.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecipeRunError {
    /// A recipe-level guard failure (capability gate, duplicate plan, etc.).
    Recipe(RecipeError),
    /// A propagated substrate-operation failure.
    Substrate(SubstrateError),
}

impl From<RecipeError> for RecipeRunError {
    fn from(e: RecipeError) -> Self {
        RecipeRunError::Recipe(e)
    }
}

impl From<SubstrateError> for RecipeRunError {
    fn from(e: SubstrateError) -> Self {
        RecipeRunError::Substrate(e)
    }
}

impl fmt::Display for RecipeRunError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RecipeRunError::Recipe(e) => write!(f, "{e}"),
            RecipeRunError::Substrate(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for RecipeRunError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn descriptions_mirror_swift() {
        let e = RecipeError::DuplicatePlanName("same".into());
        let s = format!("{}", e);
        assert!(s.contains("duplicatePlanName"));
        assert!(s.contains("'same'"));

        let e2 = RecipeError::SilentConceptLoss {
            branch_id: "b1".into(),
            lost_concepts: vec!["a".into(), "b".into()],
        };
        let s2 = format!("{}", e2);
        assert!(s2.contains("silentConceptLoss"));
        assert!(s2.contains("2 concept"));

        let e3 = RecipeError::InsufficientBranches {
            minimum: 1,
            provided: 0,
        };
        assert!(format!("{}", e3).contains("at least 1 branches, got 0"));
    }
}
