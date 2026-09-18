// RecallUnionProfileSeedTests.swift
//
// Pins for the `RecallUnionProfile` a unionBest `.matrixAware` recall returns.
// Parity peer of Rust recall_union_profile_seed_parity.rs.
//
// recallUnionBest step 7 computes the profile from the step 6 normalised
// buffer, and the profile's redundancy and matrixCoherence read the top 16
// candidates by `buffer.final`, the max over the per-lane hit finals (locus
// ramp, graph 0.5, BM25 score, Hamming similarity, dense cosine plus consensus
// boost). On a buffer of more than 16 candidates whose top 16 by `final`
// differs from its top 16 by locus, the profile differs from one seeded with
// the locus column alone. These values are the contract the Rust matrixAware
// branch reports.
//
// Tests:
//  1. matrixAwareProfileOnTextFreeEstate: three drawers, no query text: the
//     profile is the locus-only profile (sharpness of the 1.0 / 0.5 / 0.0
//     column, agreement 1.0, redundancy 1.0, coherence 0). A control: with the
//     locus lane alone `final` equals the locus column in both ports.
//  2. matrixAwareProfileReadsTheLaneMaxFinalOnTextEstate: twenty drawers with
//     a corpus; sixteen carry the query word and a few filler words, four
//     carry no query word and a long body. The newest drawer is a query
//     drawer, the next four newest are the quiet drawers, so the top 16 by
//     locus holds every quiet drawer while the top 16 by `final` (the dense
//     cosine, 0.99 or 1.00 for every query drawer, above every quiet ramp)
//     holds the sixteen query drawers only. Every query drawer carries the
//     same three source bits, so the redundancy over that top 16 is exactly
//     1.0; a locus-seeded `final` keeps the four quiet drawers (two bits) in
//     the top 16 and reports 0.8667 (six plus sixty-six full pairs plus
//     forty-eight cross pairs at two thirds, over one hundred twenty).

