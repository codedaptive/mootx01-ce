//! Adjective bitmap axis enums. Ports the four axis enums from `Adjectives.swift`.
//!
//! Only the four backing axis enums are ported here — they are genuine
//! leaves. The `Drawer` accessors that decode them belong to the Drawer
//! type and live in `drawer_operational.rs` alongside the operational
//! accessors. All adjective-axis accessors are implemented: `state()` (bits
//! 0–5), `adjective_sensitivity()` (bits 6–11), `exportability()` (bits
//! 12–17), `trust()` (bits 18–23), plus the cluster predicates
//! `is_currently_believed()`, `is_knew_past()`, `is_terminal()`, the
//! obligation flags `dreaming_recalc_required()` (bit 26), and `sealed()` (bit 27).
//!
//! ## Adjective bitmap layout (per cookbook §2.3 / §2.8)
//!
//! F11 LocusKit cascade (2026-05-27): bumped from v0.35's 4-bit fields to
//! cookbook v0.6's 6-bit fields per I-15. Raw values switched to the
//! scale-gapped layout that makes the cluster predicate a single shift-mask:
//! `cluster(state) = (state >> 4) & 0x3`.
//!
//! ```text
//! bits 0–5   State                  (gradient, 10 cases per §2.3 / §2.8)
//! bits 6–11  AdjectiveSensitivity   (scale-gapped, raw 0/16/32/48)
//! bits 12–17 AdjectiveExportability (scale-gapped, raw 0/32)
//! bits 18–23 Trust                  (gradient, 7 cases at raw 0–6; ambient is NEW)
//! bit  24    State-extension flag   (cookbook §2.9 issue C2)
//! bit  25    Lineage-clustering flag (NEW in v0.6)
//! bit  26    Dreaming-recalc-required flag (obligation; F17 cascade)
//! bit  27    Sealed flag             (custody trust hint; 1 = sealed; 2026-05-28)
//! bits 28–63 reserved
//! ```
//!
//! The pattern matches `Provenance.swift` / `provenance.rs` exactly: named-enum
//! decoders extract each axis from a single `i64` column with a safe fallback to
//! the zero case when an unrecognised raw value appears (future-version rows).

// MARK: - State

/// State axis — where the row sits in the AI's epistemic timeline.
/// Lives in bits 0–5 of `Drawer.adjective_bitmap` (6 bits, 64 values;
/// 10 used at scale-gapped raws, 54 reserved). Per cookbook §2.3 / §2.8.
///
/// The 10 cases partition into three mathematical clusters per cookbook
/// §2.3, with boundaries at raws 0 / 16 / 32 so the cluster predicate
/// is a single shift-mask `(state >> 4) & 0x3`:
///
/// - Cluster A (active / becoming):       `Active`, `Pending`, `Contested`, `Accepted`
/// - Cluster B (superseded / historical): `Superseded`, `Decayed`, `Withdrawn`, `Expired`
/// - Cluster C (terminal):                `Rejected`, `Tombstoned`
///
/// F11 cascade (2026-05-27): `Accepted` moved from the v0.35 "terminal"
/// cluster to cookbook's Cluster A. Cookbook semantics: accepted is the
/// audit-grade endpoint of becoming-true belief, parallel to rejected /
/// tombstoned being endpoints of becoming-false / removed belief.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum State {
    // Cluster A — active / becoming.
    Active = 0,
    Pending = 1,
    Contested = 2,
    Accepted = 3,
    // Cluster B — superseded / historical (boundary at 16).
    Superseded = 16,
    Decayed = 17,
    Withdrawn = 18,
    Expired = 19,
    // Cluster C — terminal (boundary at 32).
    Rejected = 32,
    Tombstoned = 33,
    // Raw values 4–15, 20–31, 34–63 are reserved per cookbook §2.3
    // for per-cluster growth.
}

