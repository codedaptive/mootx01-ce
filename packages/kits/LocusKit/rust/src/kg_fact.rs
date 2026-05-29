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
//!   channel, sensitivity per `Q1_DECISION_PROVENANCE_BITMAP.md`.
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
//! - `Date filedAt` → `i64 filed_at` (epoch seconds). Same convention
//!   used across the LocusKit Rust port.
//! - `id: String = UUID().uuidString` Swift default → Rust callers
//!   supply `id` explicitly. Tests build deterministic ids;
//!   conformance against the KG vector requires caller-supplied ids
//!   anyway.

use crate::adjectives::Trust;
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need a SimHash, Hamming distance, OR-reduce, Fingerprint256 op,
// HammingNN top-K, HLC tick, AuditGate admit, MatrixDecay, audit-
// log fold, Bradley-Terry update, NMF, FFT, eigenvalue centrality,
// or any other substrate primitive, it's already in substrate-types,
// substrate-kernel, or substrate-ml. CI catches drift four ways.
// See packages/libs/Substrate{Types,Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
use substrate_kernel::bit_field;

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

    /// Identifier of the drawer this fact was extracted from. Every
    /// fact must trace back to a drawer.
    pub source_drawer_id: String,

    /// Adjective bitmap encoding state, trust, sensitivity, and
    /// exportability per spec § 5.5. Shares the encoding with
    /// `Drawer::adjective_bitmap`.
    pub adjective_bitmap: i64,

    /// Operational bitmap encoding extractor class, assertion kind,
    /// specificity, confidence band, and the canonical flag per spec
    /// § 5.6. See `kg_fact_operational.rs`.
    pub operational_bitmap: i64,

    /// Provenance bitmap carried from the source drawer at extraction
    /// time per `Q1_DECISION_PROVENANCE_BITMAP.md`.
    pub provenance_bitmap: i64,

    /// When this fact was filed. Epoch seconds in the Rust port; the
    /// SQLite column is TEXT ISO8601 per the fleet rule.
    pub filed_at: i64,
}

impl KGFact {
    /// Construct a fact with all-zero bitmaps. Mirrors the Swift
    /// designated initializer's safe-baseline defaults.
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
    /// The four-axis adjective bitmap is shared with `Drawer`; only
    /// the `trust` accessor is exposed on `KGFact` here because it is
    /// the axis the extraction pipeline consults most often when
    /// filing facts. State, exportability, and sensitivity accessors
    /// arrive alongside the persistence path in a future sub-mission.
    pub fn trust(&self) -> Trust {
        // Cookbook §2.3: trust at bits 18-23.
        Trust::from_raw(bit_field::extract_field(self.adjective_bitmap, 18, 6))
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
    fn equality_includes_every_field() {
        let f1 = sample();
        let mut f2 = sample();
        assert_eq!(f1, f2);
        f2.subject = "bob".to_string();
        assert_ne!(f1, f2);
    }
}
