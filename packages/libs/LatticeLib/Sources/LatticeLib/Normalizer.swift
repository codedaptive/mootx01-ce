// Normalizer.swift
//
// Compatibility normalization (a documented NFKC subset) plus
// Unicode-aware case fold. Run before stemming and gazetteer lookup so
// that compatibility-equivalent surface forms collapse to one key.
//
// CROSS-PLATFORM CONTRACT (load-bearing)
// This is NOT a call to Swift's `precomposedStringWithCompatibilityMapping`.
// Full NFKC requires canonical combining-class reordering and composition
// tables that the Rust port cannot reproduce byte-for-byte without an
// external Unicode crate (the zero-dep rule forbids one here). To keep the
// two legs bit-identical, both Swift and Rust apply the SAME explicit,
// table-driven compatibility map defined in `NFKCSubset` — the table is the
// single source of truth and is mirrored verbatim in the Rust port
// (rust/src/normalizer.rs). Same table + same algorithm ⇒ identical output
// by construction. The shared fixture rust/tests/fixtures/normalize_conformance.json
// gates the agreement.
//
// COVERAGE (what the subset normalizes — see NFKCSubset for the rationale)
//   * Full-width ASCII and full-width Latin forms      → ASCII
//   * Common typographic ligatures (ﬁ ﬂ ﬀ ﬃ ﬄ ﬅ ﬆ)      → component letters
//   * Superscript / subscript digits and signs         → ASCII digits/signs
//   * Circled / parenthesized Latin letters and digits → base letter/digit
//   * Roman-numeral letterlike code points (Ⅰ…Ⅿ ⅰ…ⅿ)    → ASCII letters
//   * Fraction slash (U+2044)                          → ASCII '/'
//   * No-break space and a few compatibility spaces     → ASCII space
//
// EXPLICITLY OUT OF SCOPE (documented divergence from full NFKC)
//   * Canonical recomposition of base+combining sequences (e.g. half-width
//     katakana ｶ + ﾞ → ガ). The encoder corpus and gazetteer are ASCII
//     English; these cases do not occur and reproducing them cross-platform
//     would require the full combining-class/composition machinery. They
//     pass through unchanged (then case-folded). This is intentional and
//     called out so a future agent does not mistake it for a bug.
//
// Conformance-gated against the Rust port's `normalize` function via
// rust/tests/fixtures/normalize_conformance.json.

import Foundation

public enum Normalizer {
    /// Normalize a token: apply the documented NFKC compatibility subset
    /// (`NFKCSubset.fold`) then Unicode-aware case fold (`lowercased()`).
    ///
    /// The compatibility fold runs first so that, e.g., a full-width
    /// `Ａ` (U+FF21) becomes `A` and then folds to `a` — matching the
    /// key a plain ASCII `A` produces. Case folding alone would leave the
    /// full-width form distinct and split the canonicalization key.
    ///
    /// Deterministic and byte-identical to the Rust port for every input
    /// in the shared conformance fixture.
    ///
    /// - Parameter token: a single token (callers tokenize first).
    /// - Returns: the normalized, case-folded surface form.
    public static func normalize(_ token: String) -> String {
        return NFKCSubset.fold(token).lowercased()
    }
}
