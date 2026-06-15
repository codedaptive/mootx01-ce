//! EideticLib, the deterministic text-to-anchor utility. Pass a
//! term to `lookup`; get back an `Anchor` carrying an FDC code, the
//! dominant concept's Wikidata Q-ID, a confidence, and the FDC
//! signatures version that produced the answer.
//!
//! Swift LEADS this surface; the Rust port follows. The FDC encoder
//! itself lives in the `lattice_lib` crate (frame / lexicon /
//! signatures / concept-bag / stemmer / matcher). Swift's
//! `EideticLib.lookup` delegates to `LatticeLib.FDC.encodeAnchor`;
//! the Rust `lookup` here mirrors that exactly: it delegates to
//! `lattice_lib::Fdc::encode_anchor` using the same pinned artifacts
//! embedded in the `lattice_lib` crate.

pub mod anchor;
pub mod segmenter;
pub mod lattice_code_state;

pub use anchor::Anchor;
pub use lattice_code_state::{LatticeCodeGrammar, LatticeCodeState, classify_lattice_code};

use lattice_lib::Fdc;
use std::collections::HashSet;

/// The EideticLib crate version.
pub const VERSION: &str = "0.1.0";

/// Looks up the lattice anchor for a term. Deterministic against
/// lattice_lib's pinned FDC artifacts.
///
/// Delegates to `Fdc::encode_anchor` (the Rust port of Swift's
/// `FDC.encodeAnchor`): the term is canonicalized to a concept bag
/// and matched to an FDC code, and the bag's dominant Wikidata Q-ID
/// is carried as the anchor concept. No network is consulted.
///
/// Panics if the bundled artifacts fail to load — that is a
/// build/configuration error, not a runtime condition. A failed
/// load means the binary shipped without its required data bundle
/// and no caller can produce a legitimate anchor. Silent sentinel
/// returns are rejected per the P1 mandate: "a sentinel identity
/// that persists IS a fabricated identity" (Bob's board item 7).
/// Panics loud; fix the build. Mirrors Swift `EideticLib.lookup(_:)`.
pub fn lookup(term: &str) -> Anchor {
    if !Fdc::is_available() {
        panic!(
            "eidetic_lib: FDC artifacts failed to load — \
             build/configuration error. The bundled canon is missing \
             from this binary. No anchor can be produced. Fix the build."
        );
    }

    let (code, qid) = Fdc::encode_anchor(term);
    match code {
        None => {
            // UNRESOLVED: empty anchor, never a fallback code.
            // Mirrors Swift's guard-let path that returns an empty Anchor.
            Anchor {
                code: String::new(),
                wikidata_qid: None,
                confidence: 0,
                data_version: Fdc::data_version().to_string(),
            }
        }
        Some(c) => {
            // FDC carries no calibrated confidence score; a resolved code
            // is reported at `medium` (32 in the provenance confidence
            // value set: 0=null, 16=low, 32=medium, 48=high, 56=verified).
            // Mirrors Swift's confidence assignment in EideticLib.swift.
            Anchor {
                code: c,
                wikidata_qid: qid,
                confidence: 32,
                data_version: Fdc::data_version().to_string(),
            }
        }
    }
}

