// Adjective.swift
//
// An adjective describes the noun and constrains a recall. There are
// four categories, fixed at four by spec invariant I-8. They are
// cross-noun: every row carries a value in each, whatever its storage
// shape. This type names the four categories. The values within each
// category are a bitmap-layout concern (spec section 5.5) and are
// reified as value enums in LocusKit, which conforms to this lexicon;
// the lexicon names the categories, not the values, so the two do not
// fork.

/// One of the four cross-noun adjective categories.
public enum Adjective: String, CaseIterable, Sendable, Codable {
    /// Where the row sits in the epistemic timeline (active, pending,
    /// contested, superseded, decayed, withdrawn, expired, rejected,
    /// accepted, tombstoned).
    case state
    /// How the content was established (verbatim, observed, imported,
    /// proposed, derived, canonical).
    case trust
    /// How exposed the content may be (normal, elevated, restricted,
    /// secret).
    case sensitivity
    /// Whether the content may leave the access perimeter (private,
    /// public).
    case exportability
}
