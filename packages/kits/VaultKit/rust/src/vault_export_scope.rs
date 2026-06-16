//! VaultExportScope — controls which drawers are included in an export.
//!
//! Mirrors Swift `VaultExportScope`. Each scope maps to a `Filter` chain
//! applied by `DrawerMapping::export`. The recall evaluator supplies
//! per-axis defaults for any axis not addressed by the chain.
//!
//! ## Privacy-tier enforcement (ADR-007 Decision 2)
//!
//! Sensitivity is NOT part of `filter_chain()` — the bulk channel enforces
//! the tier rules itself so exclusions are counted, never silent:
//!
//! - **Secret tier** (`Secret`) NEVER rides bulk export, under every scope.
//! - **Private tier** (`Restricted`) is excluded by default; only the
//!   explicit `BelievedIncludingPrivate` scope includes it
//!   (`includes_private_tier()`). The owner-key ceremony that authorizes
//!   selecting that scope is v1.0-gold access-surface work; this scope is
//!   the enforcement hook it will gate.
//! - **Normal tier** (`Normal` + `Elevated`) exports freely.
//!
//! `DrawerMapping::export` recalls with an explicit
//! `Filter::SensitivityAtMost(Secret)` appended (suppressing the
//! evaluator's implicit `Elevated` ceiling so every tier is visible), then
//! partitions by the ADR-007 tier predicates and reports per-tier
//! exclusion counts.

use locus_kit::filter::Filter;

/// Controls which drawers are included in an export. Mirrors Swift `VaultExportScope`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum VaultExportScope {
    /// Currently-believed drawers with any confirmation state and any trust
    /// level. Normal tier only (tier rules in the module doc).
    ///
    /// Filter chain:
    ///   `[CurrentlyBelieve, Any([UserConfirmed, Unconfirmed, AutomatedConfirmedOnly]),
    ///     Any([Trustworthy, RequiresConfirmation])]`
    ///
    /// This is the default scope. It produces the same result as the old
    /// `Unconfirmed`-only export for unconfirmed drawers, and additionally
    /// includes confirmed drawers — fixing the confirmed-drop bug.
    #[default]
    Believed,

    /// `Believed` selection plus Private-tier (`Restricted`) drawers — the
    /// explicit scope option ADR-007 Decision 2 requires for private-tier
    /// bulk export. Secret tier is still never included.
    ///
    /// Filter chain: identical to `Believed`; the tier widening happens in
    /// the bulk channel's partition (`includes_private_tier()`), not the
    /// chain.
    BelievedIncludingPrivate,

    /// Currently-believed drawers that are marked exportable (exportability
    /// == public_), with any confirmation state.
    ///
    /// Filter chain:
    ///   `[Exportable, CurrentlyBelieve, Any([UserConfirmed, Unconfirmed, AutomatedConfirmedOnly])]`
    Exportable,

    /// Currently-believed drawers that are user-confirmed.
    ///
    /// Filter chain: `[UserConfirmed, CurrentlyBelieve]`
    Confirmed,

    /// Currently-believed drawers that are unconfirmed (the capture inbox).
    ///
    /// Filter chain: `[Unconfirmed, CurrentlyBelieve]`
    ///
    /// This is the behavior the old hard-coded export produced. It is now
    /// an explicit named scope rather than the only option.
    Unconfirmed,
}

impl VaultExportScope {
    /// Whether this scope includes Private-tier (`Restricted`) drawers in
    /// bulk export. True only for the explicit `BelievedIncludingPrivate`
    /// opt-in (ADR-007 Decision 2: Private tier is excluded from bulk
    /// channels by default). Secret tier is excluded regardless of scope.
    /// Mirrors Swift `VaultExportScope.includesPrivateTier`.
    pub fn includes_private_tier(&self) -> bool {
        matches!(self, Self::BelievedIncludingPrivate)
    }

