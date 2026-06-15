import Foundation
import SubstrateTypes
import SubstrateKernel
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib

/// Adjective bitmap value types per cookbook
/// `docs/engineering/GENIUSLOCUS_ENGINEERING_COOKBOOK_v0.36_*.md`
/// §2.3 (layout) and §2.8 (verification table).
///
/// F11 LocusKit cascade (2026-05-27): bumped from v0.35's 4-bit
/// fields to cookbook v0.6's 6-bit fields per I-15. Raw values
/// switched to the scale-gapped layout that makes the cluster
/// predicate a single shift-mask: `cluster(state) = (state >> 4) & 0x3`.
///
/// ```
/// bits 0–5   State            (gradient, 10 cases per §2.3 / §2.8)
/// bits 6–11  Sensitivity      (scale-gapped, raw 0/16/32/48)
/// bits 12–17 Exportability    (scale-gapped, raw 0/32)
/// bits 18–23 Trust            (gradient, 7 cases at raw 0…6; ambient is NEW)
/// bit  24    State-extension flag (cookbook §2.9 issue C2)
/// bit  25    Lineage-clustering flag (NEW)
/// bit  26    Dreaming-recalc-required flag (obligation; F17 cascade)
/// bit  27    Sealed flag (custody trust hint; 1 = sealed; 2026-05-28)
/// bits 28–63 reserved
/// ```
///
/// `Trust`, `AdjectiveSensitivity`, and `AdjectiveExportability` in
/// this file are the single source of truth for the three adjective
/// level axes (trust, sensitivity, exportability) across all kits —
/// NeuronKit, GeniusLocusKit, and every other LocusKit consumer reads
/// these enums rather than declaring its own. Layers *below* LocusKit
/// (SubstrateLib, SubstrateTypes, PersistenceKit) cannot import these
/// enums — the dependency graph points the other way — so they carry
/// the raw-integer encoding as the cross-layer contract: the numeric
/// encoding is the contract; the enum names are documentation (the
/// same stance `ForbiddenCombinationValidator.swift` documents about
/// itself). Any new representation of these axes must either import
/// these enums or carry a one-line citation back to this file.
///
/// The pattern matches `Provenance.swift` exactly: named-enum
/// accessors decode each axis from a single Int64 column with a
/// safe fallback to the zero case when an unrecognised raw value
/// appears (which can happen when a future-version row encodes a
/// case that does not exist in this build).

// ──────────────────────────────────────────────────────────────────────
// Quis custodiet ipsos custodes? Who watches the watchmen's bitmaps?
// The SwiftSyntax Guardian does — tools/guardian.
//
// The four enums below are the canonical source of truth for the
// adjective-level axes. SubstrateLib carries duplicate raw-integer
// encodings of the legal value sets (it cannot import LocusKit: the
// dependency graph points the other way). Touch one side and the
// Guardian warns at your desk, before it ships.
//
// Nine pairs total: six set-equality pairs (legalValues ↔ allCases)
// and three singleton-raw pairs (single comparison literal ↔ single
// case rawValue). The singleton-raw pairs cover the I-22/S-1 threshold
// constants at RowStateAutomaton.swift.
//
// Test backstop: GuardianPairParityTests (CI-level pin for all nine).
// ──────────────────────────────────────────────────────────────────────

// @guardian-pair: state-basis State.allCases <-> AuditGate.basis[state].legalValues (raw set equality)
// @guardian-pair: drawerstore-mutate-state State.allCases <-> DrawerStore.mutateState.stateSlot.legalValues (raw set equality)
// @guardian-pair: drawerstore-expunge-state State.allCases <-> DrawerStore.expungeGated.stateSlot.legalValues (raw set equality)
/// State axis — where the row sits in the AI's epistemic timeline.
/// Lives in bits 0–5 of `Drawer.adjectiveBitmap` (6 bits, 64 values;
/// 10 used at scale-gapped raws, 54 reserved). Per cookbook §2.3 /
/// §2.8.
///
/// The 10 cases partition into three mathematical clusters per
/// cookbook §2.3, with boundaries at raws 0 / 16 / 32 so the cluster
/// predicate is a single shift-mask `(state >> 4) & 0x3`:
///
///   Cluster A (active / becoming):       active, pending, contested, accepted
///   Cluster B (superseded / historical): superseded, decayed, withdrawn, expired
///   Cluster C (terminal):                rejected, tombstoned
///
/// The cluster boundaries are exposed as the `isCurrentlyBelieved`,
/// `isKnewPast`, and `isTerminal` predicates on `Drawer`. F11 cascade
/// (2026-05-27): `accepted` moved from `isTerminal` (its v0.35 home)
/// to `isCurrentlyBelieved` (cluster A per cookbook §2.3). Cookbook
/// semantics: accepted is the audit-grade endpoint of becoming-true
/// belief, parallel to rejected/tombstoned being endpoints of
/// becoming-false / removed belief.
public enum State: Int, Sendable, Codable {
    // Cluster A — active / becoming.
    case active = 0
    case pending = 1
    case contested = 2
    case accepted = 3
    // Cluster B — superseded / historical (boundary at 16).
    case superseded = 16
    case decayed = 17
    case withdrawn = 18
    case expired = 19
    // Cluster C — terminal (boundary at 32).
    case rejected = 32
    case tombstoned = 33

