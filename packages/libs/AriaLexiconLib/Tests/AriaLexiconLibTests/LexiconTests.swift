// LexiconTests.swift
//
// Conformance anchors for the ARIA grammar. These pin the counts and
// relationships that are part of the contract (spec invariants I-7,
// I-8 and the section 7.2 acceptance matrix), so a drift in the
// vocabulary fails a test rather than slipping through.

import Testing
@testable import AriaLexiconLib

@Suite("AriaLexiconLibTests")
struct AriaLexiconLibTests {

    @Test("The verb count is fixed at nine (I-7)")
    func verbCountIsNine() {
        #expect(Verb.allCases.count == 9)
    }

    @Test("The adjective category count is fixed at four (I-8)")
    func adjectiveCountIsFour() {
        #expect(Adjective.allCases.count == 4)
    }

    @Test("The drawer is the one noun of the language")
    func drawerIsPrimary() {
        #expect(Noun.primary == .drawer)
        #expect(Noun.drawer.role == .primary)
        #expect(Noun.allCases.filter { $0.role == .primary } == [.drawer])
    }

    @Test("Every non-drawer shape is a rung, structure, or product")
    func nonDrawerShapesHaveRoles() {
        #expect(Noun.kgFact.role == .rung)
        #expect(Noun.vector.role == .rung)
        #expect(Noun.tunnel.role == .structure)
        #expect(Noun.diaryEntry.role == .structure)
        #expect(Noun.association.role == .structure)
        #expect(Noun.proposal.role == .product)
        #expect(Noun.learnedReference.role == .product)
    }

    @Test("Verb flows partition the nine verbs as the spec defines")
    func verbFlowsPartition() {
        let caller = Verb.allCases.filter { $0.flow == .callerDriven }
        let substrate = Verb.allCases.filter { $0.flow == .substrateDriven }
        let grounding = Verb.allCases.filter { $0.flow == .groundingDriven }
        #expect(Set(caller) == [.capture, .reanchor, .mutate, .withdraw, .expunge, .recall])
        #expect(Set(substrate) == [.propose, .associate])
        #expect(Set(grounding) == [.learn])
        #expect(caller.count + substrate.count + grounding.count == 9)
    }

    @Test("Acceptance matrix matches spec section 7.2")
    func acceptanceMatrix() {
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

    @Test("accepts agrees with the verb set")
    func acceptsAgrees() {
        #expect(Acceptance.accepts(.drawer, .capture))
        #expect(!Acceptance.accepts(.drawer, .learn))
        #expect(Acceptance.accepts(.learnedReference, .learn))
        #expect(!Acceptance.accepts(.vector, .recall))
    }

    @Test("Only the learnedReference accepts learn; only the drawer and tunnel accept capture")
    func verbApplicability() {
        let learners = Noun.allCases.filter { Acceptance.accepts($0, .learn) }
        #expect(learners == [.learnedReference])
        let capturers = Noun.allCases.filter { Acceptance.accepts($0, .capture) }
        #expect(Set(capturers) == [.drawer, .tunnel])
    }

    @Test("The grammar sentence is stated")
    func grammarStated() {
        #expect(AriaLexiconLib.grammar.contains("one verb applied to a noun"))
    }
}
