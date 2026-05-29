import Foundation
import AriaLexiconLib

/// AriaLexicon conformance for the GeniusLocusKit nine-verb surface.
///
/// The GLK verb surface speaks AriaLexicon's vocabulary: each of the
/// nine methods on `GeniusLocusKit` maps one-to-one onto a case of
/// `AriaLexicon.Verb` (the lexicon's nine-case enum is the same nine,
/// in the same names, per architecture spec §4.2 and ARIA_LEXICON.md).
/// This file makes that mapping explicit and provides the §7.2
/// acceptance-matrix conformance helpers a test suite or a future ARIA
/// surface uses to validate that a given (verb, noun) call is legal.
///
/// The conformance is data, not behavior. It does not gate verb
/// dispatch — that is GLK-03 / Brain-layer territory. The point of
/// the conformance is so the Swift and Rust ports agree on the
/// vocabulary they implement (cookbook conformance gate) and so a
/// caller above the GLK layer (ARIA_MCP, an iOS surface) can route by
/// `(Verb, Noun)` without re-deriving the mapping.
public enum AriaLexiconConformance {

    /// The lexicon verb the GLK method named `verbName` maps to.
    /// Returns `nil` for any string outside the nine-verb set.
    ///
    /// The mapping is identity-by-name. Every verb method on
    /// `GeniusLocusKit` is named exactly as the lexicon's enum case,
    /// so the mapping is a single `Verb(rawValue:)` lookup. This is by
    /// design: the lexicon is the conformance contract; if a GLK
    /// method drifted from the lexicon's spelling, this lookup would
    /// fail and the conformance test would catch the drift.
    public static func verb(for verbName: String) -> Verb? {
        Verb(rawValue: verbName)
    }

    /// The set of `(Verb, Noun)` pairs the GLK surface routes against
    /// an existing operand noun.
    ///
    /// Per AriaLexicon's §7.2 matrix, the six caller-driven verbs
    /// (capture, recall, mutate, withdraw, expunge, reanchor) operate
    /// on `.drawer`; the grounding-driven verb (learn) operates on
    /// `.learnedReference` (the matrix lists `.learn` only against
    /// `learnedReference` because the verb's product *is* the operand).
    /// The two substrate-driven verbs (propose, associate) are
    /// deliberately excluded: the §7.2 matrix lists neither against
    /// any noun, because both verbs create products without targeting
    /// an existing instance of a noun in the lexicon's matrix sense.
    /// The GLK surface still expresses these verbs (the Brain layer
    /// invokes them in later sub-missions) but they have no
    /// matrix-targeted operand noun to enumerate here.
    public static let surfaceTargets: [(Verb, Noun)] = [
        (.capture, .drawer),
        (.recall, .drawer),
        (.mutate, .drawer),
        (.withdraw, .drawer),
        (.expunge, .drawer),
        (.reanchor, .drawer),
        (.learn, .learnedReference),
    ]

    /// Whether every surface target is accepted by the lexicon's
    /// `Acceptance` matrix (architecture spec §7.2). The conformance
    /// test calls this and asserts true; a returned false signals the
    /// surface has drifted from the matrix and must be reconciled
    /// before merge.
    public static func everySurfaceTargetIsAccepted() -> Bool {
        for (verb, noun) in surfaceTargets {
            guard Acceptance.accepts(noun, verb) else { return false }
        }
        return true
    }

    /// The set of `(Verb, Noun)` combinations the lexicon's §7.2
    /// matrix marks legal. Returned as a flattened list so a parity
    /// test can compare against the Rust port's enumeration.
    ///
    /// Order: outer loop nouns in `Noun.allCases` order, inner loop
    /// verbs in `Verb.allCases` order. Stable across runs so the parity
    /// fixture is deterministic.
    public static var legalPairs: [(Noun, Verb)] {
        var out: [(Noun, Verb)] = []
        for noun in Noun.allCases {
            for verb in Verb.allCases where Acceptance.accepts(noun, verb) {
                out.append((noun, verb))
            }
        }
        return out
    }

    /// The set of `(Verb, Noun)` combinations the lexicon's §7.2
    /// matrix marks illegal. The complement of `legalPairs` over the
    /// full Cartesian product. Used by the conformance test to assert
    /// that the lexicon rejects exactly the combinations the spec
    /// rejects (most prominently: the Vector noun accepts no verbs
    /// because vectors are substrate-managed rungs, per Noun.role
    /// `.rung`).
    public static var illegalPairs: [(Noun, Verb)] {
        var out: [(Noun, Verb)] = []
        for noun in Noun.allCases {
            for verb in Verb.allCases where !Acceptance.accepts(noun, verb) {
                out.append((noun, verb))
            }
        }
        return out
    }

    /// The four adjective categories the lexicon names (architecture
    /// spec §5.5, I-8). Re-exposed here so callers reaching the GLK
    /// verb surface for routing purposes do not need a second import.
    public static let adjectives: [Adjective] = Adjective.allCases
}
