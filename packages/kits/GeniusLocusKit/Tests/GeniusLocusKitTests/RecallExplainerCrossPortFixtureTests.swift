// RecallExplainerCrossPortFixtureTests.swift
//
// Reads the shared fixture Tests/Conformance/recall_explainer_fixture.json
// (also asserted by rust/tests/recall_explainer_parity.rs) and checks that
// RecallExplainer renders each case's lines verbatim. The lines are what
// moot_memory_search explain:true prints under each candidate row, so a
// drift in either port's explainer surfaces here before it reaches a client.

import Foundation
import Testing
import LocusKit
@testable import GeniusLocusKit

@Suite("RecallExplainer cross-port fixture")
struct RecallExplainerCrossPortFixtureTests {

    private struct FixtureScore: Decodable {
        let locus: Float, bm25: Float, vector: Float, dense: Float
        let fieldFit: Float, coOccurrence: Float, temporal: Float
        let graph: Float, preference: Float, final: Float
    }

    private struct FixtureCase: Decodable {
        let name: String
        let sources: [String]
        let score: FixtureScore
        let hasQueryText: Bool
        let mode: String
        let scoring: String
        let expected: [String]
    }

    private struct Fixture: Decodable {
        let cases: [FixtureCase]
    }

    /// Resolves Tests/Conformance/recall_explainer_fixture.json relative to
    /// this file (Tests/GeniusLocusKitTests/).
    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("recall_explainer_fixture.json")
    }

    @Test("every fixture case renders its expected lines verbatim")
    func fixtureCasesMatch() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL()))
        #expect(!fixture.cases.isEmpty)
        for c in fixture.cases {
            let sources = Set(try c.sources.map { raw -> RecallEvidencePath in
                guard let p = RecallEvidencePath(rawValue: raw) else {
                    throw FixtureError.unknownSource(raw)
                }
                return p
            })
            let sv = RecallScoreVector(
                locus: c.score.locus, bm25: c.score.bm25, vector: c.score.vector,
                fieldFit: c.score.fieldFit, coOccurrence: c.score.coOccurrence,
                temporal: c.score.temporal, graph: c.score.graph,
                preference: c.score.preference, redundancyPenalty: 0,
                final: c.score.final, dense: c.score.dense)
            let hit = RecallHit(id: "fixture", drawer: nil, sources: sources, score: sv, explanation: [])
            let mode = try #require(GLKRecallMode(rawValue: c.mode), "unknown mode \(c.mode)")
            let scoring = try #require(GLKRecallScoring(rawValue: c.scoring), "unknown scoring \(c.scoring)")
            let plan = RecallPlan(effectiveMode: mode, frontierK: 64, weights: .uniform)
            let sketch = RecallQuerySketch(
                frame: RecallFrame(filterChain: []),
                bitmapPredicates: [],
                queryText: c.hasQueryText ? "fixture query" : nil,
                queryTokens: [],
                queryEngram: nil,
                queryFingerprint: nil,
                latticeAnchor: nil)
            let lines = RecallExplainer().explain(hit: hit, sketch: sketch, plan: plan, scoring: scoring)
            #expect(lines == c.expected, "case '\(c.name)': got \(lines)")
        }
    }

    private enum FixtureError: Error { case unknownSource(String) }
}
