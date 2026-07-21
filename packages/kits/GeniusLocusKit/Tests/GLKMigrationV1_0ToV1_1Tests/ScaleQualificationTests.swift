#if GLK_MIGRATION_V1_0_TO_V1_1

// ScaleQualificationTests.swift
//
// Shared-content 1.1 P6 — large-estate migration qualification driver
// (Swift leg; Rust twin: rust/tests/scale_qualification.rs).
//
// NOT part of any CI lane: the test returns immediately unless the
// MOOT_SCF_QUAL_DB environment variable names a RECOVERABLE CLONE of a real
// legacy estate (never point it at a live estate — the migration rewrites
// the corpus lane in place). Run it explicitly:
//
//   MOOT_SCF_QUAL_DB=/path/to/clone.sqlite \
//     swift test --package-path packages/kits/GeniusLocusKit \
//       --filter ScaleQualification
//
// Prints `QUAL key=value` metric lines for the release evidence: migration
// duration and counts, reclaim outcome, and post-migration recall latency
// with direct Drawer-ID hydration proof. Resumable: kill it mid-run and
// rerun — it continues from the persisted state record and cursor.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
@testable import GeniusLocusKit
@testable import GLKMigrationV1_0ToV1_1

@Suite("ScaleQualification", .serialized)
struct ScaleQualificationTests {

    @Test func qualifyLargeEstateMigration() async throws {
        guard let path = ProcessInfo.processInfo.environment["MOOT_SCF_QUAL_DB"] else {
            return // env-gated qualification driver — inert in CI lanes
        }
        let ownerID = ProcessInfo.processInfo.environment["MOOT_SCF_QUAL_OWNER"]
            ?? "mootx01-user"
        func q(_ label: String, _ value: Any) { print("QUAL \(label)=\(value)") }
        let now = Date(timeIntervalSince1970: 1_753_000_000)

        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: URL(fileURLWithPath: path), busyTimeout: 30.0)))
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: ownerID)
        let tOpen = Date()
        let handle = try await kit.open(storage: storage, owner: owner)
        q("open_secs", String(format: "%.2f", Date().timeIntervalSince(tOpen)))

        // Migration (idempotent + resumable).
        let tMig = Date()
        let report = try await kit.runSharedContentMigration(handle: handle, now: now)
        let migSecs = Date().timeIntervalSince(tMig)
        q("migration_secs", String(format: "%.2f", migSecs))
        q("migration.state", report.state.rawValue)
        q("migration.legacy_chunk_count", report.legacyChunkCount)
        q("migration.legacy_vector_key_count", report.legacyVectorKeyCount)
        q("migration.rebuilt_content_count", report.rebuiltContentCount)
        q("migration.estimated_reclaimable_bytes",
          report.estimatedReclaimableBytes ?? -1)
        if report.rebuiltContentCount > 0, migSecs > 0 {
            q("migration.index_throughput_per_sec",
              String(format: "%.1f", Double(report.rebuiltContentCount) / migSecs))
        }
        #expect(report.state == .reclaimPending || report.state == .complete)

        // Physical reclamation through the completion hook.
        let tRec = Date()
        let maintenance = try await kit.completeSharedContentReclaim(
            handle: handle, now: now)
        q("reclaim_secs", String(format: "%.2f", Date().timeIntervalSince(tRec)))
        if let m = maintenance {
            q("reclaim.performed", m.performed)
            q("reclaim.freelist_before", m.freelistPagesBefore)
            q("reclaim.freelist_after", m.freelistPagesAfter)
            q("reclaim.file_bytes_before", m.fileSizeBytesBefore)
            q("reclaim.file_bytes_after", m.fileSizeBytesAfter)
            q("reclaim.wal_bytes_before", m.walBytesBefore)
            q("reclaim.wal_bytes_after", m.walBytesAfter)
            q("reclaim.reclaimed_bytes", m.reclaimedBytes)
        }
        let status = try await kit.sharedContentReclaimStatus(handle: handle)
        q("status.state", status.state?.rawValue ?? "nil")
        q("status.reclaimed_bytes", status.reclaimedBytes ?? -1)

        // Post-migration recall qualification: attached engine over the SAME
        // storage — BM25 hits must BE drawer IDs and hydrate directly.
        let estate = try await kit.estate(for: handle)
        let engine = try await CorpusContentEngine(
            storage: storage,
            configuration: CorpusContentConfiguration(
                mode: .attached, indexUnit: .wholeContent),
            source: LocusDrawerCorpusContentSource(estate: estate),
            models: CorpusEnsemble.defaultEnsemble())
        q("recall.indexed_sources", try await engine.indexedContentIDs().count)
        q("recall.coverage_attestations",
          try await engine.indexCoverageAttestations().count)
        // Per-provider coverage under the LIVE generations.
        for generation in await engine.providerGenerations() {
            q("recall.coverage.\(generation.modelID)",
              try await engine.coveredCount(modelID: generation.modelID) ?? 0)
            q("recall.generation.\(generation.modelID)",
              String(generation.basisDigest.prefix(12)))
        }
        let queries = ["project planning decisions",
                       "release engineering process",
                       "memory palace estate"]
        for (i, query) in queries.enumerated() {
            // Per-signal dense float lane: every configured signal must serve.
            let tF = Date()
            let perSignal = await engine.floatNearestPerSignal(query: query, limit: 5)
            q("recall.q\(i).float_all_signals_ms",
              String(format: "%.1f", Date().timeIntervalSince(tF) * 1000))
            for (modelID, outcome) in perSignal {
                if case .hits(let hitsList) = outcome {
                    q("recall.q\(i).float.\(modelID).served", !hitsList.isEmpty)
                } else {
                    q("recall.q\(i).float.\(modelID).served", false)
                }
            }
            let tQ = Date()
            let hits = try await engine.bm25TopK(query: query, limit: 5)
            q("recall.q\(i).latency_ms",
              String(format: "%.1f", Date().timeIntervalSince(tQ) * 1000))
            q("recall.q\(i).hits", hits.count)
            if let top = hits.first {
                let hydrated = (try? await estate.drawerById(rowID: top.id)) != nil
                q("recall.q\(i).top_score", String(format: "%.3f", top.score))
                q("recall.q\(i).top_hydrates_directly", hydrated)
            }
        }
        try await kit.close(handle)
    }
}

#endif