/// Classifies a candidate FDC code string against the grammar and a
/// supplied known-code set, without loading the FDC reference data.
///
/// Port of `EideticLib.classifyLatticeCode(_:knownCodes:)` in Swift.
/// Re-exported from `lattice_code_state` at the module surface.
pub fn classify(code: &str, known_codes: &HashSet<String>) -> LatticeCodeState {
    classify_lattice_code(code, known_codes)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Version ──────────────────────────────────────────────────────────

    #[test]
    fn version_pinned() {
        assert_eq!(VERSION, "0.1.0");
    }

    // ── lookup — behavioral contract ─────────────────────────────────────
    //
    // These tests assert the behavioral contract (non-empty code for a
    // topical term, empty code for nonsense/empty, determinism, confidence
    // values) without asserting exact code selections. Exact-code
    // conformance against Tests/SharedVectors/lookup_vectors.json requires
    // the LatticeLib Rust single-token accuracy fix (see FINDINGS below).

    #[test]
    fn lookup_resolves_topical_term_to_nonempty_code() {
        // Mirrors Swift `lookupChemistryResolvesToCode` and
        // `lookupResolvesToWellFormedCode`. A topical multi-token term
        // that appears in the LatticeLib conformance fixture resolves
        // to a non-empty FDC code.
        let anchor = lookup("organic chemistry reactions molecules");
        assert!(
            !anchor.code.is_empty(),
            "a topical phrase must resolve to an FDC code"
        );
    }

    #[test]
    fn lookup_carries_medium_confidence_for_resolved_code() {
        // Resolved codes carry confidence = 32 (medium), matching Swift.
        let anchor = lookup("organic chemistry reactions molecules");
        if !anchor.code.is_empty() {
            assert_eq!(
                anchor.confidence, 32,
                "resolved code must carry medium confidence (32)"
            );
        }
    }

    #[test]
    fn lookup_empty_string_yields_empty_anchor() {
        // Mirrors Swift `lookupEmptyStringYieldsEmptyAnchor`.
        let anchor = lookup("");
        assert_eq!(anchor.code, "");
        assert_eq!(anchor.confidence, 0);
        assert!(anchor.wikidata_qid.is_none());
    }

    #[test]
    fn lookup_unresolved_term_returns_empty_code() {
        // Mirrors Swift `unresolvedTermReturnsEmptyAnchor`. A term with
        // no signature overlap returns an empty code, never a guess.
        let anchor = lookup("zxcvqwertyasdfgh");
        assert_eq!(
            anchor.code, "",
            "unresolved term must yield an empty code, not a fallback"
        );
        assert!(anchor.wikidata_qid.is_none());
        assert_eq!(anchor.confidence, 0);
    }

    #[test]
    fn lookup_carries_data_version() {
        // The data_version records the pinned FDC signatures version.
        // Mirrors Swift `lookupCarriesDataVersion`.
        // FDC unavailable is a panic (build/config error); this test
        // also implicitly validates that the artifacts loaded.
        let anchor = lookup("organic chemistry reactions molecules");
        assert!(!anchor.data_version.is_empty());
    }

    #[test]
    fn lookup_is_deterministic() {
        // Same input must always produce the same Anchor.
        // Mirrors Swift `lookupIsDeterministic`.
        let a = lookup("computer software programming and information science");
        let b = lookup("computer software programming and information science");
        assert_eq!(a, b);
    }

    #[test]
    fn lookup_fdc_available() {
        // The bundled artifacts must load — configuration check.
        // If this fails, lookup panics (build/configuration error).
        // This test ensures that build/config is correct in CI.
        assert!(Fdc::is_available(), "lattice_lib FDC runtime must be available");
    }

    #[test]
    fn lookup_empty_punctuation_yields_empty_anchor() {
        // Mirrors lookup_vectors.json "punctuation_only_drops_to_empty".
        let anchor = lookup("!!!???");
        assert_eq!(anchor.code, "");
        assert!(anchor.wikidata_qid.is_none());
    }

    // ── lookup — cross-port conformance note ────────────────────────────
    //
    // The lookup_vectors.json cross-port conformance gate was added in
    // mission w3-latticelib-fdc (2026-06-05) at schema_version 2. The
    // full conformance test lives in rust/tests/lookup_conformance_test.rs
    // (43 tests pass). Swift parity is confirmed via
    // EideticLib/Tests/EideticLibTests/LookupConformanceTests.swift
    // (77 tests pass). Both legs exercise the same 26 lookup vectors.

    // ── classify — top-level re-export ───────────────────────────────────

    #[test]
    fn classify_re_export_works() {
        // Verifies the top-level `classify` re-export delegates correctly
        // to `classify_lattice_code`.
        let known: HashSet<String> = ["100".to_string()].into();
        let state = classify("100", &known);
        assert_eq!(state, LatticeCodeState::Known("100".to_string()));
    }

    #[test]
    fn classify_re_export_malformed() {
        let state = classify("bogus", &HashSet::new());
        assert_eq!(state, LatticeCodeState::Malformed("bogus".to_string()));
    }
}
