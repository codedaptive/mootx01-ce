// RedistillConvergenceTests.swift
//
// CDL-02: the product distiller is ContextDistillLib, keyed by converter ID.
//
//  §end-to-end   Filing the Debug-7 oracle originals into a corpus-wired
//                estate and running the sweep stores exactly the oracle's
//                representation under the current converter ID; the forced
//                redistill sweep rewrites every row; the full derived-lane
//                reindex leaves the rows reachable through the dense lane.
//  §trailer-parity  REPORTED, not gated: for every locomo-272 oracle row,
//                EnrichmentStage.trailer(forContent:) is compared with the
//                trailer the artifact estates stored under p2.3. A mismatch
//                means the regenerated trailer differs from the stored one and
//                is a finding for review, not a test failure.
//
// Rust twin: rust/tests/redistill_convergence_tests.rs

import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
import VectorKit

@testable import GeniusLocusKit

@Suite("Redistill convergence (CDL-02)")
struct RedistillConvergenceTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// One oracle row: the source content, the trailer the artifact stored
    /// under p2.3, and the representation the frozen converter produced.
    private struct OracleRow: Decodable {
        let original: String
        let enrichmentTrailer: String
        let aiText: String
        enum CodingKeys: String, CodingKey {
            case original
            case enrichmentTrailer = "enrichment_trailer"
            case aiText = "ai_text"
        }
    }

    /// The oracle vector beds live in the library's test tree; this package
    /// reads them by repository-relative path from this file.
    private static func oracleRows(bed: String) throws -> [OracleRow] {
        let here = URL(fileURLWithPath: #filePath)
        let vectors = here
            .deletingLastPathComponent()   // GeniusLocusKitTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // GeniusLocusKit/
            .deletingLastPathComponent()   // kits/
            .deletingLastPathComponent()   // packages/
            .appendingPathComponent("libs/ContextDistillLib/Tests/ContextDistillLibTests/Vectors")
            .appendingPathComponent("\(bed)-intent-span-v22.jsonl")
        let text = try String(contentsOf: vectors, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(OracleRow.self, from: Data($0.utf8)) }
    }

    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-redistill-convergence")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Redistill Convergence Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        return (kit, handle)
    }

    private func captureFrame(_ content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "redistill-convergence-tests",
            latticeAnchor: .udc("000"),
            addedBy: "redistill-convergence-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    private func denseHits(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, queryText: String
    ) async throws -> [RecallHit] {
        let request = GLKRecallRequest(
            frame: RecallFrame(filterChain: [], hydrationLevel: .full, limit: 20),
            mode: .unionBest,
            scoring: .matrixAware,
            limit: 20,
            fallback: .allowDegraded,
            queryText: queryText,
            origin: .external
        )
        return try await kit.recall(handle, request).hits.filter { $0.score.dense > 0 }
    }

    // MARK: - §end-to-end

    @Test("Debug-7 originals distill to the oracle representation, redistill rewrites every row, reindex keeps them dense-reachable")
    func debug7EndToEnd() async throws {
        let rows = try Self.oracleRows(bed: "debug7")
        #expect(rows.count == 7)
        let (kit, handle) = try await provisionGLKEstate()

        var ids: [String] = []
        for row in rows {
            let drawer = try await kit.capture(handle, captureFrame(row.original), mode: .impatient)
            ids.append(drawer.id)
        }

        // Eligibility sweep: every row is undistilled, so all seven regenerate.
        let produced = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: t0, limit: nil)
        #expect(produced == 7)

        let estate = try await kit.estate(for: handle)
        for (row, id) in zip(rows, ids) {
            let drawer = try #require(try await estate.getDrawers(ids: [id]).first)
            // The product contract: the stored text is the converter's
            // representation of the content with the REGENERATED trailer.
            let expected = GeniusLocusKit.distilledRepresentation(forContent: row.original)
            #expect(drawer.distilled == expected, "stored text is the converter's representation for \(id)")
            #expect(drawer.distilledPipelineVersion == GeniusLocusKit.distillationConverterID)
            #expect(drawer.distilledTokenCount == GeniusLocusKit.distilledTokenCount(expected))
            // Oracle equality holds exactly when the regenerated trailer equals
            // the trailer the artifact stored under p2.3 (the parity report
            // counts those rows); the library's own conformance suite already
            // pins the converter to the oracle for the stored trailer.
            if EnrichmentStage.trailer(forContent: row.original)
                .trimmingCharacters(in: .whitespaces) == row.enrichmentTrailer {
                #expect(expected == row.aiText, "oracle equality for \(id)")
            }
        }

        // Converged estate: a second eligibility sweep regenerates nothing.
        let again = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: t0, limit: nil)
        #expect(again == 0)

        // The forced sweep behind moot_redistill rewrites every active
        // non-empty row regardless — the seven filed here plus whatever the
        // provisioned estate seeded (hint rooms), so compare against the
        // estate's own count rather than a literal.
        var activeNonEmpty = 0
        var cursor: String? = nil
        while true {
            let page = try await estate.activeDrawersAfter(id: cursor, limit: 500)
            if page.isEmpty { break }
            activeNonEmpty += page.filter { !$0.content.isEmpty }.count
            cursor = page.last?.id
            if page.count < 500 { break }
        }
        let forced = try await kit.redistillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: t0, limit: nil)
        #expect(forced == activeNonEmpty)
        #expect(forced >= 7)

        // Full derived-lane reindex, then every row is reachable via the dense lane
        // by its own representation.
        try await kit.reindexCorpus(handle: handle, now: t0)
        for (row, id) in zip(rows, ids) {
            let hits = try await denseHits(
                kit, handle, queryText: GeniusLocusKit.distilledRepresentation(forContent: row.original))
            #expect(hits.contains { $0.id == id }, "dense lane serves \(id) after reindex")
        }
    }

    // MARK: - §trailer-parity (reported)

    /// REPORTED, not gated: the regenerated enrichment trailer versus the
    /// trailer the artifact estates stored under p2.3, per oracle bed.
    private func trailerParityReport(bed: String, expectedRows: Int) throws {
        let rows = try Self.oracleRows(bed: bed)
        #expect(rows.count == expectedRows)
        var identical = 0
        var mismatches: [(stored: String, regenerated: String)] = []
        for row in rows {
            // EnrichmentStage returns the block with its leading space; the
            // oracle stores the stripped block.
            let regenerated = EnrichmentStage.trailer(forContent: row.original)
                .trimmingCharacters(in: .whitespaces)
            if regenerated == row.enrichmentTrailer {
                identical += 1
            } else {
                mismatches.append((row.enrichmentTrailer, regenerated))
            }
        }
        print("TRAILER PARITY \(bed)-\(expectedRows): identical=\(identical) mismatched=\(mismatches.count)")
        for (i, m) in mismatches.prefix(5).enumerated() {
            print("  mismatch \(i + 1): stored=\(m.stored.prefix(200)) | regenerated=\(m.regenerated.prefix(200))")
        }
        // Reported, not gated: the numbers above are the deliverable.
        #expect(identical + mismatches.count == expectedRows)
    }

    @Test("debug7: regenerated enrichment trailers versus stored (REPORTED)")
    func debug7TrailerParityReport() throws { try trailerParityReport(bed: "debug7", expectedRows: 7) }

    @Test("sample30: regenerated enrichment trailers versus stored (REPORTED)")
    func sample30TrailerParityReport() throws { try trailerParityReport(bed: "sample30", expectedRows: 30) }

    @Test("locomo-272: regenerated enrichment trailers versus stored (REPORTED)")
    func locomoTrailerParityReport() throws { try trailerParityReport(bed: "locomo", expectedRows: 272) }
}