    /// `true` if this state is in Cluster A (currently believed) per
    /// cookbook §2.3: active, pending, contested, accepted. Used by
    /// Bundle A materialization (§11.5 active centroid) and by recall
    /// paths that want the "currently believed" set. Implemented by raw
    /// magnitude rather than the 2-bit cluster encoding (top bits of
    /// the 6-bit state field at adjective bits 0–5) so a reader can
    /// follow the predicate against the State case list directly.
    public var isClusterA: Bool {
        switch self {
        case .active, .pending, .contested, .accepted: return true
        default: return false
        }
    }
}

// @guardian-pair: trust-basis Trust.allCases <-> AuditGate.basis[trust].legalValues (raw set equality)
// @guardian-pair: s1-trust-threshold trust < 3 <-> Trust.canonical (rawValue ==)
/// Trust axis — how the substrate qualifies the row's reliability.
/// Lives in bits 18–23 of `Drawer.adjectiveBitmap` (6 bits, 64
/// values; 7 used at raws 0–6, 57 reserved). Per cookbook §2.3.
///
/// F11 cascade (2026-05-27): added `ambient = 6` per cookbook §2.3
/// (NEW in v0.6, see §2.5 for the ambient-sample noun type that
/// motivated it). `Comparable` ordering is unchanged — it still
/// compares raw values, so `ambient` orders above `proposed`.
///
/// `Comparable` so retrieval-layer filters such as
/// `drawer.trust >= .canonical` compose without raw-value math, the
/// same pattern `Confidence` uses in `Provenance.swift`.
public enum Trust: Int, Sendable, Codable, Comparable {
    case verbatim = 0
    case observed = 1
    case imported = 2
    case canonical = 3
    case derived = 4
    case proposed = 5
    case ambient = 6     // NEW in v0.6 per cookbook §2.3

    public static func < (lhs: Trust, rhs: Trust) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// @guardian-pair: sensitivity-basis AdjectiveSensitivity.allCases <-> AuditGate.basis[sensitivity].legalValues (raw set equality)
// @guardian-pair: i22-sensitivity-raw sensitivity == 48 <-> AdjectiveSensitivity.secret (rawValue ==)
/// Sensitivity axis on the adjective bitmap — per-row access posture.
/// Lives in bits 6–11 of `Drawer.adjectiveBitmap` (6 bits, 64 values).
/// Per cookbook §2.3 / §2.8.
///
/// Distinct from `Sensitivity` on the provenance bitmap — that is
/// sensitivity *at capture*, a 6-bit scale-gapped encoding at bits
/// 30–35 of the provenance column that deliberately mirrors these
/// raw values (see `Provenance.swift`).
/// The adjective sensitivity is a scale-gapped encoding: cases sit at
/// 0/16/32/48 (cookbook §2.3 scale-gapped) to leave room for
/// intermediate tiers without disturbing equality or ordering masks.
/// The qualified type name (`AdjectiveSensitivity` rather than
/// `Sensitivity`) keeps both surfaces visible on `Drawer` without a
/// type-name collision.
public enum AdjectiveSensitivity: Int, Sendable, Codable {
    case normal = 0
    case elevated = 16
    case restricted = 32
    case secret = 48
}

// MARK: - Privacy-tier predicates (ADR-007 Decision 2)

public extension AdjectiveSensitivity {