impl State {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `State::Active` for unrecognised raw
    /// values so retrieval filters that look for current beliefs fail closed
    /// (an unknown row is treated as currently believed and surfaces for
    /// review rather than silently disappearing). Matches the Swift fallback:
    /// `State(rawValue:) ?? .active`. Cookbook §2.3 scale-gapped raws.
    pub fn from_raw(v: i64) -> State {
        match v {
            // Cluster A
            0 => State::Active,
            1 => State::Pending,
            2 => State::Contested,
            3 => State::Accepted,
            // Cluster B
            16 => State::Superseded,
            17 => State::Decayed,
            18 => State::Withdrawn,
            19 => State::Expired,
            // Cluster C
            32 => State::Rejected,
            33 => State::Tombstoned,
            // Any other value (including reserved per-cluster gaps):
            // fail closed to Active.
            _ => State::Active,
        }
    }

    /// `true` if this state is in Cluster A (currently believed) per
    /// cookbook §2.3: Active, Pending, Contested, Accepted. Mirrors
    /// Swift `State.isClusterA`. Used by Bundle A materialization
    /// (§11.5 active centroid) and any recall path that wants the
    /// "currently believed" set.
    pub fn is_cluster_a(self) -> bool {
        matches!(
            self,
            State::Active | State::Pending | State::Contested | State::Accepted
        )
    }
}

// MARK: - Trust

/// Trust axis — how the substrate qualifies the row's reliability.
/// Lives in bits 18–23 of `Drawer.adjective_bitmap` (6 bits, 64 values;
/// 7 used at raw 0–6, 57 reserved). Per cookbook §2.3.
///
/// F11 cascade (2026-05-27): added `Ambient = 6` per cookbook §2.3
/// (NEW in v0.6, see §2.5 for the ambient-sample noun type that motivated
/// it). `Ord` ordering is unchanged — it still compares raw values, so
/// `Ambient` orders above `Proposed`.
///
/// `Ord` is derived from the raw-value ordering so retrieval-layer filters
/// such as `drawer.trust >= Trust::Canonical` compose without raw-value math.
/// Matches the Swift `Comparable` conformance backed by
/// `lhs.rawValue < rhs.rawValue`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(i64)]
pub enum Trust {
    Verbatim = 0,
    Observed = 1,
    Imported = 2,
    Canonical = 3,
    Derived = 4,
    Proposed = 5,
    Ambient = 6, // NEW in v0.6 per cookbook §2.3
                 // Raw values 7–63 are reserved for future trust tiers.
}

impl Trust {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `Trust::Verbatim` for unrecognised raw
    /// values; verbatim is the neutral baseline (unqualified content as filed).
    /// Matches the Swift fallback: `Trust(rawValue:) ?? .verbatim`.
    pub fn from_raw(v: i64) -> Trust {
        match v {
            0 => Trust::Verbatim,
            1 => Trust::Observed,
            2 => Trust::Imported,
            3 => Trust::Canonical,
            4 => Trust::Derived,
            5 => Trust::Proposed,
            6 => Trust::Ambient,
            // Raw values 7–63 and any other value: fall back to Verbatim.
            _ => Trust::Verbatim,
        }
    }
}

// MARK: - AdjectiveSensitivity

/// Sensitivity axis on the adjective bitmap — per-row access posture.
/// Lives in bits 6–11 of `Drawer.adjective_bitmap` (6 bits, 64 values).
/// Per cookbook §2.3 / §2.8.
///
/// Distinct from `Sensitivity` on the provenance bitmap (which is a
/// 2-bit contiguous encoding at bits 16–17 of the provenance column).
/// The adjective sensitivity uses a scale-gapped encoding: cases sit
/// at raw values 0/16/32/48 (cookbook §2.3) to leave generous room
/// for intermediate tiers without disturbing equality or ordering
/// masks.
///
/// The qualified type name (`AdjectiveSensitivity` rather than
/// `Sensitivity`) keeps both sensitivity surfaces visible on `Drawer`
/// without a type-name collision — same rationale as the Swift code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum AdjectiveSensitivity {
    /// Raw value 0 — default access posture.
    Normal = 0,
    /// Raw value 16 — cookbook §2.3 scale-gapped.
    Elevated = 16,
    /// Raw value 32 — cookbook §2.3 scale-gapped.
    Restricted = 32,
    /// Raw value 48 — cookbook §2.3 scale-gapped; maximum adjective sensitivity.
    Secret = 48,
}

