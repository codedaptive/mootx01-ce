// SpanRerankParityTests.swift
//
// Cross-port pin for the span rerank stage (Encoder Rerank Program, contract
// sheet §8/§10/§11). Reads the shared fixture
// SynapseKit/Tests/Fixtures/encoder/span_rerank_parity.json (also asserted by
// rust/tests/span_rerank_parity.rs): 50 dim-8 span rows over 20 items, 20 unit
// query vectors, one BM25 head of 30 items (10 without span rows) and the fused
// order per query. Failure mode: a port dequantises the int8 rows differently,
// picks a different best span on a tie, or sorts the RRF ties differently.

import Foundation
import Testing
@testable import GeniusLocusKit

@Suite("Span rerank cross-port parity fixture")
struct SpanRerankParityTests {

    private struct FixtureSpan: Decodable {
        let item_id: String; let index: UInt32; let start_word: Int; let end_word: Int
        let int8: [Int8]; let scale: Float
    }
    private struct FixtureQuery: Decodable { let vector: [Float] }
    private struct FixtureHit: Decodable { let item_id: String; let best_span_index: UInt32; let cosine: Float }
    private struct FixtureOrder: Decodable { let order: [String]; let hits: [FixtureHit] }
    private struct Fixture: Decodable {
        let model_id: String; let span_weight: Float
        let span_vectors: [FixtureSpan]; let query_vectors: [FixtureQuery]
        let bm25_head: [String]; let expected_orders: [FixtureOrder]
    }

    /// The fixture's rows, keyed by item — a stand-in for SynapseKit's span rows.
    private struct FixtureRows: SpanVectorReading {
        let rows: [String: [SpanRerankVector]]
        func spanVectors(itemIDs: [String], modelID: String) async throws -> [String: [SpanRerankVector]] {
            rows.filter { itemIDs.contains($0.key) }
        }
    }

    /// An encoder whose query vector is the fixture's (the model is out of the loop).
    private struct FixtureEncoder: SpanRerankEncoding {
        let modelID: String
        let vector: [Float]
        func encodeQuery(_ text: String) async throws -> [Float] { vector }
    }

    /// packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/<file> → packages/kits/ →
    /// SynapseKit/Tests/Fixtures/encoder/ (four components up: file, suite dir, Tests, kit).
    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SynapseKit/Tests/Fixtures/encoder/span_rerank_parity.json")
    }

    @Test("every query reproduces the fixture's fused order and best spans")
    func fusedOrdersMatch() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL()))
        #expect(fixture.query_vectors.count == fixture.expected_orders.count)
        var rows: [String: [SpanRerankVector]] = [:]
        for span in fixture.span_vectors {
            rows[span.item_id, default: []].append(SpanRerankVector(
                index: span.index, int8: span.int8, scale: span.scale,
                startWord: span.start_word, endWord: span.end_word))
        }
        let store = FixtureRows(rows: rows)
        let head = fixture.bm25_head.enumerated().map { SpanRerankInput(itemID: $1, bm25Rank: $0 + 1) }
        for (qi, query) in fixture.query_vectors.enumerated() {
            let expected = fixture.expected_orders[qi]
            let encoder = FixtureEncoder(modelID: fixture.model_id, vector: query.vector)
            let hits = try await SpanRerankStage.spanRerank(
                head: head, query: "fixture query \(qi)", encoder: encoder, store: store)
            #expect(hits.map(\.itemID) == expected.hits.map(\.item_id), "query \(qi): span rank order")
            #expect(hits.map(\.bestSpanIndex) == expected.hits.map(\.best_span_index), "query \(qi): best span")
            for (hit, want) in zip(hits, expected.hits) {
                #expect(abs(hit.cosine - want.cosine) < 1e-4, "query \(qi) \(hit.itemID): cosine \(hit.cosine) vs \(want.cosine)")
            }
            let fused = SpanRerankStage.fuse(bm25Order: fixture.bm25_head, hits: hits, spanWeight: fixture.span_weight)
            #expect(fused.map(\.id) == expected.order, "query \(qi): fused order")
            // Items without span rows keep no hit; items with rows carry theirs.
            for entry in fused {
                #expect((entry.hit != nil) == (rows[entry.id] != nil), "query \(qi) \(entry.id): hit presence")
            }
        }
    }
}
