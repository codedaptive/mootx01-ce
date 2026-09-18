// SpanRerankStageTests.swift
//
// The span rerank stage inside the unionBest lane (Encoder Rerank Program,
// contract sheet §8) on a 200-drawer in-memory estate with a corpus:
//
//   (a) `no_encoder` == today's `no_vector` order (the order before any encoder
//       existed) while an encoder is registered whose stage WOULD reorder the
//       head. Failure mode: the stage leaks into the ablation (no_encoder then
//       equals the balanced order instead).
//   (b) balanced runs the stage: the drawer the fake encoder scores rises to the
//       top of the result, carries its span bounds on the hit, and its `score:`
//       explain line carries the `span:<index>:<cosine>` token. `no_vector` with
//       an encoder registered runs the stage too (it only names the default
//       vector budget), so it equals balanced.
//   (c) the default fusion (nil shape) equals `no_vector`: the whole-record
//       vector column is out unless a shape asks for it.

import Foundation
import Testing
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("Span rerank stage in unionBest", .serialized)
struct SpanRerankStageTests {

    /// A query encoder that returns a fixed unit vector (dim 4) so the stage's
    /// cosines are decided entirely by the fake span rows below.
    private struct FixedEncoder: SpanRerankEncoding {
        let modelID = "minilm-l6-v2-w60"
        func encodeQuery(_ text: String) async throws -> [Float] { [1, 0, 0, 0] }
    }

