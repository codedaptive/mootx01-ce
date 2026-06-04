// Acceptance.swift
//
// Which verbs each storage shape accepts (architecture spec section
// 7.2). In the language this reads as which actions apply to the
// drawer and its facets, not as a grammar of competing nouns. The
// matrix is data so a conformance harness can check the Swift and Rust
// ports agree on it.

/// The verb-noun acceptance matrix.
public enum Acceptance {

    /// The verbs a shape accepts. The Vector is substrate-managed and
    /// not directly verb-addressable, so it accepts none.
    public static func verbs(for noun: Noun) -> Set<Verb> {
        switch noun {
        case .drawer:
            return [.capture, .reanchor, .mutate, .withdraw, .expunge, .recall]
        case .tunnel:
            return [.capture, .mutate, .withdraw, .expunge, .recall]
        case .kgFact:
            return [.mutate, .withdraw, .expunge, .recall]
        case .vector:
            return []
        case .diaryEntry:
            return [.recall]
        case .proposal:
            return [.propose, .mutate, .withdraw, .expunge, .recall]
        case .association:
            return [.associate, .mutate, .expunge, .recall]
        case .learnedReference:
            return [.learn, .mutate, .withdraw, .expunge, .recall]
        }
    }

    /// Whether a shape accepts a verb.
    public static func accepts(_ noun: Noun, _ verb: Verb) -> Bool {
        verbs(for: noun).contains(verb)
    }
}
