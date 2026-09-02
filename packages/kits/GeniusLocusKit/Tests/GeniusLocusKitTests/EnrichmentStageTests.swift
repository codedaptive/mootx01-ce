// EnrichmentStageTests.swift
//
// Pipeline-p2 categorizer pins (DECISION_DENSE_LANE_ENRICHMENT Wave 2).
// The trailer is deterministic (HMM word-class baseline + bundled FDC
// canon), so these literals are CROSS-PORT golden pins — the Rust twin
// asserts the same strings in brain/enrichment_stage.rs tests.

import Testing
import EideticLib
import LatticeLib
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

/// Query-side lattice anchoring (W2.5 Track S) — same selection rules as the
/// categorizer, one anchor per query.
@Suite("QueryLatticeAnchor")
struct QueryLatticeAnchorTests {

    @Test("multi-word phrase anchors first and carries the phrase QID")
    func phraseAnchors() {
        let a = QueryLatticeAnchor.derive(from: "Where is Rio de Janeiro?")
        #expect(a.qid == "Q8678")
        #expect(a.udcCode == "")
    }

    @Test("first anchoring noun wins and matches EideticLib's anchor")
    func nounAnchors() {
        // Selection-logic pin without pinning HMM word classes: compute the
        // first token that satisfies the categorizer's own predicate chain,
        // then assert derive() picked exactly that token's anchor.
        let text = "tell me about the painting guitar camera"
        let tokens = text.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }
        let expected = tokens.lazy
            .filter { $0.count >= 3 && !EnrichmentStage.stopwords.contains($0) }
            .filter { LatticeLib.wordClass($0) == .noun }
            .map { EideticLib.lookup($0) }
            .first { !$0.code.isEmpty && $0.code != "000" }
        let a = QueryLatticeAnchor.derive(from: text)
        if let expected {
            #expect(a.udcCode == expected.code)
            #expect(a.qid == (expected.wikidataQID ?? ""))
        } else {
            #expect(a.udcCode == "" && a.qid == "")
        }
        // The fixture is chosen so at least one noun anchors — if the canon
        // ever stops anchoring all three, this pin must be re-fixtured.
        #expect(expected != nil)
    }

    @Test("stopword-only or unanchorable text yields the empty anchor")
    func unanchorable() {
        let a = QueryLatticeAnchor.derive(from: "the and was were yeah okay")
        #expect(a.udcCode == "" && a.qid == "")
    }

    // GOLDEN PIN (M4 — cross-port vector, mirrored in enrichment_stage.rs #[test]
    // query_anchor_golden_pin_m4). Same input/output asserted in both ports.
    @Test("M4 golden pin: phrase-anchored query → Q8678")
    func m4GoldenPin() {
        let a = QueryLatticeAnchor.derive(from: "Where is Rio de Janeiro?")
        // Multi-word phrase "rio de janeiro" matches QIDFacts → QID Q8678, no FDC code.
        // This is the canonical cross-port conformance vector for the anchor path.
        #expect(a.qid == "Q8678")
        #expect(a.udcCode == "")
    }
}