    /// Span rows for exactly one drawer: one span whose cosine against the fixed
    /// query is 100 × 0.005 = 0.5. Every other drawer has no rows and keeps its
    /// lexical rank.
    private struct OneDrawerRows: SpanVectorReading {
        let itemID: String
        func spanVectors(itemIDs: [String], modelID: String) async throws -> [String: [SpanRerankVector]] {
            guard itemIDs.contains(itemID) else { return [:] }
            return [itemID: [SpanRerankVector(index: 2, int8: [100, 0, 0, 0], scale: 0.005, startWord: 60, endWord: 120)]]
        }
    }

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// 200 drawers. Every fourth drawer carries the query terms (`ledger`,
    /// `reconciled`, `clerk`) at differing document lengths so BM25 returns 50
    /// candidates with distinct scores; the rest are lexical noise. A term that
    /// appears in EVERY document has an IDF that quantises to a zero impact and
    /// produces no BM25 hit at all, so the query terms must stay rare.
    private func openEstate(owner ownerID: String) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let corpusStorage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusKit.CorpusContentEngine(
            standaloneOn: corpusStorage,
            models: [.lsa(provider: HashFloatProvider(modelID: "test-miniLM-v1"))])
        for i in 0..<200 {
            // Padding words vary the document length so BM25 scores spread
            // instead of tying; the query terms sit in every fourth drawer.
            let padding = (0..<(i % 9 + 1)).map { "filler\($0 + i)" }.joined(separator: " ")
            let content = i % 4 == 0
                ? "ledger note \(i) \(padding) reconciled by clerk \(i % 13)"
                : "invoice archive \(i) \(padding) filed by assistant \(i % 11)"
            let frame = CaptureFrame(content: content, channel: .typed, room: "span-stage-tests",
                                     latticeAnchor: .udc("000"), addedBy: "span-stage-tests",
                                     embeddingModelID: "test-model-v1")
            let drawer = try await kit.capture(handle, frame)
            try await corpus.ingest(content, contentID: drawer.id, now: Self.t0)
        }
        await kit.registerCorpus(corpus, for: handle)
        return (kit: kit, handle: handle)
    }

    private func request(_ shape: RecallShape?) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: RecallFrame(filterChain: [], hydrationLevel: .full, ordering: .byCaptureTimeDesc),
            mode: .unionBest, scoring: .matrixAware, limit: 20,
            fallback: .failClosed, queryText: "ledger reconciled clerk", origin: .internal,
            recallShape: shape)
    }

    @Test("(a)(b)(c) no_encoder tracks no_vector while balanced runs the stage")
    func noEncoderIsTheUnrerankedOrder() async throws {
        let (kit, handle) = try await openEstate(owner: "span-stage-owner")

        // The lexical order the stage would rerank: take the tenth hit of the
        // unreranked result as the drawer the fake encoder will lift.
        let before = try await kit.recall(handle, request(RecallShape.preset("no_encoder")))
        #expect(before.hits.count >= 20)
        // Pick a lexical candidate inside the encoder head that is NOT the
        // BM25 leader (rank 2...30 in the BM25 lane), so the stage has
        // something to lift. The fused order and the BM25 lane order differ
        // by fixture state, so the pick is by lane rank, not by position.
        let candidate = try #require(before.hits.dropFirst(1).first { hit in
            hit.sources.contains(.corpusBM25)
                && (before.laneRanks[hit.id]?["bm25"]).map { $0 > 1 && $0 <= 30 } == true
        })
        let target = candidate.id
        let bm25Rank = try #require(before.laneRanks[target]?["bm25"])
        #expect(before.hits.allSatisfy { $0.spanHit == nil })
        // (c) with no encoder registered, no_encoder, no_vector and the nil shape
        // are one order: the vector column is out by default.
        let noVectorBefore = try await kit.recall(handle, request(RecallShape.preset("no_vector")))
        let defaultBefore = try await kit.recall(handle, request(nil))
        #expect(noVectorBefore.hits.map(\.id) == before.hits.map(\.id))
        #expect(defaultBefore.hits.map(\.id) == before.hits.map(\.id))

        await kit.registerSpanRerank(FixedEncoder(), spanVectors: OneDrawerRows(itemID: target), head: 30, for: handle)

        let balanced = try await kit.recall(handle, request(nil))
        let noEncoder = try await kit.recall(handle, request(RecallShape.preset("no_encoder")))
        let noVector = try await kit.recall(handle, request(RecallShape.preset("no_vector")))

        // (a) the ablation skips the stage: identical to the order before the
        // encoder existed (today's no_vector order).
        #expect(noEncoder.hits.map(\.id) == before.hits.map(\.id))
        #expect(noEncoder.hits.allSatisfy { $0.spanHit == nil })
        #expect(!noEncoder.degradedStages.contains("spanRerank"))
        // no_vector only names the default budget; with an encoder it runs the
        // stage like balanced does.
        #expect(noVector.hits.map(\.id) == balanced.hits.map(\.id))

        // (b) balanced ran the stage: the only span-bearing drawer leads, with
        // its bounds on the hit and the token on the explain line.
        #expect(balanced.hits.first?.id == target)
        let lifted = try #require(balanced.hits.first)
        #expect(lifted.spanHit == SpanRerankHit(itemID: target, bestSpanIndex: 2, bestSpanStart: 60, bestSpanEnd: 120, cosine: 0.5, bm25Rank: bm25Rank))
        let scoreLine = try #require(lifted.explanation.first { $0.hasPrefix("score: ") })
        #expect(scoreLine.hasSuffix(" span:2:0.500"), "got \(scoreLine)")
        #expect(balanced.hits.dropFirst().allSatisfy { $0.spanHit == nil })
        #expect(balanced.hits.map(\.id) != noEncoder.hits.map(\.id))
        try await kit.close(handle)
    }

    @Test("isSpanRerankRegistered reflects span rerank registration lifecycle")
    func isSpanRerankRegisteredLifecycle() async throws {
        let (kit, handle) = try await openEstate(owner: "isprr-lifecycle")
        // Before any registration: not registered.
        // Extract via await before #expect (actor-isolated method).
        let beforeReg = await kit.isSpanRerankRegistered(for: handle)
        #expect(!beforeReg)
        // After registerSpanRerank with the fakes from this suite: registered.
        await kit.registerSpanRerank(
            FixedEncoder(),
            spanVectors: OneDrawerRows(itemID: "any"),
            head: 30,
            for: handle)
        let afterReg = await kit.isSpanRerankRegistered(for: handle)
        #expect(afterReg)
        // After close: not registered (the entry is dropped by the lifecycle).
        try await kit.close(handle)
        let afterClose = await kit.isSpanRerankRegistered(for: handle)
        #expect(!afterClose)
    }

    @Test("an encoder failure leaves the lexical order standing and names the stage")
    func encoderFailureDegrades() async throws {
        struct ThrowingEncoder: SpanRerankEncoding {
            struct Unavailable: Error {}
            let modelID = "minilm-l6-v2-w60"
            func encodeQuery(_ text: String) async throws -> [Float] { throw Unavailable() }
        }
        let (kit, handle) = try await openEstate(owner: "span-stage-throwing-owner")
        let before = try await kit.recall(handle, request(nil))
        await kit.registerSpanRerank(ThrowingEncoder(), spanVectors: OneDrawerRows(itemID: "none"), for: handle)
        let after = try await kit.recall(handle, request(nil))
        #expect(after.hits.map(\.id) == before.hits.map(\.id))
        #expect(after.degradedStages.contains("spanRerank"))
        try await kit.close(handle)
    }
}