impl AdjectiveSensitivity {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `AdjectiveSensitivity::Normal` for
    /// unrecognised raw values, matching the estate-level default access
    /// posture. Matches the Swift fallback: `AdjectiveSensitivity(rawValue:) ?? .normal`.
    pub fn from_raw(v: i64) -> AdjectiveSensitivity {
        match v {
            0 => AdjectiveSensitivity::Normal,
            16 => AdjectiveSensitivity::Elevated,
            32 => AdjectiveSensitivity::Restricted,
            48 => AdjectiveSensitivity::Secret,
            // Any raw value not matching a defined case (scale-gapped
            // intermediates and beyond-spec values) falls back to Normal.
            _ => AdjectiveSensitivity::Normal,
        }
    }

    // -------------------------------------------------------------------------
    // Privacy-tier predicates — ADR-007 Decision 2
    //
    // Three predicates record the normative mapping of the four sensitivity
    // values onto the three ADR-007 privacy tiers. The predicates are mutually
    // exclusive and collectively exhaustive: exactly one is `true` for every
    // variant. They are pure computed functions — no new fields, no new bitmap
    // bits, no schema changes.
    //
    // Tier mapping (four sensitivity values → three tiers):
    //   Normal  (raw  0) → Normal tier  — free bulk export
    //   Elevated(raw 16) → Normal tier  — free bulk export
    //   Restricted(raw 32) → Private tier — bulk requires owner-held key (v1.0)
    //   Secret  (raw 48) → Secret tier  — never rides bulk channels
    // -------------------------------------------------------------------------

    /// `true` for sensitivity values that belong to the **Normal tier**
    /// per ADR-007 Decision 2: `Normal` (raw 0) and `Elevated` (raw 16).
    ///
    /// Normal-tier drawers are eligible for free bulk export. VaultKit's
    /// export path consults this predicate to determine whether a drawer
    /// may ride a bulk channel without additional friction.
    ///
    /// Mirrors Swift `AdjectiveSensitivity.isBulkExportable`.
    pub fn is_bulk_exportable(self) -> bool {
        matches!(self, AdjectiveSensitivity::Normal | AdjectiveSensitivity::Elevated)
    }

    /// `true` for sensitivity values that belong to the **Private tier**
    /// per ADR-007 Decision 2: `Restricted` (raw 32).
    ///
    /// Private-tier drawers require an owner-held key at execution time before
    /// participating in bulk operations (v1.0 gold deliverable). By default
    /// they are excluded from bulk export; an explicit scope option in VaultKit
    /// may include them when the key ceremony is satisfied.
    ///
    /// Mirrors Swift `AdjectiveSensitivity.requiresOwnerKeyForBulk`.
    pub fn requires_owner_key_for_bulk(self) -> bool {
        matches!(self, AdjectiveSensitivity::Restricted)
    }

    /// `true` for sensitivity values that belong to the **Secret tier**
    /// per ADR-007 Decision 2: `Secret` (raw 48).
    ///
    /// Secret-tier drawers never ride bulk channels under any scope option.
    /// VaultKit's export path must reject secret-tier drawers regardless of
    /// any other scope configuration.
    ///
    /// Mirrors Swift `AdjectiveSensitivity.isExcludedFromBulk`.
    pub fn is_excluded_from_bulk(self) -> bool {
        matches!(self, AdjectiveSensitivity::Secret)
    }
}

// MARK: - AdjectiveExportability

/// Exportability axis — whether a row may leave the local estate.
/// Lives in bits 12–17 of `Drawer.adjective_bitmap` (6 bits, 64 values;
/// 2 used at raw 0 and 32, 62 reserved). Per cookbook §2.3.
///
/// Two cases at scale-gapped raw values 0 and 32 leave generous room
/// for intermediate tiers (e.g., a future `RestrictedShare` between
/// private and public) to slot in without disturbing existing
/// equality masks.
///
/// ## Naming
///
/// In Swift, `private` and `public` are reserved keywords, so the cases are
/// named `private_` and `public_` (trailing underscore). In Rust, `private`
/// and `public` are also reserved, so the cases use `Private` and `Public`
/// (idiomatic Rust PascalCase). The Swift origin names (`private_`, `public_`)
/// are preserved in this comment for cross-reference.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i64)]
pub enum AdjectiveExportability {
    /// Raw value 0. Swift name: `private_`. Non-exportable; content stays
    /// within the local estate.
    Private = 0,
    /// Raw value 32. Swift name: `public_`. Scale-gap of 32 from `Private`
    /// (cookbook §2.3) leaves generous room for intermediate tiers (e.g.,
    /// restricted share, redacted export) without changing existing wire values.
    Public = 32,
}