    /// `true` for sensitivity values that belong to the **Normal tier**
    /// per ADR-007 Decision 2: `.normal` (raw 0) and `.elevated` (raw 16).
    ///
    /// Normal-tier drawers are eligible for free bulk export. This predicate
    /// is the enforcement hook that VaultKit's export path consults to
    /// determine whether a drawer may ride a bulk channel without additional
    /// friction.
    ///
    /// ADR-007 Decision 2 tier mapping (four sensitivity values → three tiers):
    ///   `.normal`     → Normal tier  → `isBulkExportable = true`
    ///   `.elevated`   → Normal tier  → `isBulkExportable = true`
    ///   `.restricted` → Private tier → `isBulkExportable = false`
    ///   `.secret`     → Secret tier  → `isBulkExportable = false`
    var isBulkExportable: Bool {
        switch self {
        case .normal, .elevated: return true
        case .restricted, .secret: return false
        }
    }

    /// `true` for sensitivity values that belong to the **Private tier**
    /// per ADR-007 Decision 2: `.restricted` (raw 32).
    ///
    /// Private-tier drawers require an owner-held key at execution time before
    /// participating in bulk operations (v1.0 gold deliverable). By default
    /// they are excluded from bulk export; an explicit scope option in VaultKit
    /// may include them when the key ceremony is satisfied.
    ///
    /// ADR-007 Decision 2 tier mapping:
    ///   `.normal`     → Normal tier  → `requiresOwnerKeyForBulk = false`
    ///   `.elevated`   → Normal tier  → `requiresOwnerKeyForBulk = false`
    ///   `.restricted` → Private tier → `requiresOwnerKeyForBulk = true`
    ///   `.secret`     → Secret tier  → `requiresOwnerKeyForBulk = false`
    var requiresOwnerKeyForBulk: Bool {
        switch self {
        case .restricted: return true
        case .normal, .elevated, .secret: return false
        }
    }

    /// `true` for sensitivity values that belong to the **Secret tier**
    /// per ADR-007 Decision 2: `.secret` (raw 48).
    ///
    /// Secret-tier drawers never ride bulk channels under any scope option.
    /// This predicate is the hard exclusion gate: VaultKit's export path
    /// must reject secret-tier drawers regardless of any other scope
    /// configuration.
    ///
    /// ADR-007 Decision 2 tier mapping:
    ///   `.normal`     → Normal tier  → `isExcludedFromBulk = false`
    ///   `.elevated`   → Normal tier  → `isExcludedFromBulk = false`
    ///   `.restricted` → Private tier → `isExcludedFromBulk = false`
    ///   `.secret`     → Secret tier  → `isExcludedFromBulk = true`
    var isExcludedFromBulk: Bool {
        switch self {
        case .secret: return true
        case .normal, .elevated, .restricted: return false
        }
    }
}

// @guardian-pair: exportability-basis AdjectiveExportability.allCases <-> AuditGate.basis[exportability].legalValues (raw set equality)
// @guardian-pair: i22-exportability-raw exportability == 32 <-> AdjectiveExportability.public_ (rawValue ==)
/// Exportability axis — whether a row may leave the local estate.
/// Lives in bits 12–17 of `Drawer.adjectiveBitmap` (6 bits, 64
/// values; 2 used, 62 reserved). Per cookbook §2.3.
///
/// Two cases at scale-gapped raw values 0 and 32 leave generous room
/// for intermediate tiers (e.g., a future `restrictedShare` between
/// private and public) to slot in without disturbing existing
/// equality masks. Case names use trailing underscores because
/// `private` and `public` are reserved Swift keywords.
public enum AdjectiveExportability: Int, Sendable, Codable {
    case private_ = 0
    case public_ = 32
}

// MARK: - Drawer accessors

public extension Drawer {

