// HybridRecallTests.swift
//
// Peer suite for HybridRecallConfiguration (Sources/CorpusKit/HybridRecall.swift).
// HybridRecall.recall(...) requires a live VectorStore + BM25Index +
// BundleStore, which is integration scope; the configuration value type
// is the unit-testable surface. These assertions pin the documented
// defaults (RRF k=60, 0.6/0.4 weights, MMR disabled) and the custom init.

import Testing
import CorpusKit

@Suite("HybridRecallConfiguration")
struct HybridRecallTests {

    @Test func defaultsMatchDocumentedValues() {
        let config = HybridRecallConfiguration()
        #expect(config.vectorWeight == 0.6)
        #expect(config.keywordWeight == 0.4)
        #expect(config.rrfK == 60)
        #expect(config.mmrLambda == nil)
    }

    @Test func customInitStoresAllFields() {
        let config = HybridRecallConfiguration(
            vectorWeight: 0.7,
            keywordWeight: 0.3,
            rrfK: 10,
            mmrLambda: 0.5
        )
        #expect(config.vectorWeight == 0.7)
        #expect(config.keywordWeight == 0.3)
        #expect(config.rrfK == 10)
        #expect(config.mmrLambda == 0.5)
    }

    @Test func fieldsAreMutable() {
        var config = HybridRecallConfiguration()
        config.vectorWeight = 0.9
        config.mmrLambda = 0.25
        #expect(config.vectorWeight == 0.9)
        #expect(config.mmrLambda == 0.25)
    }
}