impl AdjectiveExportability {
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// Decode from a raw i64. Returns `AdjectiveExportability::Private` for
    /// unrecognised raw values — defaulting to non-exportable is the safe
    /// fallback for an unknown encoding. Matches the Swift fallback:
    /// `AdjectiveExportability(rawValue:) ?? .private_`.
    pub fn from_raw(v: i64) -> AdjectiveExportability {
        match v {
            0 => AdjectiveExportability::Private,
            32 => AdjectiveExportability::Public,
            // Any raw value not matching a defined case falls back to Private
            // (non-exportable is the safe default).
            _ => AdjectiveExportability::Private,
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // --- State raw values (bits 0–5, cookbook §2.3 scale-gapped) ---

    #[test]
    fn state_raw_values_match_cookbook_section_2_3() {
        // Cluster A — active / becoming.
        assert_eq!(State::Active.raw_value(), 0);
        assert_eq!(State::Pending.raw_value(), 1);
        assert_eq!(State::Contested.raw_value(), 2);
        assert_eq!(State::Accepted.raw_value(), 3);
        // Cluster B — superseded / historical.
        assert_eq!(State::Superseded.raw_value(), 16);
        assert_eq!(State::Decayed.raw_value(), 17);
        assert_eq!(State::Withdrawn.raw_value(), 18);
        assert_eq!(State::Expired.raw_value(), 19);
        // Cluster C — terminal.
        assert_eq!(State::Rejected.raw_value(), 32);
        assert_eq!(State::Tombstoned.raw_value(), 33);
    }

    #[test]
    fn state_roundtrip_all_ten_cases() {
        for v in [0i64, 1, 2, 3, 16, 17, 18, 19, 32, 33] {
            assert_eq!(
                State::from_raw(v).raw_value(),
                v,
                "round-trip failed for raw {v}"
            );
        }
    }

    /// Unknown / reserved raw values must fall back to Active — fail-closed
    /// so retrieval filters surface unknown rows for review.
    #[test]
    fn state_reserved_falls_back_to_active() {
        // Per-cluster gaps and beyond-spec values.
        for v in [4i64, 15, 20, 31, 34, 63, -1, 100] {
            assert_eq!(
                State::from_raw(v),
                State::Active,
                "expected Active fallback for raw {v}"
            );
        }
    }

    /// Cookbook §2.3 cluster predicate: `(state >> 4) & 0x3` resolves
    /// 0=Cluster A, 1=Cluster B, 2=Cluster C.
    #[test]
    fn state_cluster_predicate() {
        for s in [
            State::Active,
            State::Pending,
            State::Contested,
            State::Accepted,
        ] {
            assert_eq!(
                (s.raw_value() >> 4) & 0x3,
                0,
                "{s:?} should be in Cluster A"
            );
        }
        for s in [
            State::Superseded,
            State::Decayed,
            State::Withdrawn,
            State::Expired,
        ] {
            assert_eq!(
                (s.raw_value() >> 4) & 0x3,
                1,
                "{s:?} should be in Cluster B"
            );
        }
        for s in [State::Rejected, State::Tombstoned] {
            assert_eq!(
                (s.raw_value() >> 4) & 0x3,
                2,
                "{s:?} should be in Cluster C"
            );
        }
    }

    // --- Trust raw values + Ord (bits 18–23) ---

    #[test]
    fn trust_raw_values() {
        assert_eq!(Trust::Verbatim.raw_value(), 0);
        assert_eq!(Trust::Observed.raw_value(), 1);
        assert_eq!(Trust::Imported.raw_value(), 2);
        assert_eq!(Trust::Canonical.raw_value(), 3);
        assert_eq!(Trust::Derived.raw_value(), 4);
        assert_eq!(Trust::Proposed.raw_value(), 5);
        assert_eq!(Trust::Ambient.raw_value(), 6); // NEW in v0.6
    }

    #[test]
    fn trust_roundtrip_all_seven_cases() {
        for v in 0i64..=6 {
            assert_eq!(
                Trust::from_raw(v).raw_value(),
                v,
                "round-trip failed for raw {v}"
            );
        }
    }

    #[test]
    fn trust_reserved_falls_back_to_verbatim() {
        // Raw values 7–63 are reserved per cookbook §2.3.
        assert_eq!(Trust::from_raw(7), Trust::Verbatim);
        assert_eq!(Trust::from_raw(63), Trust::Verbatim);
        assert_eq!(Trust::from_raw(-1), Trust::Verbatim);
    }

    /// Trust ordered strictly by raw value, matching Swift's
    /// `Comparable` implementation: `lhs.rawValue < rhs.rawValue`.
    #[test]
    fn trust_ordering() {
        assert!(Trust::Verbatim < Trust::Observed);
        assert!(Trust::Observed < Trust::Imported);
        assert!(Trust::Imported < Trust::Canonical);
        assert!(Trust::Canonical < Trust::Derived);
        assert!(Trust::Derived < Trust::Proposed);
        assert!(Trust::Proposed < Trust::Ambient);
        // Transitivity spot-check
        assert!(Trust::Verbatim < Trust::Ambient);
        assert!(Trust::Proposed >= Trust::Canonical);
    }

    #[test]
    fn trust_filter_example() {
        // Retrieval-layer pattern: "only drawers with trust >= Canonical"
        let values = [
            Trust::Verbatim,
            Trust::Observed,
            Trust::Canonical,
            Trust::Proposed,
            Trust::Ambient,
        ];
        let filtered: Vec<_> = values.iter().filter(|&&t| t >= Trust::Canonical).collect();
        assert_eq!(filtered.len(), 3); // Canonical, Proposed, Ambient
    }

    // --- AdjectiveSensitivity raw values (bits 6–11, cookbook §2.3 scale-gapped) ---

    #[test]
    fn adjective_sensitivity_raw_values_match_cookbook() {
        assert_eq!(AdjectiveSensitivity::Normal.raw_value(), 0);
        assert_eq!(AdjectiveSensitivity::Elevated.raw_value(), 16);
        assert_eq!(AdjectiveSensitivity::Restricted.raw_value(), 32);
        assert_eq!(AdjectiveSensitivity::Secret.raw_value(), 48);
    }

    #[test]
    fn adjective_sensitivity_roundtrip() {
        for &v in &[0i64, 16, 32, 48] {
            assert_eq!(AdjectiveSensitivity::from_raw(v).raw_value(), v);
        }
    }

    #[test]
    fn adjective_sensitivity_gap_values_fall_back_to_normal() {
        for v in [1i64, 4, 8, 12, 15, 17, 31, 33, 47, 49, 63, -1, 255] {
            assert_eq!(
                AdjectiveSensitivity::from_raw(v),
                AdjectiveSensitivity::Normal,
                "expected Normal fallback for raw {v}"
            );
        }
    }

    // --- AdjectiveExportability raw values (bits 12–17, cookbook §2.3) ---

    #[test]
    fn adjective_exportability_raw_values_match_cookbook() {
        assert_eq!(AdjectiveExportability::Private.raw_value(), 0);
        assert_eq!(AdjectiveExportability::Public.raw_value(), 32);
    }

    #[test]
    fn adjective_exportability_roundtrip() {
        assert_eq!(
            AdjectiveExportability::from_raw(0),
            AdjectiveExportability::Private
        );
        assert_eq!(
            AdjectiveExportability::from_raw(32),
            AdjectiveExportability::Public
        );
    }

    #[test]
    fn adjective_exportability_unknown_falls_back_to_private() {
        for v in [1i64, 8, 16, 31, 33, 48, 63, -1, 255] {
            assert_eq!(
                AdjectiveExportability::from_raw(v),
                AdjectiveExportability::Private,
                "expected Private fallback for raw {v}"
            );
        }
    }

    // --- Privacy-tier predicates — ADR-007 Decision 2 ---
    //
    // Truth table: four sensitivity values × three tier predicates.
    // Mirrors the Swift AdjectivePrivacyTierTests suite — cross-port
    // conformance: the truth tables MUST agree in both languages.

    // is_bulk_exportable (Normal tier)

    #[test]
    fn is_bulk_exportable_true_for_normal() {
        assert!(
            AdjectiveSensitivity::Normal.is_bulk_exportable(),
            "Normal is in the Normal tier — free bulk export (ADR-007 Decision 2)"
        );
    }

    #[test]
    fn is_bulk_exportable_true_for_elevated() {
        assert!(
            AdjectiveSensitivity::Elevated.is_bulk_exportable(),
            "Elevated is in the Normal tier — free bulk export (ADR-007 Decision 2)"
        );
    }

    #[test]
    fn is_bulk_exportable_false_for_restricted() {
        assert!(
            !AdjectiveSensitivity::Restricted.is_bulk_exportable(),
            "Restricted is in the Private tier — not bulk-exportable (ADR-007 Decision 2)"
        );
    }

    #[test]
    fn is_bulk_exportable_false_for_secret() {
        assert!(
            !AdjectiveSensitivity::Secret.is_bulk_exportable(),
            "Secret is in the Secret tier — not bulk-exportable (ADR-007 Decision 2)"
        );
    }

    // requires_owner_key_for_bulk (Private tier)

    #[test]
    fn requires_owner_key_false_for_normal() {
        assert!(
            !AdjectiveSensitivity::Normal.requires_owner_key_for_bulk(),
            "Normal is in the Normal tier — no key required (ADR-007 Decision 2)"
        );
    }

    #[test]
    fn requires_owner_key_false_for_elevated() {
        assert!(
            !AdjectiveSensitivity::Elevated.requires_owner_key_for_bulk(),
            "Elevated is in the Normal tier — no key required (ADR-007 Decision 2)"
        );
    }

    #[test]
    fn requires_owner_key_true_for_restricted() {
        assert!(
            AdjectiveSensitivity::Restricted.requires_owner_key_for_bulk(),
            "Restricted is in the Private tier — owner key required (ADR-007 Decision 2)"
        );
    }

    #[test]
    fn requires_owner_key_false_for_secret() {
        assert!(
            !AdjectiveSensitivity::Secret.requires_owner_key_for_bulk(),
            "Secret is in the Secret tier — excluded entirely, not key-gated (ADR-007 Decision 2)"
        );
    }

    // is_excluded_from_bulk (Secret tier)

    #[test]
    fn is_excluded_from_bulk_false_for_normal() {
        assert!(
            !AdjectiveSensitivity::Normal.is_excluded_from_bulk(),
            "Normal is in the Normal tier — not excluded (ADR-007 Decision 2)"
        );
    }

    #[test]
    fn is_excluded_from_bulk_false_for_elevated() {
        assert!(
            !AdjectiveSensitivity::Elevated.is_excluded_from_bulk(),
            "Elevated is in the Normal tier — not excluded (ADR-007 Decision 2)"
        );
    }

    #[test]
    fn is_excluded_from_bulk_false_for_restricted() {
        assert!(
            !AdjectiveSensitivity::Restricted.is_excluded_from_bulk(),
            "Restricted is in the Private tier — key-gated, not hard-excluded (ADR-007 Decision 2)"
        );
    }

    #[test]
    fn is_excluded_from_bulk_true_for_secret() {
        assert!(
            AdjectiveSensitivity::Secret.is_excluded_from_bulk(),
            "Secret is in the Secret tier — always excluded from bulk (ADR-007 Decision 2)"
        );
    }

    /// ADR-007 Decision 2 exhaustiveness: the three predicates are mutually
    /// exclusive and collectively exhaustive — exactly one is `true` for
    /// every variant. Cross-port conformance: matches the Swift exhaustiveness
    /// test in `AdjectivePrivacyTierTests`.
    #[test]
    fn privacy_tier_predicates_mutually_exclusive_exhaustive() {
        let all_variants = [
            AdjectiveSensitivity::Normal,
            AdjectiveSensitivity::Elevated,
            AdjectiveSensitivity::Restricted,
            AdjectiveSensitivity::Secret,
        ];
        for variant in all_variants {
            let true_count = [
                variant.is_bulk_exportable(),
                variant.requires_owner_key_for_bulk(),
                variant.is_excluded_from_bulk(),
            ]
            .iter()
            .filter(|&&b| b)
            .count();
            assert_eq!(
                true_count, 1,
                "{variant:?}: expected exactly 1 true predicate but got {true_count} (ADR-007 Decision 2)"
            );
        }
    }
}
