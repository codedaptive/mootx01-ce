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
