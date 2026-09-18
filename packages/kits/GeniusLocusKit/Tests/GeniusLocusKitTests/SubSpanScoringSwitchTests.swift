// SubSpanScoringSwitchTests.swift
//
// The unionBest step 5.8 sub-span refinement runs only when the request
// says so: `GLKRecallRequest.subSpanScoring` is `.off` unless the caller
// turns it on. Swift twin of rust/tests/sub_span_scoring_switch.rs; both
// read Tests/Conformance/sub_span_scoring_switch_fixture.json.
//
// Tests:
//   1. offLeavesTheDenseColumnUntouched — fixture bodies, switch off: the
//      control body (never ingested) reports dense 0, no hit carries the
//      `subSpan:budget` token and there is no `subSpan.budget` stage.
//   2. onAppliesTheBlend — fixture bodies, switch on: every ingested body's
//      hit reports dense above 0, the control body (captured, not in the
//      corpus) stays at 0.
//   3. offNeverReachesTheEngine — 20 ingested records of 16,000 scalars
//      (the pool UnionBestBudgetStagesTests uses to exhaust the 1,024-window
//      budget), switch off: no `subSpan.budget` stage and no `subSpan:budget`
//      token, which the engine would have recorded had it been called.

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("Sub-span scoring switch", .serialized)
struct SubSpanScoringSwitchTests {

    private struct Fixture: Decodable {
        let query: String
        let limit: Int
        let ingested_bodies: [String]
        let control_body: String
    }

    /// Resolves Tests/Conformance/sub_span_scoring_switch_fixture.json
    /// relative to this file (Tests/GeniusLocusKitTests/).
    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("sub_span_scoring_switch_fixture.json")
    }

    private func loadFixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL()))
    }

    /// An estate with every body captured and the first `ingested` of them
    /// also in a standalone corpus registered on the estate. The
    /// deterministic model gives the corpus a hashed float lane, so sub-span
    /// windows can be scored without a real encoder. No vector store is
    /// registered; the whole-record float lane over the corpus fills the dense
    /// column for ingested bodies, and a body outside the corpus stays at 0.
    private func openEstate(
        bodies: [String], ingested: Int
    ) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-sub-span-switch")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusContentEngine(standaloneOn: corpusStorage, models: [.deterministic])
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        for (i, text) in bodies.enumerated() {
            let frame = CaptureFrame(
                content: text, channel: .typed, room: "sub-span-switch",
                latticeAnchor: .udc("000"), addedBy: "sub-span-switch",
                embeddingModelID: "test-model-v1")
            let drawer = try await kit.capture(handle, frame)
            if i < ingested {
                try await corpus.ingest(text, contentID: drawer.id, now: now)
            }
        }
        await kit.registerCorpus(corpus, for: handle)
        return (kit, handle)
    }

    private func request(
        query: String, limit: Int, subSpanScoring: GLKSubSpanScoring
    ) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(
                filterChain: [.unconfirmed], hydrationLevel: .full, ordering: .byCaptureTimeDesc),
            mode: .unionBest, scoring: .matrixAware, limit: limit,
            fallback: .failClosed, queryText: query, origin: .internal,
            subSpanScoring: subSpanScoring)
    }

    @Test("off leaves the dense column untouched")
    func offLeavesTheDenseColumnUntouched() async throws {
        let fixture = try loadFixture()
        try await withIntellectusLock {
            let bodies = fixture.ingested_bodies + [fixture.control_body]
            let (kit, handle) = try await openEstate(bodies: bodies, ingested: fixture.ingested_bodies.count)
            let result = try await kit.recall(
                handle, request(query: fixture.query, limit: fixture.limit, subSpanScoring: .off))
            #expect(result.hits.count == bodies.count, "the locus lane supplies every body at limit \(fixture.limit)")
            for hit in result.hits where hit.drawer?.content == fixture.control_body {
                #expect(hit.score.dense == 0,
                        "switch off: the control body has no corpus record and no blend runs, dense stays 0; got \(hit.score.dense)")
            }
            let flagged = result.hits.filter { hit in
                hit.explanation.contains { $0.hasPrefix("score:") && $0.contains(" subSpan:budget") }
            }.count
            #expect(flagged == 0, "switch off: no hit carries the sub-span budget token")
            #expect(!result.degradedStages.contains("subSpan.budget"),
                    "the engine was not called, so no budget stage; stages: \(result.degradedStages)")
        }
    }

    @Test("on applies the max-cosine blend to the ingested candidates")
    func onAppliesTheBlend() async throws {
        let fixture = try loadFixture()
        try await withIntellectusLock {
            let bodies = fixture.ingested_bodies + [fixture.control_body]
            let (kit, handle) = try await openEstate(bodies: bodies, ingested: fixture.ingested_bodies.count)
            let result = try await kit.recall(
                handle, request(query: fixture.query, limit: fixture.limit, subSpanScoring: .on))
            #expect(result.hits.count == bodies.count, "the locus lane supplies every body at limit \(fixture.limit)")
            let ingested = Set(fixture.ingested_bodies)
            for hit in result.hits {
                let content = hit.drawer?.content ?? ""
                if ingested.contains(content) {
                    #expect(hit.score.dense > 0,
                            "switch on: the sub-span max-cosine raised the dense column; got 0 for \(content)")
                } else {
                    #expect(content == fixture.control_body, "unexpected hit \(content)")
                    #expect(hit.score.dense == 0,
                            "the control body has no corpus record, so the blend leaves it at 0; got \(hit.score.dense)")
                }
            }
        }
    }

    @Test("off never reaches the engine, even over a pool that would exhaust the window budget")
    func offNeverReachesTheEngine() async throws {
        try await withIntellectusLock {
            let count = 20
            let bodies = (0..<count).map {
                UnionBestBudgetStagesTests.longBody($0, scalars: 16_000)
            }
            let (kit, handle) = try await openEstate(bodies: bodies, ingested: count)
            let result = try await kit.recall(
                handle, request(query: UnionBestBudgetStagesTests.query, limit: count, subSpanScoring: .off))
            #expect(!result.hits.isEmpty)
            #expect(!result.degradedStages.contains("subSpan.budget"),
                    "switch off: 1,700-odd windows were never offered to the budget; stages: \(result.degradedStages)")
            let flagged = result.hits.filter { hit in
                hit.explanation.contains { $0.hasPrefix("score:") && $0.contains(" subSpan:budget") }
            }.count
            #expect(flagged == 0, "no hit carries the budget token when the step does not run")
        }
    }
}
