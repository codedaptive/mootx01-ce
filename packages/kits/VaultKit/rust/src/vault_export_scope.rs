//! VaultExportScope — controls which drawers are included in an export.
//!
//! Mirrors Swift `VaultExportScope`. Each scope maps to a `Filter` chain
//! applied by `DrawerMapping::export`. The recall evaluator supplies
//! per-axis defaults for any axis not addressed by the chain.
//!
//! Sensitivity is intentionally left unaddressed in all scopes so the
//! evaluator applies its `.normal`-or-below default — export must never
//! surface elevated/restricted/secret content to a plaintext vault.

use locus_kit::filter::Filter;

/// Controls which drawers are included in an export. Mirrors Swift `VaultExportScope`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum VaultExportScope {
    /// Currently-believed drawers with any confirmation state and any trust
    /// level (sensitivity stays at the evaluator's `.normal` default).
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
    /// The `Filter` chain this scope maps to.
    ///
    /// The chain is passed directly to `RecallFrame::filter_chain`; the recall
    /// evaluator interprets it as an implicit AND. Per-axis defaults (trust,
    /// provenance) are supplied by the evaluator when the chain does not address
    /// an axis. Mirrors Swift `VaultExportScope.filterChain`.
    pub fn filter_chain(&self) -> Vec<Filter> {
        match self {
            VaultExportScope::Believed => vec![
                // currently-believed ∧ ANY confirmation state ∧ ANY trust.
                // Sensitivity ≤ normal comes from the evaluator default.
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
                // Trust and sensitivity from evaluator defaults.
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
                // Trust and sensitivity from evaluator defaults.
                Filter::UserConfirmed,
                Filter::CurrentlyBelieve,
            ],
            VaultExportScope::Unconfirmed => vec![
                // unconfirmed ∧ currently-believed (the legacy capture-inbox behavior).
                // Trust and sensitivity from evaluator defaults.
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
            Self::Exportable => "exportable",
            Self::Confirmed => "confirmed",
            Self::Unconfirmed => "unconfirmed",
        }
    }

    /// All valid scope strings, for error message generation.
    pub fn all_strs() -> &'static [&'static str] {
        &["believed", "exportable", "confirmed", "unconfirmed"]
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
        for scope in [
            VaultExportScope::Believed,
            VaultExportScope::Exportable,
            VaultExportScope::Confirmed,
            VaultExportScope::Unconfirmed,
        ] {
            let s = scope.as_str();
            let parsed = VaultExportScope::from_str(s).expect("must parse back");
            assert_eq!(parsed, scope);
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
    fn unconfirmed_chain_has_correct_length() {
        // [Unconfirmed, CurrentlyBelieve] = 2 elements.
        assert_eq!(VaultExportScope::Unconfirmed.filter_chain().len(), 2);
    }
}
