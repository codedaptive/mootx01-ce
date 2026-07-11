//! CognitionKit's public error types — Rust versions of the Swift error types
//! in `CognitionKit/Sources/CognitionKit/`:
//!   - `RecipeError` (RecipeError.swift) — recipe guard failures
//!   - `SubstrateError` / `RecipeRunError` — substrate operation failures
//!   - `AnchorNotInRecalledSetError` (PartialCueRecall.swift:41) — the typed
//!     error raised when the anchor drawer is absent from the recalled set
//!
//! The behavioural meaning of each case lives in COGNITIONKIT_SPEC § 5;
//! this is the shipped shape. `Display` strings mirror the Swift
//! `description` / `localizedDescription` so a caller sees the same
//! message across versions.

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

    /// More migration plans than the recipe admits. Each plan derives a
    /// retained COW branch, so an unbounded plan count is a
    /// resource-exhaustion vector. Refused before any branch is derived.
    /// Mirrors Swift `RecipeError.tooManyPlans`.
    TooManyPlans { count: usize, maximum: usize },

    /// More origin entries than the recipe admits. Each entry is captured
    /// into every branch, so an unbounded corpus is O(plans × entries)
    /// work. Refused before any branch is derived. Mirrors Swift
    /// `RecipeError.tooManyOriginEntries`.
    TooManyOriginEntries { count: usize, maximum: usize },
}

/// DoS bounds on attacker-influenceable migration input. Mirror Swift
/// `MigrationBenchmark.maxPlans` / `maxOriginEntries`.
pub const MAX_MIGRATION_PLANS: usize = 20;
pub const MAX_MIGRATION_ORIGIN_ENTRIES: usize = 5000;

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
            RecipeError::TooManyPlans { count, maximum } => write!(
                f,
                "RecipeError.tooManyPlans: {} plans exceeds the maximum of {}.",
                count, maximum
            ),
            RecipeError::TooManyOriginEntries { count, maximum } => write!(
                f,
                "RecipeError.tooManyOriginEntries: {} origin entries exceeds the maximum of {}.",
                count, maximum
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
        Self {
            operation: operation.into(),
            detail: detail.into(),
        }
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

// ---------------------------------------------------------------------------
// AnchorNotInRecalledSetError
// ---------------------------------------------------------------------------

/// The cue pointed at nothing: `anchor_id` was not in the recalled set.
///
/// Rust nominal counterpart of the Swift `AnchorNotInRecalledSetError` struct
/// in `PartialCueRecall.swift:41`. When `run_partial_cue_recall` receives an
/// `anchor_id` that is not present in the drawers returned by the recall
/// frame, it raises this error (INTERFACE § 4 — Rust `SubstrateError` arm
/// encodes the Swift propagated-`throws` path).
///
/// The `Display` format mirrors the Swift `localizedDescription`:
/// `"AnchorNotInRecalledSetError: anchor drawer '{anchor_id}' not in recalled set"`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnchorNotInRecalledSetError {
    /// The anchor drawer id that was absent.
    pub anchor_id: String,
}

impl AnchorNotInRecalledSetError {
    /// Construct an error carrying the absent `anchor_id`.
    pub fn new(anchor_id: impl Into<String>) -> Self {
        Self {
            anchor_id: anchor_id.into(),
        }
    }
}

impl fmt::Display for AnchorNotInRecalledSetError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "AnchorNotInRecalledSetError: anchor drawer '{}' not in recalled set",
            self.anchor_id
        )
    }
}

impl std::error::Error for AnchorNotInRecalledSetError {}

#[cfg(test)]
mod tests {
    use super::*;

    // ── RecipeError case parity ───────────────────────────────────────────────

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

    #[test]
    fn all_six_recipe_error_cases_exist() {
        // Structural exhaustiveness check: this match covers every Rust
        // `RecipeError` variant. It is a Rust compile-time gate only — it does
        // not detect a Swift-only enum change. A Swift-side addition requires a
        // matching Rust case plus an update to this list.
        use crate::capability::NeuronKitCapability;
        let cases: Vec<RecipeError> = vec![
            RecipeError::MissingCapability(NeuronKitCapability::HybridRecall),
            RecipeError::InsufficientBranches {
                minimum: 2,
                provided: 1,
            },
            RecipeError::DuplicatePlanName("dup".into()),
            RecipeError::SilentConceptLoss {
                branch_id: "b1".into(),
                lost_concepts: vec!["x".into()],
            },
            RecipeError::TournamentNoWinner {
                disqualified_count: 3,
            },
            RecipeError::UserConfirmationRequired {
                action: "promote".into(),
            },
            RecipeError::TooManyPlans { count: 21, maximum: 20 },
            RecipeError::TooManyOriginEntries { count: 5001, maximum: 5000 },
        ];
        // Exhaustive match — compiler enforces that every arm is covered.
        for c in &cases {
            let _ = match c {
                RecipeError::MissingCapability(_) => "missingCapability",
                RecipeError::InsufficientBranches { .. } => "insufficientBranches",
                RecipeError::DuplicatePlanName(_) => "duplicatePlanName",
                RecipeError::SilentConceptLoss { .. } => "silentConceptLoss",
                RecipeError::TournamentNoWinner { .. } => "tournamentNoWinner",
                RecipeError::UserConfirmationRequired { .. } => "userConfirmationRequired",
                RecipeError::TooManyPlans { .. } => "tooManyPlans",
                RecipeError::TooManyOriginEntries { .. } => "tooManyOriginEntries",
            };
        }
        // Every description carries the Swift-matching case-name prefix.
        assert!(format!("{}", cases[0]).contains("missingCapability"));
        assert!(format!("{}", cases[1]).contains("insufficientBranches"));
        assert!(format!("{}", cases[2]).contains("duplicatePlanName"));
        assert!(format!("{}", cases[3]).contains("silentConceptLoss"));
        assert!(format!("{}", cases[4]).contains("tournamentNoWinner"));
        assert!(format!("{}", cases[5]).contains("userConfirmationRequired"));
        assert!(format!("{}", cases[6]).contains("tooManyPlans"));
        assert!(format!("{}", cases[7]).contains("tooManyOriginEntries"));
    }

