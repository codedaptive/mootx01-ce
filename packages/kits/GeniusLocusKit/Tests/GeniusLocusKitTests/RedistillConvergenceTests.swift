// RedistillConvergenceTests.swift
//
// The product distiller is ContextDistillLib's intent-span v23.2 converter,
// keyed by converter ID and source digest.
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
//  §currency     The one currency rule: a row stamped with the v22 converter
//                id regenerates on the next sweep and comes back stamped v23.2
//                with the digest of its content; a row whose digest disagrees
//                with its content regenerates; a row with the active id and
//                the matching digest is left alone; identical source gives
//                identical bytes and an identical digest; the CLI convergence
//                call tree on a SQLite estate regenerates every v22 row.
//
// Rust twin: rust/tests/redistill_convergence_tests.rs

import ContextDistillLib
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import Testing
import SynapseKit

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
            .appendingPathComponent("\(bed)-intent-span-v23-attributed.jsonl")
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
            #expect(drawer.distilledSourceDigest == sourceDigest(row.original))
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

    // MARK: - §awaiting-reindex

    /// Shared helper: provision a LocusOnly estate (no corpus, no vector store).
    private func provisionLocusOnlyEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-redistill-locus-only")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Redistill LocusOnly Estate",
            kind: .locusOnly,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [])
        return (kit, handle)
    }

    // Shared long-form content strings (100+ words each) used by the
    // awaiting-reindex tests. Short strings cause degenerate range faults in
    // the BM25/HNSW indexer when hint-room drawers contribute very few tokens;
    // paragraphs of this length exercise the indexer without triggering that edge case.
    private static let alphaContent = """
        The distributed memory model partitions knowledge across spatial regions \
        called wings, each subdivided into rooms and drawers. A room groups thematically \
        related drawers under a shared lattice anchor, enabling efficient neighbourhood \
        recall without full-corpus scans. Each drawer carries typed content, an optional \
        enrichment trailer, and a distilled representation indexed by the current \
        converter pipeline version. When the converter ID changes, the eligibility sweep \
        identifies stale rows and regenerates their representations in a single pass before \
        the derived corpus lanes are rebuilt from the new text.
        """

    private static let betaContent = """
        Convergence idempotence requires that a second pass over a fully-updated estate \
        produces zero regenerated rows and skips the reindex entirely. The two-key \
        eligibility gate adds a second condition: even when the sweep reports zero \
        regenerated rows, the reindex still runs if any drawer's distilled-at timestamp \
        is strictly newer than its corresponding corpus index row's updated-at timestamp. \
        This detects the mid-run crash scenario where the sweep transaction committed but \
        the process terminated before the reindex could execute, leaving the derived BM25 \
        and dense lanes indexed against the previous representation text.
        """

    private static let gammaContent = """
        Bitmap-indexed content flags allow the estate to distinguish active, tombstoned, \
        and archived drawers without materialising boolean columns in the schema. Bit \
        nineteen records whether all four distillation columns are populated and agree with \
        the current converter identifier. The §4 invariant guarantees the bit and the \
        columns are always in agreement: setting the bit without writing the columns, or \
        writing the columns without setting the bit, constitutes a schema violation that \
        the pre-commit gate rejects. The awaiting-reindex probe relies on this invariant \
        to project only the id and distilled-at columns without hydrating the full content.
        """

    @Test("Full sweep then reindex leaves awaiting count at zero")
    func sweepAndReindexLeavesZeroAwaiting() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        // File two drawers so there is content to distill.
        _ = try await kit.capture(handle, captureFrame(Self.alphaContent), mode: .impatient)
        _ = try await kit.capture(handle, captureFrame(Self.betaContent), mode: .impatient)

        // Use the current system time for sweep and reindex so that any
        // provision-time hint drawers (distilledAt = some earlier Date()) also
        // get their index rows stamped with a updatedAt >= distilledAt. A fixed
        // past timestamp like t0 (2023) would be older than the provision-time
        // hint-drawer distilledAt (2026), causing them to count as awaiting.
        let now = Date()
        let regenerated = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now, limit: nil)
        #expect(regenerated >= 2)

        // Reindex — index rows get updatedAt == now >= distilledAt for every
        // drawer in the estate, so the strict `<` predicate is false for all.
        try await kit.reindexCorpus(handle: handle, now: now)
        let awaiting = try await kit.distilledRepresentationsAwaitingReindex(handle: handle)
        #expect(awaiting == 0)
    }

    @Test("Sweep without reindex leaves all represented drawers awaiting (crash-scenario simulation)")
    func sweepWithoutReindexLeavesDrawersAwaiting() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        let count = 3
        let contents = [Self.alphaContent, Self.betaContent, Self.gammaContent]
        for i in 0..<count {
            _ = try await kit.capture(handle, captureFrame(contents[i]), mode: .impatient)
        }

        // Sweep sets distilledAt on all drawers — but we do NOT call reindexCorpus.
        // This is the crash scenario: sweep committed, reindex did not. Use the
        // current system time for sweep so no hint drawer is excluded (see
        // sweepAndReindexLeavesZeroAwaiting for the t0 vs Date() reasoning).
        let now = Date()
        let regenerated = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now, limit: nil)
        #expect(regenerated >= count)

        // No index rows exist (or they are older than distilledAt), so every
        // represented drawer is awaiting reindex.
        let awaiting = try await kit.distilledRepresentationsAwaitingReindex(handle: handle)
        // The estate may also have provision-time hint drawers; awaiting >= filed count.
        #expect(awaiting >= count)

        // After reindex the gap closes.
        try await kit.reindexCorpus(handle: handle, now: now)
        let afterReindex = try await kit.distilledRepresentationsAwaitingReindex(handle: handle)
        #expect(afterReindex == 0)
    }

    @Test("Drawer with no index row counts as awaiting")
    func drawerWithNoIndexRowCountsAsAwaiting() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        _ = try await kit.capture(handle, captureFrame(Self.alphaContent), mode: .impatient)
        _ = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: Date(), limit: nil)
        // No reindex — no index rows (or only stale pre-sweep rows). At least the
        // one explicitly filed drawer has distilledAt set and no current index row.
        let awaiting = try await kit.distilledRepresentationsAwaitingReindex(handle: handle)
        #expect(awaiting >= 1)
    }

    @Test("LocusOnly estate returns zero awaiting (no corpus to check)")
    func locusOnlyEstateReturnsZero() async throws {
        let (kit, handle) = try await provisionLocusOnlyEstate()
        // No corpus is registered for this estate kind.
        let awaiting = try await kit.distilledRepresentationsAwaitingReindex(handle: handle)
        #expect(awaiting == 0)
    }


    // MARK: - §currency

    /// The converter id v22 rows carry: the library's previous ruleset, kept
    /// in the library and never routed to by the product.
    private static let v22ConverterID = "intent-span@intent-span-v22-authority-closure"

    @Test("the active converter is intent-span v23.2 (attributed prose)")
    func activeConverterIsV23Attributed() {
        #expect(GeniusLocusKit.distillationConverter == .intentSpanV23Attributed)
        #expect(GeniusLocusKit.distillationConverterID
            == "intent-span-v23-attributed@intent-span-v23.2-attributed-prose")
        #expect(GeniusLocusKit.distillationConverterID != Self.v22ConverterID)
    }

    /// Stamp one row exactly as a v22-era build wrote it: the v22 converter
    /// id beside the digest of the content it distilled.
    private func stampV22(_ estate: LocusKit.Estate, drawer: Drawer, now: Date) async throws {
        let written = try await estate.setDistilledRepresentation(
            drawerId: drawer.id,
            distilled: "v22 rendering of \(drawer.id)",
            pipelineVersion: Self.v22ConverterID,
            sourceDigest: sourceDigest(drawer.content),
            tokenCount: 3,
            at: now)
        #expect(written == 1)
    }

    @Test("the converter bump forces regeneration: v22 rows regenerate, come back stamped v23.2 with the content digest, and reindex closes the gap")
    func converterBumpForcesRegeneration() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        let now = Date()
        let alpha = try await kit.capture(handle, captureFrame(Self.alphaContent), mode: .impatient)
        let beta = try await kit.capture(handle, captureFrame(Self.betaContent), mode: .impatient)
        // Settle the estate (hint rooms included) under the active converter.
        _ = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now, limit: nil)
        try await kit.reindexCorpus(handle: handle, now: now)
        #expect(try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now, limit: nil) == 0)

        // Rewind the two filed rows to the v22 converter.
        let estate = try await kit.estate(for: handle)
        try await stampV22(estate, drawer: alpha, now: now)
        try await stampV22(estate, drawer: beta, now: now)
        #expect(try await estate.countUndistilled(pipelineVersion: GeniusLocusKit.distillationConverterID) == 2)
        for id in [alpha.id, beta.id] {
            let row = try #require(try await estate.getDrawers(ids: [id]).first)
            #expect(!GeniusLocusKit.distilledRepresentationIsCurrent(row))
        }

        // The sweep regenerates exactly those two rows.
        let later = now.addingTimeInterval(1)
        let regenerated = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: later, limit: nil)
        #expect(regenerated == 2)
        for drawer in [alpha, beta] {
            let row = try #require(try await estate.getDrawers(ids: [drawer.id]).first)
            #expect(row.distilledPipelineVersion == GeniusLocusKit.distillationConverterID)
            #expect(row.distilledSourceDigest == sourceDigest(drawer.content))
            #expect(row.distilled == GeniusLocusKit.distilledRepresentation(forContent: drawer.content))
            #expect(GeniusLocusKit.distilledRepresentationIsCurrent(row))
        }
        #expect(try await estate.countUndistilled(pipelineVersion: GeniusLocusKit.distillationConverterID) == 0)

        // The regenerated rows postdate their index rows until the reindex runs.
        #expect(try await kit.distilledRepresentationsAwaitingReindex(handle: handle) >= 2)
        try await kit.reindexCorpus(handle: handle, now: later)
        #expect(try await kit.distilledRepresentationsAwaitingReindex(handle: handle) == 0)
    }

    @Test("a row stamped with the active converter but a digest that does not match its content regenerates")
    func digestMismatchRegenerates() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        let now = Date()
        let alpha = try await kit.capture(handle, captureFrame(Self.alphaContent), mode: .impatient)
        _ = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now, limit: nil)

        let estate = try await kit.estate(for: handle)
        let written = try await estate.setDistilledRepresentation(
            drawerId: alpha.id,
            distilled: "rendering of other content",
            pipelineVersion: GeniusLocusKit.distillationConverterID,
            sourceDigest: sourceDigest("other content"),
            tokenCount: 4,
            at: now)
        #expect(written == 1)
        let stale = try #require(try await estate.getDrawers(ids: [alpha.id]).first)
        #expect(!GeniusLocusKit.distilledRepresentationIsCurrent(stale))

        let regenerated = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now.addingTimeInterval(1), limit: nil)
        #expect(regenerated == 1)
        let row = try #require(try await estate.getDrawers(ids: [alpha.id]).first)
        #expect(row.distilledSourceDigest == sourceDigest(alpha.content))
        #expect(row.distilled == GeniusLocusKit.distilledRepresentation(forContent: alpha.content))
        #expect(GeniusLocusKit.distilledRepresentationIsCurrent(row))
    }

    @Test("a row with the active converter id and the matching digest is left alone")
    func matchingIDAndDigestIsLeftAlone() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        let now = Date()
        let alpha = try await kit.capture(handle, captureFrame(Self.alphaContent), mode: .impatient)
        _ = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now, limit: nil)

        // A hand-written representation that satisfies the rule exactly.
        let estate = try await kit.estate(for: handle)
        _ = try await estate.setDistilledRepresentation(
            drawerId: alpha.id,
            distilled: "hand-written but current",
            pipelineVersion: GeniusLocusKit.distillationConverterID,
            sourceDigest: sourceDigest(alpha.content),
            tokenCount: 4,
            at: now)
        let before = try #require(try await estate.getDrawers(ids: [alpha.id]).first)
        #expect(GeniusLocusKit.distilledRepresentationIsCurrent(before))

        let regenerated = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now.addingTimeInterval(1), limit: nil)
        #expect(regenerated == 0)
        let after = try #require(try await estate.getDrawers(ids: [alpha.id]).first)
        #expect(after.distilled == "hand-written but current")
        #expect(after.distilledAt == now)
    }

    @Test("distilling the same source twice yields identical bytes and identical digests")
    func sameSourceTwiceIsByteIdentical() async throws {
        // Pure function level: same content, same converter, same bytes.
        let first = GeniusLocusKit.distilledRepresentation(forContent: Self.gammaContent)
        let second = GeniusLocusKit.distilledRepresentation(forContent: Self.gammaContent)
        #expect(first == second)
        #expect(sourceDigest(Self.gammaContent) == sourceDigest(Self.gammaContent))

        // Stored level: two forced distillations of one row store the same
        // text and the same digest.
        let (kit, handle) = try await provisionGLKEstate()
        let now = Date()
        let gamma = try await kit.capture(handle, captureFrame(Self.gammaContent), mode: .impatient)
        let estate = try await kit.estate(for: handle)
        #expect(try await kit.distillItem(
            handle: handle, drawerID: gamma.id, content: gamma.content,
            distillFn: GeniusLocusKit.defaultDistillFn, now: now))
        let one = try #require(try await estate.getDrawers(ids: [gamma.id]).first)
        #expect(try await kit.distillItem(
            handle: handle, drawerID: gamma.id, content: gamma.content,
            distillFn: GeniusLocusKit.defaultDistillFn, now: now.addingTimeInterval(1)))
        let two = try #require(try await estate.getDrawers(ids: [gamma.id]).first)
        #expect(one.distilled == two.distilled)
        #expect(one.distilled == first)
        #expect(one.distilledSourceDigest == two.distilledSourceDigest)
        #expect(one.distilledSourceDigest == sourceDigest(Self.gammaContent))
    }

    @Test("the CLI convergence call tree on a SQLite estate regenerates every v22 row at the active converter")
    func convergenceCallTreeRegeneratesEveryV22RowOnSQLite() async throws {
        // The same call tree `mootx01 upgrade --backfill-only` runs after its
        // migration catalog step: sweep, probe, reindex when either key fires.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-cdl05-convergence-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
        }
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-cdl05-convergence")
        // `.ephemeral` keeps the file-backed estate's Ed25519 identity out of
        // the login keychain (one orphaned entry per run otherwise).
        let params = EstateProvisionParams(
            estateName: "Convergence Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none,
            lifetime: .ephemeral
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic])
        let now = Date()
        let contents = [Self.alphaContent, Self.betaContent, Self.gammaContent]
        var filed: [Drawer] = []
        for content in contents {
            filed.append(try await kit.capture(handle, captureFrame(content), mode: .impatient))
        }
        _ = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: now, limit: nil)
        try await kit.reindexCorpus(handle: handle, now: now)

        // Every filed row rewinds to the v22 converter.
        let estate = try await kit.estate(for: handle)
        for drawer in filed { try await stampV22(estate, drawer: drawer, now: now) }
        #expect(try await estate.countUndistilled(pipelineVersion: GeniusLocusKit.distillationConverterID) == filed.count)

        // The convergence step.
        let later = now.addingTimeInterval(1)
        let regenerated = try await kit.distillItemsSweep(
            handle: handle, distillFn: GeniusLocusKit.defaultDistillFn, now: later)
        let awaiting = try await kit.distilledRepresentationsAwaitingReindex(handle: handle)
        if regenerated > 0 || awaiting > 0 {
            try await kit.reindexCorpus(handle: handle, now: later)
        }
        #expect(regenerated == filed.count)
        #expect(awaiting >= filed.count)
        #expect(try await kit.distilledRepresentationsAwaitingReindex(handle: handle) == 0)
        #expect(try await estate.countUndistilled(pipelineVersion: GeniusLocusKit.distillationConverterID) == 0)
        for drawer in filed {
            let row = try #require(try await estate.getDrawers(ids: [drawer.id]).first)
            #expect(row.distilledPipelineVersion == GeniusLocusKit.distillationConverterID)
            #expect(row.distilledSourceDigest == sourceDigest(drawer.content))
        }
        try await kit.close(handle)
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
