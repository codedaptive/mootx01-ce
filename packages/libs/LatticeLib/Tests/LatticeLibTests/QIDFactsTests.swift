// QIDFactsTests.swift
//
// Pins for the vendored Wikidata property subset (QIDFacts.json,
// DECISION_DENSE_LANE_ENRICHMENT v0.2). Cross-port literal twins in
// rust qid_facts tests.

import Testing
@testable import LatticeLib

struct QIDFactsTests {
    @Test("artifact loads and versions")
    func loads() {
        #expect(QIDFacts.isAvailable)
        #expect(QIDFacts.dataVersion != "0.0.0-unavailable")
    }

    @Test("label + P17 pins (Paris/France)")
    func parisPins() {
        #expect(QIDFacts.label(for: "Q90") == "Paris")
        #expect(QIDFacts.countryQID(for: "Q90") == "Q142")
        #expect(QIDFacts.countryLabel(for: "Q90") == "France")
        #expect(QIDFacts.label(for: "") == nil)
        #expect(QIDFacts.label(for: "Q999999999") == nil)
    }

    @Test("multi-word phrase index (Rio de Janeiro → Brazil)")
    func phrasePins() {
        #expect(QIDFacts.qid(forPhrase: "rio de janeiro") == "Q8678")
        #expect(QIDFacts.countryLabel(for: "Q8678") == "Brazil")
        #expect(QIDFacts.qid(forPhrase: "rio") == nil)
    }
}
