//! Proposal noun struct. Ports `Proposal.swift`.
//!
//! A proposed change to the substrate, awaiting confirmation. The
//! row-shaped noun behind the `proposal` lexicon entry (proposal
//! accepts mutate, withdraw, expunge, recall). A proposal records an
//! intended write — "create this tunnel", "mutate this drawer",
//! "promote this association" — that a confirmation step (human, agent,
//! or automated threshold) later accepts or rejects. The propose path
//! is the substrate's only autonomous write surface per cookbook §10.7.
//!
//! This file ships the value type, its operational accessors,
//! the `proposals` table, and store persistence. The `propose` verb
//! is implemented in `estate_verbs.rs::Estate::propose`; other verb
//! paths (accept / reject / withdraw / expunge / recall on proposals)
//! route through the standard DrawerStore mutation surface.
//!
//! `Proposal` mirrors `KGFact` structurally — an identity, three i64
//! bitmap columns, and content fields — with one addition `KGFact`
//! predates: a required `lattice_anchor`. Per cookbook §2.7 (I-16)
//! every row carries a lattice anchor; proposals are anchored to their
//! target's anchor.
//!
//! Three i64 bitmap columns carry the operational axes:
//!
//! - `adjective_bitmap` — the proposal's own lifecycle state, trust,
//!   sensitivity, exportability per cookbook §2.3. The `state` accessor
//!   decodes the lifecycle axis (`Pending` → `Accepted` / `Rejected` /
//!   `Withdrawn`).
//! - `operational_bitmap` — proposal kind, target object type,
//!   confirmation source, generated-by class, confidence bucket per
//!   cookbook §2.4 ("Proposal operational"). See
//!   `proposal_operational.rs`.
//! - `provenance_bitmap` — source type, confirmation, confidence,
//!   channel, sensitivity per `the packed provenance layout`.
//!
//! All three bitmaps default to `0` so callers constructing a bare
//! proposal get the safe baseline without threading every axis through
//! the call site.
//!
//! ## Swift-to-Rust shape changes
//!
//! - `Date filedAt` → `i64 filed_at` (epoch milliseconds, epoch-millisecond instants), the convention
//!   used across the LocusKit Rust port.
//! - `id: String = UUID().uuidString` Swift default → Rust callers
//!   supply `id` explicitly.
//! - Like the Swift type, `Proposal` derives `PartialEq, Eq` but **not**
//!   `Hash`: the embedded `LatticeAnchor` is not `Hash`, matching the
//!   Swift `LatticeAnchor` (which is `Equatable` but not `Hashable`).

use crate::adjectives::State;
use crate::estate_types::LatticeAnchor;
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

/// A proposed change to the substrate, awaiting confirmation.
///
/// Mirrors `Proposal.swift` field-for-field. Equality follows the Rust
/// derive defaults — every field participates, matching Swift's
/// auto-synthesized `Equatable`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proposal {
    /// Stable identifier. Row identity is a UUID per cookbook I-29;
    /// callers supply it explicitly (the Swift default mints a fresh
    /// UUID).
    pub id: String,

    /// Identifier of the row this proposal acts on — the `RowReference`
    /// of cookbook §10.7's `propose(target:…)`. Empty for a
    /// brand-new-object proposal (target object type `NoneBrandNew`).
    pub target_row_id: String,

    /// Free-form explanation of why this proposal was generated — the
    /// `justification` of cookbook §10.7. `None` for automated-threshold
    /// proposals that carry no rationale.
    pub justification: Option<String>,

    /// The adjective set this proposal would apply to its target if
    /// accepted — the `candidate_state` of cookbook §10.7. Encoded in
    /// the same adjective bitmap layout as `Drawer::adjective_bitmap`.
    pub candidate_state: i64,

    /// The proposal's lattice anchor — required on every row per
    /// cookbook §2.7 (I-16). Proposals are anchored to their target's
    /// anchor. `udc_code` must be non-empty at storage; `add_proposal`
    /// rejects an empty anchor with `LocusKitError::InvalidContent`.
    pub lattice_anchor: LatticeAnchor,

    /// Adjective bitmap encoding the proposal's own lifecycle state,
    /// trust, sensitivity, exportability per cookbook §2.3.
    pub adjective_bitmap: i64,

    /// Operational bitmap encoding proposal kind, target object type,
    /// confirmation source, generated-by class, confidence bucket per
    /// cookbook §2.4. See `proposal_operational.rs`.
    pub operational_bitmap: i64,

    /// Provenance bitmap per `the packed provenance layout`.
    pub provenance_bitmap: i64,

    /// When this proposal was filed. Epoch seconds in the Rust port;
    /// the SQLite column is TEXT ISO8601 per the fleet rule.
    pub filed_at: i64,
}

