//! Knowledge-graph fact struct. Ports `KGFact.swift`.
//!
//! Per `docs/specs/GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 4.1.
//!
//! `KGFact` is the first-class noun for rung 1.5 of the substrate: a
//! subject-predicate-object triple distilled from a verbatim drawer,
//! retaining a backreference to the source drawer so the fact's
//! provenance is always recoverable.
//!
//! Three Int64 bitmap columns carry the operational axes:
//!
//! - `adjective_bitmap` — state, trust, sensitivity, exportability per
//!   § 5.5. Accessors live alongside `Drawer`'s in `adjectives.rs`;
//!   `KGFact` reuses the same encoding so a fact and its source drawer
//!   can be filtered by the same retrieval-layer predicates.
//! - `operational_bitmap` — extractor class, assertion kind,
//!   specificity, confidence band, and the canonical flag per § 5.6.
//!   See `kg_fact_operational.rs` for the four enums and the
//!   computed accessors.
//! - `provenance_bitmap` — source type, confirmation, confidence,
//!   channel, sensitivity per `the packed provenance layout`.
//!   Carried verbatim from the source drawer's provenance at extraction
//!   time.
//!
//! All three bitmaps default to `0` so callers extracting facts without
//! operational metadata get the safe baseline (extractor `Manual`,
//! assertion `Asserted`, specificity `General`, confidence `Unknown`,
//! non-canonical).
//!
//! ## Swift-to-Rust shape changes
//!
//! - `Date filedAt` → `i64 filed_at` (epoch milliseconds, epoch-millisecond instants). Same convention
//!   used across the LocusKit Rust port.
//! - `id: String = UUID().uuidString` Swift default → Rust callers
//!   supply `id` explicitly. Tests build deterministic ids;
//!   conformance against the KG vector requires caller-supplied ids
//!   anyway.

use crate::adjectives::{AdjectiveExportability, AdjectiveSensitivity, State, Trust};
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_kernel::bit_field;

/// The three provenance strings a fact carries alongside its
/// `source_drawer_id`: who filed it, and — for palace-imported facts —
/// which foreign key and foreign record it came from.
///
/// Swift expresses these as defaulted initializer parameters
/// (`addedBy: String = ""` and friends). Rust has no default arguments,
/// so the same "callers who do not record an origin say nothing extra"
/// ergonomics come from `KGFactOrigin::default()`, which is all-empty.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct KGFactOrigin {
    /// Identity of the agent or host binary filing the fact.
    pub added_by: String,
    /// The foreign palace's stable source key for the anchoring drawer.
    pub foreign_source_key: String,
    /// The foreign palace's own id for the record that produced the fact.
    pub foreign_record_id: String,
}

