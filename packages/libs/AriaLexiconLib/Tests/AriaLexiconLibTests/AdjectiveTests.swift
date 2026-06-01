// AdjectiveTests.swift
//
// Per-type peer suite for `Adjective`. Mirrors the Rust `adjective_count_is_four`
// #[test] (spec invariant I-8: the adjective category count is fixed at four).
// Thin by design: the lexicon names the four cross-noun categories, not their
// values — the values within each category are a bitmap-layout concern reified
// in LocusKit, deliberately NOT modeled here (so the two do not fork). There is
// no per-value behavioral surface to assert; this suite pins the four category
// identities and their stable raw values.

import Testing
@testable import AriaLexiconLib

@Suite("Adjective")
struct AdjectiveTests {

    @Test("The adjective category count is fixed at four (I-8)")
    func adjectiveCountIsFour() {
        #expect(Adjective.allCases.count == 4)
    }

    @Test("The four categories are state, trust, sensitivity, exportability")
    func categoryIdentities() {
        #expect(Adjective.allCases == [.state, .trust, .sensitivity, .exportability])
    }

    @Test("Adjective raw values are stable and round-trip")
    func rawValueIdentity() {
        #expect(Adjective.state.rawValue == "state")
        #expect(Adjective.trust.rawValue == "trust")
        #expect(Adjective.sensitivity.rawValue == "sensitivity")
        #expect(Adjective.exportability.rawValue == "exportability")
        for adjective in Adjective.allCases {
            #expect(Adjective(rawValue: adjective.rawValue) == adjective)
        }
    }
}