    /// Decode bits 0–5 of `adjectiveBitmap` as a `State`. Returns
    /// `.active` for unrecognised raw values so retrieval filters that
    /// look for current beliefs fail closed (an unknown row is
    /// treated as currently believed and surfaces for review rather
    /// than silently disappearing). Cookbook §2.3 6-bit field.
    var state: State {
        // Cookbook §2.3: state at bits 0–5.
        State(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 0, width: 6))) ?? .active
    }

    /// Decode bits 6–11 of `adjectiveBitmap` as an
    /// `AdjectiveSensitivity`. Returns `.normal` for unrecognised raw
    /// values, matching the estate-level default access posture.
    /// Named `adjectiveSensitivity` rather than `sensitivity` to
    /// avoid colliding with the provenance-bitmap `sensitivity`
    /// accessor declared in `Drawer.swift`. Cookbook §2.3 6-bit field.
    var adjectiveSensitivity: AdjectiveSensitivity {
        // Cookbook §2.3: sensitivity at bits 6–11.
        AdjectiveSensitivity(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 6, width: 6))) ?? .normal
    }

    /// Decode bits 12–17 of `adjectiveBitmap` as an
    /// `AdjectiveExportability`. Returns `.private_` for unrecognised
    /// raw values — defaulting to non-exportable is the safe fallback
    /// for an unknown encoding. Cookbook §2.3 6-bit field.
    var exportability: AdjectiveExportability {
        // Cookbook §2.3: exportability at bits 12–17.
        AdjectiveExportability(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 12, width: 6))) ?? .private_
    }

    /// Decode bits 18–23 of `adjectiveBitmap` as a `Trust`. Returns
    /// `.verbatim` for unrecognised raw values; verbatim is the
    /// neutral baseline (unqualified content as filed). Cookbook §2.3
    /// 6-bit field.
    var trust: Trust {
        // Cookbook §2.3: trust at bits 18–23.
        Trust(rawValue: Int(BitField.extractField(adjectiveBitmap, shift: 18, width: 6))) ?? .verbatim
    }

    /// True when the row sits in Cluster A (active / becoming) per
    /// cookbook §2.3 — `.active`, `.pending`, `.contested`, or
    /// `.accepted`. F11 cascade (2026-05-27): `.accepted` moved here
    /// from `isTerminal`. Cookbook semantics: accepted is the
    /// audit-grade endpoint of becoming-true belief.
    ///
    /// Mathematically equivalent to `(state.rawValue >> 4) & 0x3 == 0`.
    var isCurrentlyBelieved: Bool {
        switch state {
        case .active, .pending, .contested, .accepted: return true
        default: return false
        }
    }

    /// True when the row sits in Cluster B (superseded / historical)
    /// per cookbook §2.3 — `.superseded`, `.decayed`, `.withdrawn`, or
    /// `.expired`.
    ///
    /// Mathematically equivalent to `(state.rawValue >> 4) & 0x3 == 1`.
    var isKnewPast: Bool {
        switch state {
        case .superseded, .decayed, .withdrawn, .expired: return true
        default: return false
        }
    }

    /// True when the row sits in Cluster C (terminal) per cookbook
    /// §2.3 — `.rejected` or `.tombstoned`. F11 cascade (2026-05-27):
    /// `.accepted` moved OUT of this cluster (now in `isCurrentlyBelieved`).
    /// Cookbook semantics: cluster C is "externally rejected / removed,"
    /// not "no further transitions" (which `accepted` satisfies but
    /// rejected/tombstoned also satisfy).
    ///
    /// Mathematically equivalent to `(state.rawValue >> 4) & 0x3 == 2`.
    var isTerminal: Bool {
        switch state {
        case .rejected, .tombstoned: return true
        default: return false
        }
    }

    /// True when this row's graph contribution has been disturbed
    /// (by redact/expunge, mass-mutation, lineage rewrite, or any
    /// other operation that invalidates downstream relationships)
    /// and the dreaming pass has not yet reconciled the affected
    /// neighborhood. Cookbook §2.3 bit 26, F17 cascade (2026-05-27).
    ///
    /// Polarity is *obligation*, not state: true = recalc owed,
    /// false = no recalc owed (either never disturbed or dreaming
    /// has visited since the last disturbance). See cookbook §9.5.1
    /// for the content-vs-graph distinction this flag encodes.
    var dreamingRecalcRequired: Bool {
        // Cookbook §2.3 bit 26 (F17 cascade).
        BitField.extractFlag(adjectiveBitmap, bit: 26)
    }

    /// True when a valid integrity seal exists for this row's current
    /// state. Cookbook §2.3 bit 27 (custody cascade, 2026-05-28).
    ///
    /// Polarity: 1 = sealed (higher custody trust), 0 = unsealed (more
    /// recent / emergent, seal not yet computed). This is a cached
    /// *trust hint* only — the proof is the seal stored elsewhere; if
    /// the bit and the seal ever disagree, the seal is authoritative.
    /// Set only by the seal-writing/verifying path: strict mode stamps
    /// 1 at write; lazy mode stamps 0 at write and the dreaming pass
    /// flips it to 1 when the seal is computed. Unsealed rows are the
    /// dreaming seal queue (`sealed == false`).
    var sealed: Bool {
        // Cookbook §2.3 bit 27 (custody cascade).
        BitField.extractFlag(adjectiveBitmap, bit: 27)
    }
}