/// A knowledge-graph fact extracted from drawer content.
///
/// Mirrors `KGFact.swift` field-for-field. Equality and hashing follow
/// the Rust derive defaults — every field participates, which matches
/// Swift's auto-synthesized `Equatable` / `Hashable`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct KGFact {
    /// Stable identifier. Callers replaying or importing previously-
    /// extracted facts supply a deterministic id (typically derived
    /// from `source_drawer_id` + subject + predicate + object) so the
    /// kg_facts table can dedupe on re-extraction.
    pub id: String,

    /// Subject of the triple. Free-form string; the substrate does
    /// not enforce an entity vocabulary at this layer.
    pub subject: String,

    /// Predicate of the triple — the relationship vocabulary item
    /// linking subject and object. Free-form string at this rung.
    pub predicate: String,

    /// Object of the triple. Free-form string. May reference another
    /// entity by id or carry a literal value depending on the
    /// predicate; the value type makes no distinction.
    pub object: String,

    /// Identifier of the drawer this fact was extracted from — a
    /// **local** drawer id, or `""` when the fact is not anchored to a
    /// drawer. Nothing else is ever stored here: a host identity, a
    /// foreign palace's key, and a foreign record id each have their own
    /// field below. A non-empty value must resolve to a drawer in this
    /// estate; the capture verb fails the write when it does not.
    pub source_drawer_id: String,

    /// Identity of the agent or host binary that filed this fact — for
    /// example `"mootx01"` or `"aria-mcp-server"` when the fact arrives
    /// through the MCP surface. Free-form; `""` when the filer is not
    /// recorded. Provenance about *who wrote the row*, which is a
    /// different question from which drawer the fact was drawn from.
    pub added_by: String,

    /// The foreign palace's stable source key for the drawer this fact
    /// anchors to, carried verbatim from the exporting estate. Set only
    /// on palace-imported facts; `""` otherwise. The key is meaningful in
    /// the *foreign* estate's namespace and resolves to no local drawer,
    /// which is why it cannot live in `source_drawer_id`.
    ///
    /// The palace re-import dedup signature (CAND-049) is built over this
    /// value, so it must survive round-trips byte-for-byte.
    pub foreign_source_key: String,

    /// The foreign palace's own identifier for the record that produced
    /// this fact — the triple id, e.g. `"t_fleet_works_with_skippy_0001"`.
    /// Set only on palace-imported facts; `""` otherwise. Like
    /// `foreign_source_key` this names a row in the foreign estate, not a
    /// local drawer.
    ///
    /// The Rust importer signs the CAND-049 signature with this value when
    /// `foreign_source_key` is empty, so it too must round-trip verbatim.
    pub foreign_record_id: String,

    /// Adjective bitmap encoding state, trust, sensitivity, and
    /// exportability per spec § 5.5. Shares the encoding with
    /// `Drawer::adjective_bitmap`.
    pub adjective_bitmap: i64,

    /// Operational bitmap encoding extractor class, assertion kind,
    /// specificity, confidence band, and the canonical flag per spec
    /// § 5.6. See `kg_fact_operational.rs`.
    pub operational_bitmap: i64,

    /// Provenance bitmap carried from the source drawer at extraction
    /// time per `the packed provenance layout`.
    pub provenance_bitmap: i64,

    /// When this fact was filed. Epoch seconds in the Rust port; the
    /// SQLite column is TEXT ISO8601 per the fleet rule.
    pub filed_at: i64,
}

impl KGFact {
    /// Construct a fact with all-zero bitmaps and empty provenance
    /// strings. Mirrors the Swift designated initializer's safe-baseline
    /// defaults, where `addedBy`, `foreignSourceKey`, and
    /// `foreignRecordID` all default to `""`.
    ///
    /// Rust has no default arguments, so callers that do record a filing
    /// host or a foreign palace origin set those fields with struct-update
    /// syntax on the returned value — the same pattern the bitmaps use.
    pub fn new(
        id: String,
        subject: String,
        predicate: String,
        object: String,
        source_drawer_id: String,
        filed_at: i64,
    ) -> Self {
        KGFact {
            id,
            subject,
            predicate,
            object,
            source_drawer_id,
            added_by: String::new(),
            foreign_source_key: String::new(),
            foreign_record_id: String::new(),
            adjective_bitmap: 0,
            operational_bitmap: 0,
            provenance_bitmap: 0,
            filed_at,
        }
    }

    /// Decode bits 18–23 of `adjective_bitmap` as a `Trust` (6-bit field,
    /// cookbook §2.3 / §5.5 — shared with Drawer). Returns
    /// `Trust::Verbatim` for unrecognised raw values — the neutral
    /// baseline matching `Drawer::trust` in `adjectives.rs`.
    ///
    /// The four-axis adjective bitmap is shared with `Drawer`; `KGFact`
    /// exposes all four axes (`state`, `adjective_sensitivity`,
    /// `exportability`, `trust`) so a fact can be filtered by the same
    /// retrieval-layer predicates as its source drawer. The encoding and
    /// fail-closed defaults match the `Drawer` accessors in
    /// `drawer_operational.rs` exactly.
    pub fn trust(&self) -> Trust {
        // Cookbook §2.3: trust at bits 18-23.
        Trust::from_raw(bit_field::extract_field(self.adjective_bitmap, 18, 6))
    }

