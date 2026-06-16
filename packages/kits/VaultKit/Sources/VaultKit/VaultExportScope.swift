import LocusKit

/// Controls which drawers are included in an export.
///
/// The scope maps to a `Filter` chain applied by `DrawerMapping.export`.
/// The recall evaluator supplies per-axis defaults for any axis not addressed
/// by the chain; each scope below addresses only the non-sensitivity axes it
/// cares about, letting the evaluator's defaults fill the rest.
///
/// ## Privacy-tier enforcement (ADR-007 Decision 2)
///
/// Sensitivity is NOT part of `filterChain` — the bulk channel enforces the
/// tier rules itself so exclusions are counted, never silent:
///
/// - **Secret tier** (`.secret`) NEVER rides bulk export, under every scope.
/// - **Private tier** (`.restricted`) is excluded by default; only the
///   explicit `.believedIncludingPrivate` scope includes it
///   (`includesPrivateTier`). The owner-key ceremony that authorizes
///   selecting that scope is v1.0-gold access-surface work; this scope is
///   the enforcement hook it will gate.
/// - **Normal tier** (`.normal` + `.elevated`) exports freely.
///
/// `DrawerMapping.export` recalls with an explicit
/// `.sensitivityAtMost(.secret)` filter (suppressing the evaluator's
/// implicit `.elevated` ceiling so every tier is visible), then partitions by
/// the ADR-007 tier predicates and reports per-tier exclusion counts.
///
/// ## Scope semantics
///
/// - `believed` (default): currently-believed drawers regardless of
///   confirmation state — the projection-of-my-estate semantics. Fixes
///   the confirmed-drop bug present when the filter was hard-coded to
///   `.unconfirmed` (confirmed drawers were silently excluded).
///
/// - `believedIncludingPrivate`: same selection as `believed`, plus
///   Private-tier (`.restricted`) drawers. The explicit opt-in for
///   private-tier bulk export. Secret is still excluded.
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
    /// level. Normal tier only (tier rules above).
    ///
    /// Filter chain:
    ///   `.currentlyBelieve, .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
    ///    .any([.trustworthy, .requiresConfirmation])`
    ///
    /// This is the default scope. It produces the same result as the old
    /// `.unconfirmed`-only export for unconfirmed drawers, and additionally
    /// includes confirmed drawers — fixing the confirmed-drop bug.
    case believed

    /// `believed` selection plus Private-tier (`.restricted`) drawers — the
    /// explicit scope option ADR-007 Decision 2 requires for private-tier
    /// bulk export. Secret tier is still never included.
    ///
    /// Filter chain: identical to `believed`; the tier widening happens in
    /// the bulk channel's partition (`includesPrivateTier`), not the chain.
    case believedIncludingPrivate = "believed-including-private"

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

    // MARK: - Privacy tier

    /// Whether this scope includes Private-tier (`.restricted`) drawers in
    /// bulk export. True only for the explicit `.believedIncludingPrivate`
    /// opt-in (ADR-007 Decision 2: Private tier is excluded from bulk
    /// channels by default). Secret tier is excluded regardless of scope.
    public var includesPrivateTier: Bool {
        self == .believedIncludingPrivate
    }

    // MARK: - Filter chain

    /// The `Filter` chain this scope maps to, as documented in each case.
    ///
    /// The chain is passed to `RecallFrame.filterChain` by
    /// `DrawerMapping.export` with `.sensitivityAtMost(.secret)` appended;
    /// the recall evaluator interprets the chain as an implicit AND.
    /// Per-axis defaults (trust, provenance) are supplied by the evaluator
    /// when the chain does not address an axis. Sensitivity is deliberately
    /// unaddressed here — the bulk channel enforces the ADR-007 tier rules
    /// after recall so per-tier exclusion counts are reported, never silent.
    public var filterChain: [Filter] {
        switch self {
        case .believed, .believedIncludingPrivate:
            // currently-believed ∧ ANY confirmation state ∧ ANY trust.
            // The two scopes differ only in the tier partition
            // (`includesPrivateTier`), not in the chain.
            return [
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                .any([.trustworthy, .requiresConfirmation]),
            ]
        case .exportable:
            // exportability==public ∧ currently-believed ∧ ANY confirmation.
            // Trust from evaluator default.
            return [
                .exportable,
                .currentlyBelieve,
                .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
            ]
        case .confirmed:
            // user-confirmed ∧ currently-believed.
            // Trust from evaluator default.
            return [.userConfirmed, .currentlyBelieve]
        case .unconfirmed:
            // unconfirmed ∧ currently-believed (the legacy capture-inbox behavior).
            // Trust from evaluator default.
            return [.unconfirmed, .currentlyBelieve]
        }
    }
}