impl Proposal {
    /// Construct a proposal with all-zero bitmaps. Mirrors the Swift
    /// designated initializer's safe-baseline defaults.
    pub fn new(
        id: String,
        target_row_id: String,
        lattice_anchor: LatticeAnchor,
        filed_at: i64,
    ) -> Self {
        Proposal {
            id,
            target_row_id,
            justification: None,
            candidate_state: 0,
            lattice_anchor,
            adjective_bitmap: 0,
            operational_bitmap: 0,
            provenance_bitmap: 0,
            filed_at,
        }
    }

    /// Decode bits 0–5 of `adjective_bitmap` as a `State` (6-bit field,
    /// cookbook §2.3 — shared with `Drawer`). Returns `State::Active`
    /// for unrecognised raw values, the neutral fail-closed baseline
    /// matching `State::from_raw`. `state` is the axis a proposal moves
    /// through over its lifecycle — `Pending` while it awaits
    /// confirmation, then `Accepted`, `Rejected`, or `Withdrawn`.
    pub fn state(&self) -> State {
        // Cookbook §2.3: state at bits 0–5.
        State::from_raw(bit_field::extract_field(self.adjective_bitmap, 0, 6))
    }

    /// Decode bits 6–11 of `adjective_bitmap` as an `AdjectiveSensitivity`.
    /// Returns `AdjectiveSensitivity::Normal` for unrecognised raw values,
    /// the fail-closed baseline matching `AdjectiveSensitivity::from_raw`.
    ///
    /// A proposal inherits its target drawer's sensitivity tier at creation
    /// (§D.2): the `propose` path stamps these bits from `target_drawer.
    /// adjective_sensitivity()`. Mirrors `Drawer.adjectiveSensitivity` and
    /// `Tunnel.adjectiveSensitivity`. Cookbook §2.3 6-bit field.
    pub fn adjective_sensitivity(&self) -> crate::adjectives::AdjectiveSensitivity {
        // Cookbook §2.3: adjective sensitivity at bits 6–11 of adjective_bitmap.
        crate::adjectives::AdjectiveSensitivity::from_raw(
            bit_field::extract_field(self.adjective_bitmap, 6, 6),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Proposal {
        Proposal::new(
            "p-1".to_string(),
            "d-1".to_string(),
            LatticeAnchor::udc("547"),
            1_700_000_000,
        )
    }

    #[test]
    fn defaults_match_swift_initializer() {
        let p = sample();
        assert_eq!(p.adjective_bitmap, 0);
        assert_eq!(p.operational_bitmap, 0);
        assert_eq!(p.provenance_bitmap, 0);
        assert_eq!(p.candidate_state, 0);
        assert_eq!(p.justification, None);
        assert_eq!(p.state(), State::Active);
    }

    #[test]
    fn state_decodes_bits_zero_through_five() {
        let mut p = sample();
        p.adjective_bitmap = 1; // Pending
        assert_eq!(p.state(), State::Pending);
        p.adjective_bitmap = 3; // Accepted
        assert_eq!(p.state(), State::Accepted);
        p.adjective_bitmap = 18; // Withdrawn
        assert_eq!(p.state(), State::Withdrawn);
        p.adjective_bitmap = 32; // Rejected
        assert_eq!(p.state(), State::Rejected);
    }

    #[test]
    fn state_ignores_bits_outside_zero_through_five() {
        let mut p = sample();
        // Set bits above the 0..6 window — accessor must ignore them.
        p.adjective_bitmap = (1i64 << 6) | (1i64 << 30);
        assert_eq!(p.state(), State::Active);
    }

    #[test]
    fn lattice_anchor_round_trips() {
        let p = sample();
        assert_eq!(p.lattice_anchor.udc_code, "547");
    }

    #[test]
    fn equality_includes_every_field() {
        let p1 = sample();
        let mut p2 = sample();
        assert_eq!(p1, p2);
        p2.target_row_id = "d-2".to_string();
        assert_ne!(p1, p2);
    }
}
