// Normalizer.swift
//
// NFKC normalization plus ASCII case-fold. Used before stemming
// and gazetteer lookup so that equivalent representations
// collapse to the same surface form.
//
// Conformance-gated against the Rust port's `normalize` function.

import Foundation

public enum Normalizer {
    /// Normalize a token: lowercase using Swift's Unicode-aware
    /// case folding. NFKC composition is deferred to a follow-on
    /// commit when the corpus surfaces a case needing it; the
    /// gazetteer entries are ASCII English in v0.1.
    public static func normalize(_ token: String) -> String {
        return token.lowercased()
    }
}