    /// Decode bits 0–5 of `adjective_bitmap` as a `State`. Returns
    /// `State::Active` for unrecognised raw values so retrieval filters
    /// that look for current beliefs fail closed (an unknown row surfaces
    /// for review rather than silently disappearing). Cookbook §2.3 6-bit
    /// field. Mirrors Swift `KGFact.state` and `Drawer::state`.
    pub fn state(&self) -> State {
        // Cookbook §2.3: state at bits 0–5 of adjective_bitmap.
        State::from_raw(bit_field::extract_field(self.adjective_bitmap, 0, 6))
    }

    /// Decode bits 6–11 of `adjective_bitmap` as an `AdjectiveSensitivity`.
    /// Returns `AdjectiveSensitivity::Normal` for unrecognised raw values,
    /// matching the estate-level default access posture. Cookbook §2.3
    /// 6-bit field. Named `adjective_sensitivity` (not `sensitivity`) to
    /// match the `Drawer` convention and stay unambiguous about which
    /// bitmap axis is read. Mirrors Swift `KGFact.adjectiveSensitivity`.
    pub fn adjective_sensitivity(&self) -> AdjectiveSensitivity {
        // Cookbook §2.3: adjective sensitivity at bits 6–11 of adjective_bitmap.
        AdjectiveSensitivity::from_raw(bit_field::extract_field(self.adjective_bitmap, 6, 6))
    }

