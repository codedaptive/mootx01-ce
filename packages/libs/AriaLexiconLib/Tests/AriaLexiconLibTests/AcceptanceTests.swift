// AcceptanceTests.swift
//
// Per-type peer suite for `Acceptance` — the verb-noun acceptance matrix
// (architecture spec section 7.2). Mirrors the Rust `acceptance_matrix`,
// `accepts_agrees`, and `verb_applicability` #[test] functions, and adds an
// exhaustive cross-check that `accepts(_:_:)` agrees with `verbs(for:)` over
// every noun x verb pair. `verbs(for:)` returns `Set<Verb>`, so equality is
// asserted on sets — no ordering is assumed (the Rust port returns an ordered
// Vec; the matrix content, not its order, is the contract here).

import Testing
@testable import AriaLexiconLib

@Suite("Acceptance matrix")
struct AcceptanceTests {

    @Test("The matrix matches spec section 7.2 for every noun")
    func matrixMatchesSpec() {
        #expect(Acceptance.verbs(for: .drawer)
                == [.capture, .reanchor, .mutate, .withdraw, .expunge, .recall])
        #expect(Acceptance.verbs(for: .tunnel)
                == [.capture, .mutate, .withdraw, .expunge, .recall])
        #expect(Acceptance.verbs(for: .kgFact)
                == [.mutate, .withdraw, .expunge, .recall])
        #expect(Acceptance.verbs(for: .vector).isEmpty)
        #expect(Acceptance.verbs(for: .diaryEntry) == [.recall])
        #expect(Acceptance.verbs(for: .proposal)
                == [.propose, .mutate, .withdraw, .expunge, .recall])
        #expect(Acceptance.verbs(for: .association)
                == [.associate, .mutate, .expunge, .recall])
        #expect(Acceptance.verbs(for: .learnedReference)
                == [.learn, .mutate, .withdraw, .expunge, .recall])
    }

    @Test("The vector is substrate-managed and accepts no verb")
    func vectorAcceptsNothing() {
        #expect(Acceptance.verbs(for: .vector).isEmpty)
        for verb in Verb.allCases {
            #expect(!Acceptance.accepts(.vector, verb))
        }
    }

    @Test("accepts agrees with the verb set on spot checks")
    func acceptsAgrees() {
        #expect(Acceptance.accepts(.drawer, .capture))
        #expect(!Acceptance.accepts(.drawer, .learn))
        #expect(Acceptance.accepts(.learnedReference, .learn))
        #expect(!Acceptance.accepts(.vector, .recall))
    }

    @Test("accepts is exactly membership in verbs(for:) over every noun x verb pair")
    func acceptsIsMembershipEverywhere() {
        for noun in Noun.allCases {
            let set = Acceptance.verbs(for: noun)
            for verb in Verb.allCases {
                #expect(Acceptance.accepts(noun, verb) == set.contains(verb))
            }
        }
    }

    @Test("Only the learnedReference accepts learn; only the drawer and tunnel accept capture")
    func verbApplicability() {
        let learners = Noun.allCases.filter { Acceptance.accepts($0, .learn) }
        #expect(learners == [.learnedReference])
        let capturers = Noun.allCases.filter { Acceptance.accepts($0, .capture) }
        #expect(Set(capturers) == [.drawer, .tunnel])
    }

    @Test("Every accepted verb is one of the nine; recall is the most widely accepted")
    func acceptedVerbsAreInVocabulary() {
        for noun in Noun.allCases {
            for verb in Acceptance.verbs(for: noun) {
                #expect(Verb.allCases.contains(verb))
            }
        }
        // recall applies to every shape except the substrate-managed vector.
        let recallers = Noun.allCases.filter { Acceptance.accepts($0, .recall) }
        #expect(Set(recallers) == Set(Noun.allCases).subtracting([.vector]))
    }
}