import Testing
import Foundation
import LocusKit
import CorpusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("Recall unionBest .matrixAware union profile: final is the lane max")
struct RecallUnionProfileSeedTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// The twenty drawer bodies, oldest first. Twin of the Rust `text_estate_contents`.
    static let textEstateContents: [String] = {
        var bodies: [String] = []
        for i in 0..<15 {
            let filler = Array(repeating: "word", count: i % 3 + 1).joined(separator: " ")
            bodies.append(String(format: "doc%02d queryword ", i) + filler)
        }
        let longFiller = Array(repeating: "filler", count: 80).joined(separator: " ")
        for j in 15..<19 {
            bodies.append("quiet\(j) \(longFiller)")
        }
        bodies.append("zdoc19 queryword word")
        return bodies
    }()

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
            room: "profile-seed-room",
            latticeAnchor: .udc("000"),
            addedBy: "profile-seed-tests",
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

    private func matrixAwareRequest(query: String? = nil) -> GLKRecallRequest {
        GLKRecallRequest(
            frame: activeFrame(),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 5,
            fallback: .allowDegraded,
            queryText: query,
            origin: .internal
        )
    }

    /// Twenty drawers with a corpus and no vector store, captured oldest first
    /// in this order: query drawers doc00 to doc14, quiet drawers quiet15 to
    /// quiet18, then the newest query drawer zdoc19. A query drawer is its name,
    /// "queryword" and one to three filler words, so its dense cosine to the
    /// one-word query quantises to 0.99 or 1.00. A quiet drawer is its name and
    /// eighty filler words, so it is absent from the BM25 lane and its dense
    /// cosine is far from the query. The locus ramp at frontierK 64 is 1.0 for
    /// zdoc19, then 0.984375, 0.96875, 0.953125 and 0.9375 for the quiet
    /// drawers, so the top 16 by locus holds all four quiet drawers while the
    /// top 16 by `final` holds the sixteen query drawers and none of them.
    /// Content strings sort the same way as capture time, so the stable locus
    /// sort is fixed even when two captures share a timestamp.
    private func openTextEstate() async throws -> (kit: GeniusLocusKit, handle: EstateHandle, query: String) {
        let (kit, handle) = try await openEstate(owner: "owner-profile-seed-text")
        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusContentEngine(
            standaloneOn: corpusStorage,
            models: [.lsa(provider: HashFloatProvider(modelID: "test-miniLM-v1"))]
        )
        for (i, content) in Self.textEstateContents.enumerated() {
            let drawer = try await captureDrawer(content: content, kit: kit, handle: handle)
            try await corpus.ingest(content, contentID: drawer.id, now: Self.t0.addingTimeInterval(Double(i)))
        }
        await kit.registerCorpus(corpus, for: handle)
        return (kit, handle, "queryword")
    }

    private func describe(_ p: RecallUnionProfile) -> String {
        "locus=\(p.locusSharpness) bm25=\(p.bm25Sharpness) vector=\(p.vectorSharpness) agreement=\(p.signalAgreement) redundancy=\(p.redundancy) coherence=\(p.matrixCoherence)"
    }

    // MARK: - 1. Text-free control

    /// Twin of Rust `matrix_aware_profile_on_text_free_estate`.
    @Test("unionBest .matrixAware profile on a text-free three-drawer estate")
    func matrixAwareProfileOnTextFreeEstate() async throws {
        let (kit, handle) = try await openEstate(owner: "owner-profile-seed-text-free")
        _ = try await captureDrawer(content: "seed-1-oldest", kit: kit, handle: handle)
        _ = try await captureDrawer(content: "seed-2-middle", kit: kit, handle: handle)
        _ = try await captureDrawer(content: "seed-3-newest", kit: kit, handle: handle)

        let result = try await kit.recall(handle, matrixAwareRequest())
        let profile = try #require(result.unionProfile, "unionBest returns a profile")

        // Population standard deviation of the normalised locus column 1.0 / 0.5 / 0.0.
        let wantSharpness = Float((2.0 / 3.0).squareRoot() * 0.5)
        #expect(abs(profile.locusSharpness - wantSharpness) < 1e-5, "\(describe(profile))")
        #expect(profile.bm25Sharpness == 0, "\(describe(profile))")
        #expect(profile.vectorSharpness == 0, "\(describe(profile))")
        #expect(abs(profile.signalAgreement - 1.0) < 1e-6, "one lane supplied every candidate: \(describe(profile))")
        #expect(abs(profile.redundancy - 1.0) < 1e-6, "every candidate shares the one source mask: \(describe(profile))")
        #expect(profile.matrixCoherence == 0, "no matrix tier: \(describe(profile))")
    }

    // MARK: - 2. Text estate: the top 16 by final differs from the top 16 by locus

    /// Twin of Rust `matrix_aware_profile_reads_the_lane_max_final_on_text_estate`.
    @Test("unionBest .matrixAware profile reads the top 16 by the lane-max final")
    func matrixAwareProfileReadsTheLaneMaxFinalOnTextEstate() async throws {
        let (kit, handle, query) = try await openTextEstate()

        let result = try await kit.recall(handle, matrixAwareRequest(query: query))
        let profile = try #require(result.unionProfile, "unionBest returns a profile")

        #expect(!result.hits.isEmpty, "the recall returns hits")
        // Three supply lanes (locus, bm25, dense); sixteen candidates carry all
        // three bits and four carry two: (16 * 3 + 4 * 2) / (20 * 3).
        #expect(abs(profile.signalAgreement - 56.0 / 60.0) < 1e-5, "\(describe(profile))")
        // The top 16 by `final` is the sixteen query drawers, one source mask.
        #expect(abs(profile.redundancy - 1.0) < 1e-6, "\(describe(profile))")
        // Locus column: twenty ramp values, normalised to i / 19; population
        // standard deviation of that column.
        let wantLocusSharpness = Float((Double(20 * 20 - 1) / 12.0).squareRoot() / 19.0)
        #expect(abs(profile.locusSharpness - wantLocusSharpness) < 1e-5, "\(describe(profile))")
        // BM25 column: sixteen scores and four zeros, normalised; the value the
        // Swift build produced, pinned in both ports.
        #expect(abs(profile.bm25Sharpness - 0.38824) < 2e-3, "\(describe(profile))")
        #expect(profile.vectorSharpness == 0, "no vector store: \(describe(profile))")
        #expect(profile.matrixCoherence == 0, "no matrix tier: \(describe(profile))")
    }
}