    /// Decode bits 12–17 of `adjective_bitmap` as an `AdjectiveExportability`.
    /// Returns `AdjectiveExportability::Private` for unrecognised raw values —
    /// non-exportable is the safe fallback for an unknown encoding. Cookbook
    /// §2.3 6-bit field. Mirrors Swift `KGFact.exportability` and
    /// `Drawer::exportability`.
    pub fn exportability(&self) -> AdjectiveExportability {
        // Cookbook §2.3: exportability at bits 12–17 of adjective_bitmap.
        AdjectiveExportability::from_raw(bit_field::extract_field(self.adjective_bitmap, 12, 6))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> KGFact {
        KGFact::new(
            "f-1".to_string(),
            "alice".to_string(),
            "livesIn".to_string(),
            "berlin".to_string(),
            "d-1".to_string(),
            1_700_000_000,
        )
    }

    #[test]
    fn defaults_match_swift_initializer() {
        let f = sample();
        assert_eq!(f.adjective_bitmap, 0);
        assert_eq!(f.operational_bitmap, 0);
        assert_eq!(f.provenance_bitmap, 0);
        // All four adjective axes decode to their fail-closed baseline on a
        // zero bitmap — identical to Swift's `KGFact` initializer defaults.
        assert_eq!(f.state(), State::Active);
        assert_eq!(f.adjective_sensitivity(), AdjectiveSensitivity::Normal);
        assert_eq!(f.exportability(), AdjectiveExportability::Private);
        assert_eq!(f.trust(), Trust::Verbatim);
    }

    #[test]
    fn trust_decodes_bits_eighteen_through_twenty_three() {
        let mut f = sample();
        f.adjective_bitmap = 1 << 18;
        assert_eq!(f.trust(), Trust::Observed);
        f.adjective_bitmap = 2 << 18;
        assert_eq!(f.trust(), Trust::Imported);
        f.adjective_bitmap = 3 << 18;
        assert_eq!(f.trust(), Trust::Canonical);
        f.adjective_bitmap = 4 << 18;
        assert_eq!(f.trust(), Trust::Derived);
        f.adjective_bitmap = 5 << 18;
        assert_eq!(f.trust(), Trust::Proposed);
    }

    #[test]
    fn trust_falls_back_to_verbatim_for_reserved_raws() {
        let mut f = sample();
        // Raws 7–63 within bits 18–23 are reserved per cookbook §2.3 and
        // resolve to Verbatim. (Raw 6 is now Ambient, NEW in v0.6.)
        for raw in 7..=63i64 {
            f.adjective_bitmap = raw << 18;
            assert_eq!(f.trust(), Trust::Verbatim, "raw {} should be Verbatim", raw);
        }
    }

    #[test]
    fn trust_ignores_bits_outside_eighteen_through_twenty_three() {
        let mut f = sample();
        // Set bits outside the 18..24 window — accessor must ignore them.
        f.adjective_bitmap = 0xFFF | (1i64 << 16) | (1i64 << 30);
        assert_eq!(f.trust(), Trust::Verbatim);
    }

    #[test]
    fn state_decodes_bits_zero_through_five() {
        let mut f = sample();
        // Cluster A / B / C representatives at their cookbook §2.3 raws.
        f.adjective_bitmap = 1; // raw 1, bits 0–5
        assert_eq!(f.state(), State::Pending);
        f.adjective_bitmap = 16;
        assert_eq!(f.state(), State::Superseded);
        f.adjective_bitmap = 18;
        assert_eq!(f.state(), State::Withdrawn);
        f.adjective_bitmap = 33;
        assert_eq!(f.state(), State::Tombstoned);
    }

    #[test]
    fn state_falls_back_to_active_for_reserved_raws() {
        let mut f = sample();
        // Reserved per-cluster gaps fail closed to Active (parity with
        // Swift `State(rawValue:) ?? .active`).
        for raw in [4i64, 15, 20, 31, 34, 63] {
            f.adjective_bitmap = raw;
            assert_eq!(f.state(), State::Active, "raw {raw} should fail closed to Active");
        }
    }

    #[test]
    fn adjective_sensitivity_decodes_bits_six_through_eleven() {
        let mut f = sample();
        // Sensitivity raws (0,16,32,48) shifted into bits 6–11.
        f.adjective_bitmap = 16 << 6;
        assert_eq!(f.adjective_sensitivity(), AdjectiveSensitivity::Elevated);
        f.adjective_bitmap = 32 << 6;
        assert_eq!(f.adjective_sensitivity(), AdjectiveSensitivity::Restricted);
        f.adjective_bitmap = 48 << 6;
        assert_eq!(f.adjective_sensitivity(), AdjectiveSensitivity::Secret);
    }

    #[test]
    fn exportability_decodes_bits_twelve_through_seventeen() {
        let mut f = sample();
        // Exportability raw 32 shifted into bits 12–17 is Public; raw 0 Private.
        f.adjective_bitmap = 32 << 12;
        assert_eq!(f.exportability(), AdjectiveExportability::Public);
        f.adjective_bitmap = 0;
        assert_eq!(f.exportability(), AdjectiveExportability::Private);
    }

    #[test]
    fn all_four_axes_coexist_without_cross_talk() {
        // Compose a bitmap carrying a distinct non-default value on each of
        // the four 6-bit axes and assert every accessor reads only its own
        // field — proves the masks/shifts do not bleed into neighbours.
        // This is the shared-bitmap conformance vector the Swift test mirrors.
        let mut f = sample();
        f.adjective_bitmap = 2            // state    = Contested (raw 2,  bits 0–5)
            | (48 << 6)                   // sens     = Secret    (raw 48, bits 6–11)
            | (32 << 12)                  // export   = Public    (raw 32, bits 12–17)
            | (3 << 18); // trust    = Canonical (raw 3,  bits 18–23)
        assert_eq!(f.state(), State::Contested);
        assert_eq!(f.adjective_sensitivity(), AdjectiveSensitivity::Secret);
        assert_eq!(f.exportability(), AdjectiveExportability::Public);
        assert_eq!(f.trust(), Trust::Canonical);
    }

    #[test]
    fn equality_includes_every_field() {
        let f1 = sample();
        let mut f2 = sample();
        assert_eq!(f1, f2);
        f2.subject = "bob".to_string();
        assert_ne!(f1, f2);
    }
}
