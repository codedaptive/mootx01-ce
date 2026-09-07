// RecallHybridRawMergeTests.swift
//
// Pins for the hit order and `final` score a hybrid or corpusOnly recall
// reports under `.raw`. Parity peer of Rust recall_hybrid_raw_merge_parity.rs.
//
// recallHybrid `.raw` performs no fusion: it merges the locus list, then the
// BM25 list, then the vector list, in that order, dedups by id and takes
// `prefix(limit)`. Each hit's `final` is the score of the list it entered from,
// so a hit the locus lane supplied carries the locus ramp `(frontierK - rank) /
// frontierK`. recallCorpusOnly `.raw` is the same merge over BM25 then vector.
//
// Tests:
//  1. hybridRawReturnsTheLocusOrderOnTextFreeEstate: three drawers, no corpus:
//     capture-time DESC order with final 1.0 / 0.984375 / 0.96875 at
//     frontierK 64. A control: the Rust no-corpus fallback already agrees.
//  2. hybridRawReturnsTheLocusOrderAndRampOnTextEstate: six drawers with a
//     corpus and a vector store, a query every drawer matches: the hybrid
//     `.raw` order is the locus order (newest first) and every final is the
//     locus ramp. A lane sum reads above 1.0 and orders by BM25 strength.
//  3. corpusOnlyRawReturnsTheBm25OrderOnTextEstate: the same estate under
//     corpusOnly `.raw`: finals are non-increasing and each equals the hit's
//     BM25 column. A lane sum adds the Hamming similarity to every final.