    /// The `Filter` chain this scope maps to.
    ///
    /// The chain is passed to `RecallFrame::filter_chain` by
    /// `DrawerMapping::export` with `Filter::SensitivityAtMost(Secret)`
    /// appended; the recall evaluator interprets the chain as an implicit
    /// AND. Per-axis defaults (trust, provenance) are supplied by the
    /// evaluator when the chain does not address an axis. Sensitivity is
    /// deliberately unaddressed here — the bulk channel enforces the
    /// ADR-007 tier rules after recall so per-tier exclusion counts are
    /// reported, never silent. Mirrors Swift `VaultExportScope.filterChain`.
    pub fn filter_chain(&self) -> Vec<Filter> {
        match self {
            // currently-believed ∧ ANY confirmation state ∧ ANY trust.
            // The two scopes differ only in the tier partition
            // (`includes_private_tier`), not in the chain.
            VaultExportScope::Believed | VaultExportScope::BelievedIncludingPrivate => vec![
                Filter::CurrentlyBelieve,
                Filter::Any(vec![
                    Filter::UserConfirmed,
                    Filter::Unconfirmed,
                    Filter::AutomatedConfirmedOnly,
                ]),
                Filter::Any(vec![Filter::Trustworthy, Filter::RequiresConfirmation]),
            ],
            VaultExportScope::Exportable => vec![
                // exportability==public ∧ currently-believed ∧ ANY confirmation.
                // Trust from evaluator default.
                Filter::Exportable,
                Filter::CurrentlyBelieve,
                Filter::Any(vec![
                    Filter::UserConfirmed,
                    Filter::Unconfirmed,
                    Filter::AutomatedConfirmedOnly,
                ]),
            ],
            VaultExportScope::Confirmed => vec![
                // user-confirmed ∧ currently-believed.
                // Trust from evaluator default.
                Filter::UserConfirmed,
                Filter::CurrentlyBelieve,
            ],
            VaultExportScope::Unconfirmed => vec![
                // unconfirmed ∧ currently-believed (the legacy capture-inbox behavior).
                // Trust from evaluator default.
                Filter::Unconfirmed,
                Filter::CurrentlyBelieve,
            ],
        }
    }

    /// Parse a scope from its string representation (same raw values as Swift).
    ///
    /// Returns `None` when the string does not match a known scope. The caller
    /// is responsible for producing a clear error to the user.
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "believed" => Some(Self::Believed),
            "believed-including-private" => Some(Self::BelievedIncludingPrivate),
            "exportable" => Some(Self::Exportable),
            "confirmed" => Some(Self::Confirmed),
            "unconfirmed" => Some(Self::Unconfirmed),
            _ => None,
        }
    }

    /// Return the string representation of this scope (same raw values as Swift).
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Believed => "believed",
            Self::BelievedIncludingPrivate => "believed-including-private",
            Self::Exportable => "exportable",
            Self::Confirmed => "confirmed",
            Self::Unconfirmed => "unconfirmed",
        }
    }

    /// All valid scope strings, for error message generation.
    pub fn all_strs() -> &'static [&'static str] {
        &[
            "believed",
            "believed-including-private",
            "exportable",
            "confirmed",
            "unconfirmed",
        ]
    }

    /// Every scope value, for exhaustive iteration in tests. Mirrors Swift
    /// `VaultExportScope.allCases`.
    pub fn all_cases() -> &'static [VaultExportScope] {
        &[
            Self::Believed,
            Self::BelievedIncludingPrivate,
            Self::Exportable,
            Self::Confirmed,
            Self::Unconfirmed,
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_believed() {
        assert_eq!(VaultExportScope::default(), VaultExportScope::Believed);
    }

    #[test]
    fn from_str_round_trips() {
        for scope in VaultExportScope::all_cases() {
            let s = scope.as_str();
            let parsed = VaultExportScope::from_str(s).expect("must parse back");
            assert_eq!(parsed, *scope);
        }
    }

    #[test]
    fn unknown_scope_returns_none() {
        assert!(VaultExportScope::from_str("bogus").is_none());
    }

    #[test]
    fn believed_chain_has_correct_length() {
        // [CurrentlyBelieve, Any([...3...]), Any([...2...])] = 3 elements.
        assert_eq!(VaultExportScope::Believed.filter_chain().len(), 3);
    }

    #[test]
    fn believed_including_private_chain_matches_believed() {
        // The opt-in scope differs only in the tier partition, not the chain.
        assert_eq!(
            VaultExportScope::BelievedIncludingPrivate.filter_chain(),
            VaultExportScope::Believed.filter_chain()
        );
    }

    #[test]
    fn unconfirmed_chain_has_correct_length() {
        // [Unconfirmed, CurrentlyBelieve] = 2 elements.
        assert_eq!(VaultExportScope::Unconfirmed.filter_chain().len(), 2);
    }

    #[test]
    fn only_the_explicit_scope_includes_private_tier() {
        for scope in VaultExportScope::all_cases() {
            assert_eq!(
                scope.includes_private_tier(),
                *scope == VaultExportScope::BelievedIncludingPrivate
            );
        }
    }
}