    // ── SubstrateError ────────────────────────────────────────────────────────

    #[test]
    fn substrate_error_fields_and_description() {
        let err = SubstrateError::new("derive_branch", "estate locked");
        assert_eq!(err.operation, "derive_branch");
        assert_eq!(err.detail, "estate locked");
        // Description format: "SubstrateError.{op}: {detail}" — mirrors Swift.
        assert_eq!(
            format!("{}", err),
            "SubstrateError.derive_branch: estate locked"
        );
    }

    #[test]
    fn substrate_error_equatable() {
        let a = SubstrateError::new("recall", "timeout");
        let b = SubstrateError::new("recall", "timeout");
        let c = SubstrateError::new("capture", "timeout");
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    // ── RecipeRunError ────────────────────────────────────────────────────────

    #[test]
    fn recipe_run_error_recipe_arm() {
        let inner = RecipeError::DuplicatePlanName("plan-x".into());
        let err = RecipeRunError::Recipe(inner.clone());
        // Description delegates to the inner RecipeError — no extra prefix.
        assert_eq!(format!("{}", err), format!("{}", inner));
        assert!(format!("{}", err).contains("duplicatePlanName"));
    }

    #[test]
    fn recipe_run_error_substrate_arm() {
        let inner = SubstrateError::new("benchmark", "corpus empty");
        let err = RecipeRunError::Substrate(inner.clone());
        // Description delegates to SubstrateError.
        assert_eq!(format!("{}", err), format!("{}", inner));
        assert!(format!("{}", err).contains("SubstrateError.benchmark"));
    }

    #[test]
    fn recipe_run_error_from_recipe_error() {
        // `From<RecipeError> for RecipeRunError` — mirrors Swift's `init(_:)`.
        let inner = RecipeError::TournamentNoWinner {
            disqualified_count: 2,
        };
        let err: RecipeRunError = inner.clone().into();
        assert_eq!(err, RecipeRunError::Recipe(inner));
    }

    #[test]
    fn recipe_run_error_from_substrate_error() {
        // `From<SubstrateError> for RecipeRunError` — mirrors Swift's `init(_:)`.
        let inner = SubstrateError::new("recall", "index missing");
        let err: RecipeRunError = inner.clone().into();
        assert_eq!(err, RecipeRunError::Substrate(inner));
    }

    #[test]
    fn recipe_run_error_equatable() {
        let a = RecipeRunError::Recipe(RecipeError::TournamentNoWinner {
            disqualified_count: 2,
        });
        let b = RecipeRunError::Recipe(RecipeError::TournamentNoWinner {
            disqualified_count: 2,
        });
        let c = RecipeRunError::Recipe(RecipeError::TournamentNoWinner {
            disqualified_count: 3,
        });
        let d = RecipeRunError::Substrate(SubstrateError::new("x", "y"));
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_ne!(a, d);
    }

    #[test]
    fn recipe_run_error_exhaustive_match() {
        // Rust exhaustiveness check over RecipeRunError variants. Protects the
        // Rust enum only — a Swift-only variant addition does not produce a Rust
        // compile error; it requires a manual update to both the Rust enum and
        // this match.
        fn classify(e: &RecipeRunError) -> &'static str {
            match e {
                RecipeRunError::Recipe(_) => "recipe",
                RecipeRunError::Substrate(_) => "substrate",
            }
        }
        let r = RecipeRunError::Recipe(RecipeError::DuplicatePlanName("p".into()));
        let s = RecipeRunError::Substrate(SubstrateError::new("op", "d"));
        assert_eq!(classify(&r), "recipe");
        assert_eq!(classify(&s), "substrate");
    }

    // ── AnchorNotInRecalledSetError ───────────────────────────────────────────

    // CK-ERR-ANR-1: struct carries the anchor_id field.
    #[test]
    fn anchor_not_recalled_carries_anchor_id() {
        let err = AnchorNotInRecalledSetError::new("drawer-42");
        assert_eq!(err.anchor_id, "drawer-42");
    }

    // CK-ERR-ANR-2: Display format mirrors the Swift localizedDescription.
    #[test]
    fn anchor_not_recalled_display_mirrors_swift() {
        let err = AnchorNotInRecalledSetError::new("abc-123");
        let s = format!("{}", err);
        // Swift: "AnchorNotInRecalledSetError: anchor drawer '{id}' not in recalled set"
        assert!(s.contains("AnchorNotInRecalledSetError"), "missing type prefix: {s}");
        assert!(s.contains("abc-123"), "missing anchor_id: {s}");
        assert!(s.contains("not in recalled set"), "missing phrase: {s}");
    }

    // CK-ERR-ANR-3: equatable — same anchor_id compares equal.
    #[test]
    fn anchor_not_recalled_equatable() {
        let a = AnchorNotInRecalledSetError::new("x");
        let b = AnchorNotInRecalledSetError::new("x");
        let c = AnchorNotInRecalledSetError::new("y");
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    // CK-ERR-ANR-4: implements std::error::Error (compile-time check).
    #[test]
    fn anchor_not_recalled_is_error() {
        let err: Box<dyn std::error::Error> =
            Box::new(AnchorNotInRecalledSetError::new("id"));
        assert!(!format!("{}", err).is_empty());
    }
}
