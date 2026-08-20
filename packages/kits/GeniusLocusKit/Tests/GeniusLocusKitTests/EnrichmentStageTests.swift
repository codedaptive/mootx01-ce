// EnrichmentStageTests.swift
//
// Pipeline-p2 categorizer pins (DECISION_DENSE_LANE_ENRICHMENT Wave 2).
// The trailer is deterministic (HMM word-class baseline + bundled FDC
// canon), so these literals are CROSS-PORT golden pins — the Rust twin
// asserts the same strings in brain/enrichment_stage.rs tests.

import Testing
import CorpusKit
@testable import GeniusLocusKit

struct EnrichmentStageTests {

    @Test("no anchoring noun → empty trailer")
    func emptyWhenNothingAnchors() {
        #expect(EnrichmentStage.trailer(forContent: "") == "")
        #expect(EnrichmentStage.trailer(forContent: "ok so um yeah") == "")
    }

    @Test("trailer is grammar-v1 shaped and scanner-parseable")
    func trailerShape() {
        let t = EnrichmentStage.trailer(
            forContent: "I finally finished my first full screenplay and printed it last Friday.")
        if !t.isEmpty {
            #expect(t.hasPrefix(" (*[ "))
            #expect(t.hasSuffix(" ]*)"))
            // CorpusKit's scanner must accept every trailer we emit.
            #expect(CorpusKit.TrailerGrammar.lexicalSupplement(
                fromDenseText: "body." + t) != "")
        }
        // Determinism: same input, same output.
        #expect(t == EnrichmentStage.trailer(
            forContent: "I finally finished my first full screenplay and printed it last Friday."))
    }

    @Test("function words never become facts")
    func stopwordsNeverAnchor() {
        let t = EnrichmentStage.trailer(
            forContent: "The idea is that they have been with you and them about it.")
        #expect(!t.contains("entity: the"))
        #expect(!t.contains("entity: they"))
    }

    @Test("multi-word entities anchor as phrases with country facts")
    func multiWordAnchoring() {
        let t = EnrichmentStage.trailer(
            forContent: "We got back from an awesome trip to Rio de Janeiro yesterday.")
        #expect(t.contains("entity: rio de janeiro"))
        #expect(t.contains("country: brazil"))
        // The fragments never re-anchor separately.
        #expect(!t.contains("entity: rio,") && !t.contains("entity: janeiro"))
    }

    @Test("facts are capped and deduplicated")
    func capAndDedup() {
        let long = Array(repeating: "painting music travel robot guitar camera festival", count: 5)
            .joined(separator: " ")
        let t = EnrichmentStage.trailer(forContent: long)
        if !t.isEmpty {
            let inner = t.dropFirst(" (*[ ".count).dropLast(" ]*)".count)
            let pairs = inner.split(separator: ",")
            #expect(pairs.count <= EnrichmentStage.maxFacts)
            #expect(Set(pairs.map { $0.trimmingCharacters(in: .whitespaces) }).count == pairs.count)
        }
    }
}
