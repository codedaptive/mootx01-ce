import LocusKit

/// Controls which drawers are included in an export.
///
/// The scope maps to a `Filter` chain applied by `DrawerMapping.export`.
/// The recall evaluator supplies per-axis defaults for any axis not addressed
/// by the chain; each scope below is designed to address only the axes it
/// cares about, letting the evaluator's defaults fill the rest.
///
/// Sensitivity is intentionally left at the evaluator's `.normal` default
/// for every scope — vault export must never write sensitive content to a
/// plaintext file.
///
/// ## Scope semantics
///
/// - `believed` (default): currently-believed drawers regardless of
///   confirmation state — the projection-of-my-estate semantics. Fixes
///   the confirmed-drop bug present when the filter was hard-coded to
///   `.unconfirmed` (confirmed drawers were silently excluded).
///
/// - `exportable`: only drawers explicitly marked exportable (exportability
///   == .public_). A curated "safe to share" subset.
///
/// - `confirmed`: only user-confirmed currently-believed drawers. The
///   manually-reviewed portion of the estate.
///
/// - `unconfirmed`: the capture inbox — unconfirmed currently-believed
///   drawers. The legacy hard-coded behavior, now made explicit.
public enum VaultExportScope: String, Sendable, CaseIterable {

    /// Currently-believed drawers with any confirmation state and any trust
    /// level (sensitivity stays at the evaluator's `.normal` default).
    ///
    /// Filter chain:
    ///   `.currentlyBelieve, .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
    ///    .any([.trustworthy, .requiresConfirmation])`
    ///
    /// This is the default scope. It produces the same result as the old
    /// `.unconfirmed`-only export for unconfirmed drawers, and additionally
    /// includes confirmed drawers — fixing the confirmed-drop bug.
    case believed

    /// Currently-believed drawers that are marked exportable
    /// (exportability == .public_), with any confirmation state.
    ///
    /// Filter chain:
    ///   `.exportable, .currentlyBelieve,
    ///    .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly])`
    case exportable

    /// Currently-believed drawers that are user-confirmed.
    ///
    /// Filter chain: `.userConfirmed, .currentlyBelieve`
    case confirmed

    /// Currently-believed drawers that are unconfirmed (the capture inbox).
    ///
    /// Filter chain: `.unconfirmed, .currentlyBelieve`
    ///
    /// This is the behavior the old hard-coded export produced. It is now
    /// an explicit named scope rather than the only option.
    case unconfirmed

    // MARK: - Filter chain

    /// The `Filter` chain this scope maps to, as documented in each case.
    ///
    /// The chain is passed directly to `RecallFrame.filterChain`; the
    /// recall evaluator interprets it as an implicit AND. Per-axis defaults
    /// (trust, provenance) are supplied by the evaluator when the chain
    /// does not address an axis.
    ///
    /// Sensitivity is left unaddressed in all scopes so the evaluator
    /// applies its `.normal`-or-below default — export must never surface
    /// elevated/restricted/secret content to a plaintext vault.
    public var filterChain: [Filter] {
        switch self {
        case .believed:
            // currently-believed ∧ ANY confirmation state ∧ ANY trust.
            // Sensitivity ≤ normal comes from the evaluator default.
            return [
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                .any([.trustworthy, .requiresConfirmation]),
            ]
        case .exportable:
            // exportability==public ∧ currently-believed ∧ ANY confirmation.
            // Trust and sensitivity from evaluator defaults.
            return [
                .exportable,
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
            ]
        case .confirmed:
            // user-confirmed ∧ currently-believed.
            // Trust and sensitivity from evaluator defaults.
            return [.userConfirmed, .currentlyBelieve]
        case .unconfirmed:
            // unconfirmed ∧ currently-believed (the legacy capture-inbox behavior).
            // Trust and sensitivity from evaluator defaults.
            return [.unconfirmed, .currentlyBelieve]
        }
    }
}
