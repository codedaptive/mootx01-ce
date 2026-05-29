// Tokenizer.swift
//
// UAX #29 word-boundary tokenization. Uses Foundation's
// `String.enumerateSubstrings(in:options: .byWords)` which
// invokes ICU's word-boundary analyzer beneath. ICU implements
// UAX #29; Foundation is part of the Swift standard library on
// Apple and Linux platforms (via swift-corelibs-foundation), so
// this is cross-platform portable.
//
// Conformance-gated against the Rust port's `tokenize` function,
// which uses the `unicode-segmentation` crate. Both implement
// UAX #29; output is byte-identical for the same input on the
// covered cases.

import Foundation

public enum Tokenizer {
    /// Tokenize a string into Unicode words. Whitespace,
    /// punctuation, and word separators are dropped; words are
    /// returned in input order.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        let range = text.startIndex..<text.endIndex
        text.enumerateSubstrings(
            in: range,
            options: .byWords
        ) { substring, _, _, _ in
            if let substring, !substring.isEmpty {
                tokens.append(substring)
            }
        }
        return tokens
    }
}
