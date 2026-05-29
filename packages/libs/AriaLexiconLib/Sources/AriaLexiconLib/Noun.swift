// Noun.swift
//
// The noun is the data. In the language there is one noun, the Drawer,
// the atomic unit of memory. The substrate stores other shapes, and
// the architecture spec's storage taxonomy (section 4.1) has loosely
// called all of them nouns; they are not nouns in the language. They
// are facets of the drawer or the residue of verbs acting on it. This
// type names every storage shape but marks the Drawer as primary and
// records each shape's role relative to it.

/// A storage shape the substrate persists. The Drawer is the noun of
/// the language; the rest are its rungs, structure about it, or the
/// products of verbs.
public enum Noun: String, CaseIterable, Sendable, Codable {
    case drawer
    case tunnel
    case kgFact
    case vector
    case diaryEntry
    case proposal
    case association
    case learnedReference

    /// The one noun of the language. Consumers think in drawers; the
    /// other shapes are how the substrate represents a drawer's content
    /// or records what verbs did.
    public static let primary: Noun = .drawer

    /// How this shape relates to the drawer in the language.
    public var role: NounRole {
        switch self {
        case .drawer:
            return .primary
        case .kgFact, .vector:
            return .rung
        case .tunnel, .diaryEntry, .association:
            return .structure
        case .proposal, .learnedReference:
            return .product
        }
    }
}

/// A storage shape's relationship to the drawer.
public enum NounRole: String, CaseIterable, Sendable, Codable {
    /// The drawer itself, the noun of the language.
    case primary
    /// A representation of the drawer's content (a rung).
    case rung
    /// An edge or event about drawers.
    case structure
    /// What a verb leaves behind.
    case product
}