import Testing
import Foundation
import LocusKit
import CorpusKit
import SynapseKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("Recall hybrid and corpusOnly .raw: ordered list merge, lane score as final")
struct RecallHybridRawMergeTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let textDrawerCount = 6
    /// `min(max(limit * 4, 64), 256)` for every limit at or below 16.
    private static let frontierK = 64

    // MARK: - Estate factory

    private func openEstate(owner ownerID: String) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func captureDrawer(content: String, kit: GeniusLocusKit, handle: EstateHandle) async throws -> Drawer {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "raw-merge-room",
            latticeAnchor: .udc("000"),
            addedBy: "raw-merge-tests",
            embeddingModelID: "test-model-v1"
        )
        return try await kit.capture(handle, frame)
    }

    /// Recall frame matching every currently-believed row.
    private func activeFrame() -> RecallFrame {
        RecallFrame(
            filterChain: [.unconfirmed],
            hydrationLevel: .structured,
            ordering: .byCaptureTimeDesc
        )
    }

    private func rawRequest(mode: GLKRecallMode, limit: Int, query: String? = nil) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: activeFrame(),
            mode: mode,
            scoring: .raw,
            limit: limit,
            fallback: .allowDegraded,
            queryText: query,
            origin: .internal
        )
    }

    /// The locus ramp for a zero-based rank at the default frontier.
    private func ramp(_ rank: Int) -> Float {
        Float(Self.frontierK - rank) / Float(Self.frontierK)
    }

    /// Six drawers with a corpus and a vector store, oldest first. Drawer i
    /// carries the shared query word and i + 1 filler words, so BM25 ranks the
    /// shorter (older) drawers first, the opposite of the locus order. Content
    /// strings sort the same way as capture time, so the stable locus sort is
    /// fixed even when two captures share a timestamp.
    private func openTextEstate() async throws -> (kit: GeniusLocusKit, handle: EstateHandle, ids: [String], query: String) {
        let (kit, handle) = try await openEstate(owner: "owner-raw-merge-text")
        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusContentEngine(
            standaloneOn: corpusStorage,
            models: [.miniLM(inference: { tokens in
                let theta = Float(tokens.count) * 0.018
                var v = Array(repeating: Float(0), count: 384)
                v[0] = Foundation.cos(theta)
                v[1] = Foundation.sin(theta)
                return v
            })]
        )
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let hammingModelID = await corpus.modelID
        var ids: [String] = []
        for i in 0..<Self.textDrawerCount {
            let filler = Array(repeating: "word", count: i + 1).joined(separator: " ")
            let content = "doc\(i) queryword \(filler)"
            let drawer = try await captureDrawer(content: content, kit: kit, handle: handle)
            try await corpus.ingest(content, contentID: drawer.id, now: Self.t0)
            let engram = try await corpus.embed(content)
            try await vectorStore.addVector(
                itemID: drawer.id, engram: engram, modelID: hammingModelID,
                modelVersion: "1.0", filedAt: Self.t0)
            ids.append(drawer.id)
        }
        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle, ids, "queryword")
    }

    // MARK: - 1. Text-free control: the locus order and ramp

    /// Twin of Rust `hybrid_raw_returns_the_locus_order_on_text_free_estate`.
    @Test("hybrid .raw without a corpus returns the locus order with the ramp as final")
    func hybridRawReturnsTheLocusOrderOnTextFreeEstate() async throws {
        let (kit, handle) = try await openEstate(owner: "owner-raw-merge-text-free")
        let oldest = try await captureDrawer(content: "merge-1-oldest", kit: kit, handle: handle)
        let middle = try await captureDrawer(content: "merge-2-middle", kit: kit, handle: handle)
        let newest = try await captureDrawer(content: "merge-3-newest", kit: kit, handle: handle)

        let result = try await kit.recall(handle, rawRequest(mode: .hybrid, limit: 10))

        #expect(result.hits.map(\.id) == [newest.id, middle.id, oldest.id],
                "hybrid .raw is the locus order, newest first (got \(result.hits.map(\.id)))")
        for (rank, hit) in result.hits.enumerated() {
            #expect(abs(hit.score.final - ramp(rank)) < 1e-6,
                    "rank \(rank): final got \(hit.score.final), want \(ramp(rank))")
        }
    }

    // MARK: - 2. Text estate: hybrid .raw is the locus list first

    /// Twin of Rust `hybrid_raw_returns_the_locus_order_and_ramp_on_text_estate`.
    @Test("hybrid .raw on a text query returns the locus order and the locus ramp as final")
    func hybridRawReturnsTheLocusOrderAndRampOnTextEstate() async throws {
        let (kit, handle, ids, query) = try await openTextEstate()

        let result = try await kit.recall(handle, rawRequest(mode: .hybrid, limit: 10, query: query))

        let wantOrder = Array(ids.reversed())
        #expect(result.hits.map(\.id) == wantOrder,
                "hybrid .raw merges the locus list first, so the order is newest first (got \(result.hits.map(\.id)))")
        #expect(result.hits.contains { $0.sources.contains(.corpusBM25) },
                "the BM25 lane must have run (sources \(result.hits.map(\.sources)))")
        for (rank, hit) in result.hits.enumerated() {
            #expect(abs(hit.score.final - ramp(rank)) < 1e-6,
                    "rank \(rank): final is the locus ramp \(ramp(rank)), got \(hit.score.final)")
            #expect(hit.score.final <= 1.0, "a merged final never exceeds the lane score (got \(hit.score.final))")
        }

        // The limit truncates the merged list, never re-sorts it.
        let three = try await kit.recall(handle, rawRequest(mode: .hybrid, limit: 3, query: query))
        #expect(three.hits.map(\.id) == Array(wantOrder.prefix(3)),
                "limit 3 keeps the three newest (got \(three.hits.map(\.id)))")
    }

    // MARK: - 3. Text estate: corpusOnly .raw is the BM25 list first

    /// Twin of Rust `corpus_only_raw_returns_the_bm25_order_on_text_estate`.
    @Test("corpusOnly .raw on a text query returns the BM25 order with the BM25 score as final")
    func corpusOnlyRawReturnsTheBm25OrderOnTextEstate() async throws {
        let (kit, handle, ids, query) = try await openTextEstate()

        let result = try await kit.recall(handle, rawRequest(mode: .corpusOnly, limit: 10, query: query))

        #expect(result.hits.count == Self.textDrawerCount, "every drawer matches the query (got \(result.hits.count))")
        #expect(Set(result.hits.map(\.id)) == Set(ids), "the same six drawers surface")
        var previous: Float = .greatestFiniteMagnitude
        for hit in result.hits {
            #expect(hit.sources.contains(.corpusBM25), "\(hit.id): a BM25 hit (sources \(hit.sources))")
            #expect(hit.score.final > 0, "\(hit.id): a BM25 score is positive (got \(hit.score.final))")
            #expect(abs(hit.score.final - hit.score.bm25) < 1e-6,
                    "\(hit.id): final is the BM25 lane score \(hit.score.bm25), got \(hit.score.final)")
            #expect(hit.score.final <= previous, "\(hit.id): BM25 order is non-increasing")
            previous = hit.score.final
        }
        // BM25 prefers the shorter drawers, so the oldest drawer leads.
        #expect(result.hits.first?.id == ids.first, "the shortest drawer ranks first under BM25")
    }
}
