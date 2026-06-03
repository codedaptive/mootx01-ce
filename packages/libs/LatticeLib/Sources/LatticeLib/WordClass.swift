// WordClass.swift
//
// The word-class label produced by FDC encoder Step 1 (cookbook §2,
// canonical §3 Step 1). Step 1 keeps only nouns and verbs; everything
// else (articles, prepositions, times, adjectives, punctuation) is
// discarded, which is what `.other` represents here.
//
// This is the return type of `LatticeLib.wordClass(_:)`. It is pure
// data with a byte-identical shape to the Rust port's `WordClass`
// enum, so the two legs agree on every shared conformance vector.

import Foundation

/// The word class of a single token under FDC encoder Step 1.
///
/// Step 1 retains nouns and verbs with their counts and discards
/// everything else. `.other` is that discard bucket: any token the
/// encoder will not carry forward into Step 2.
///
/// String-backed so the value serializes to a stable, human-readable
/// JSON form (`"noun"` / `"verb"` / `"other"`) that the shared
/// conformance vectors and the Rust port both read.
public enum WordClass: String, Equatable, Sendable, Codable {

    /// The token is a noun. Kept by Step 1.
    case noun

    /// The token is a verb. Kept by Step 1.
    case verb

    /// The token is neither a noun nor a verb (article, preposition,
    /// adjective, time, punctuation, or anything else). Discarded by
    /// Step 1.
    case other
}
