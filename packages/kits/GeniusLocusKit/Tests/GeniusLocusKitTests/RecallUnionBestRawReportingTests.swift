// RecallUnionBestRawReportingTests.swift
//
// Pins for the score columns a unionBest hit reports under `.raw` and `.rrf`.
// Parity peer of Rust recall_union_best_raw_reporting_parity.rs.
//
// recallUnionBest builds one candidate buffer, min-max normalises every column
// at step 6 and, for `.raw` and `.rrf`, scores each candidate from the
// normalised `buffer.final` (the max over the per-lane finals). Step 11 reports
// the normalised columns and that score on every hit. These values are the
// contract the Rust rrf/raw branch reports.
//
// Tests:
//  1. rawAndRrfReportNormalisedLocusAndFinalOnTextFreeEstate: three drawers,
//     no query text: locus 1.0 / 0.5 / 0.0 and final 1.0 / 0.5 / 0.0
//     (newest / middle / oldest) under both scorings, and the two result sets
//     are identical.
//  2. rawAndRrfReportTheSameNormalisedColumnsOnTextQuery: six drawers with a
//     corpus and a vector store, a query that lights the BM25, Hamming and dense
//     lanes: `.raw` and `.rrf` return the same ids in the same order with the
//     same score vectors, every reported column is in [0, 1], and the top final
//     is exactly 1.0.

import Testing
import Foundation
import LocusKit
import CorpusKit
import SynapseKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("Recall unionBest raw and rrf score reporting: normalised buffer columns")
struct RecallUnionBestRawReportingTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let textDrawerCount = 6

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
            room: "raw-reporting-room",
            latticeAnchor: .udc("000"),
            addedBy: "raw-reporting-tests",
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

    private func unionBestRequest(scoring: GLKRecallScoring, query: String? = nil) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: activeFrame(),
            mode: .unionBest,
            scoring: scoring,
            limit: 20,
            fallback: .allowDegraded,
            queryText: query,
            origin: .internal
        )
    }

    /// Six drawers with a corpus and a vector store. Drawer i carries the shared
    /// query word and i + 1 filler words, so BM25, Hamming and dense all rank
    /// the drawers and the lanes disagree on the order. The inference is the
    /// token-count direction the anti-similar fixture uses, so the dense lane
    /// orders the drawers without ties.
    private func openTextEstate() async throws -> (kit: GeniusLocusKit, handle: EstateHandle, query: String) {
        let (kit, handle) = try await openEstate(owner: "owner-raw-reporting-text")
        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusContentEngine(
            standaloneOn: corpusStorage,
            models: [.lsa(provider: HashFloatProvider(modelID: "test-miniLM-v1"))]
        )
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let hammingModelID = await corpus.modelID
        for i in 0..<Self.textDrawerCount {
            let filler = Array(repeating: "word", count: i + 1).joined(separator: " ")
            let content = "doc\(i) queryword \(filler)"
            let drawer = try await captureDrawer(content: content, kit: kit, handle: handle)
            try await corpus.ingest(content, contentID: drawer.id, now: Self.t0)
            let engram = try await corpus.embed(content)
            try await vectorStore.addVector(
                itemID: drawer.id, engram: engram, modelID: hammingModelID,
                modelVersion: "1.0", filedAt: Self.t0)
        }
        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle, "queryword")
    }

    private func columns(_ result: GLKRecallResult) -> [(id: String, cols: [Float])] {
        result.hits.map { ($0.id, [$0.score.locus, $0.score.bm25, $0.score.vector, $0.score.dense, $0.score.final]) }
    }

    private func sameColumns(_ a: GLKRecallResult, _ b: GLKRecallResult) -> Bool {
        let ca = columns(a), cb = columns(b)
        guard ca.count == cb.count else { return false }
        return zip(ca, cb).allSatisfy { $0.id == $1.id && $0.cols == $1.cols }
    }

    // MARK: - 1. Text-free three-drawer estate: locus and final read 1.0 / 0.5 / 0.0

    /// Twin of Rust `raw_and_rrf_report_normalised_locus_and_final_on_text_free_estate`.
    @Test("unionBest .raw and .rrf report the normalised locus and final columns: 1.0 / 0.5 / 0.0")
    func rawAndRrfReportNormalisedLocusAndFinalOnTextFreeEstate() async throws {
        let (kit, handle) = try await openEstate(owner: "owner-raw-reporting-text-free")

        // Content strings sort the same way as capture time (content DESC is the
        // final tiebreak of the stable locus sort), so the slice order is fixed.
        let oldest = try await captureDrawer(content: "report-1-oldest", kit: kit, handle: handle)
        let middle = try await captureDrawer(content: "report-2-middle", kit: kit, handle: handle)
        let newest = try await captureDrawer(content: "report-3-newest", kit: kit, handle: handle)

        let raw = try await kit.recall(handle, unionBestRequest(scoring: .raw))
        let rrf = try await kit.recall(handle, unionBestRequest(scoring: .rrf))

        for (label, result) in [("raw", raw), ("rrf", rrf)] {
            #expect(result.hits.count == 3, "\(label): all three drawers must surface (got \(result.hits.count))")
            func hit(_ id: String) -> RecallHit? { result.hits.first { $0.id == id } }
            for (name, id, want) in [("newest", newest.id, Float(1.0)), ("middle", middle.id, 0.5), ("oldest", oldest.id, 0.0)] {
                let locus = hit(id)?.score.locus ?? .nan
                let final = hit(id)?.score.final ?? .nan
                #expect(abs(locus - want) < 1e-4, "\(label) \(name): locus got \(locus), want \(want)")
                #expect(abs(final - want) < 1e-4, "\(label) \(name): final got \(final), want \(want)")
            }
        }
        #expect(sameColumns(raw, rrf), "rrf on unionBest is the raw path: same hits, same columns")
        #expect(rrf.degradedStages.contains("unionBest.rrf"),
                "rrf on unionBest records its fallback (got \(rrf.degradedStages))")
    }

    // MARK: - 2. Text query: raw equals rrf, every column normalised, top final 1.0

    /// Twin of Rust `raw_and_rrf_report_the_same_normalised_columns_on_text_query`.
    @Test("unionBest .raw and .rrf report the same normalised columns on a text query")
    func rawAndRrfReportTheSameNormalisedColumnsOnTextQuery() async throws {
        let (kit, handle, query) = try await openTextEstate()

        let raw = try await kit.recall(handle, unionBestRequest(scoring: .raw, query: query))
        let rrf = try await kit.recall(handle, unionBestRequest(scoring: .rrf, query: query))

        #expect(raw.hits.count == Self.textDrawerCount, "every drawer matches the query (got \(raw.hits.count))")
        #expect(raw.hits.contains { $0.score.bm25 > 0 },
                "the BM25 lane must contribute a column (got \(columns(raw)))")
        #expect(sameColumns(raw, rrf), "rrf on unionBest is the raw path: same ids, order and columns")

        var topFinal: Float = -.greatestFiniteMagnitude
        for hit in raw.hits {
            for (name, v) in [("locus", hit.score.locus), ("bm25", hit.score.bm25), ("vector", hit.score.vector),
                              ("dense", hit.score.dense), ("final", hit.score.final)] {
                #expect((0...1).contains(v), "\(hit.id): \(name) column \(v) is outside [0, 1]")
            }
            topFinal = max(topFinal, hit.score.final)
        }
        #expect(abs(topFinal - 1.0) < 1e-6, "the normalised final column peaks at exactly 1.0 (got \(topFinal))")
    }
}
