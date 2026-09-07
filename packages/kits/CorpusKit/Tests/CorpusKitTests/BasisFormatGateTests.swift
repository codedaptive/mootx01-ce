// BasisFormatGateTests.swift
//
// The open-path format-version gate: an estate whose persisted basis and
// counts rows were written by another codec generation (same provider magic,
// another format-version byte) must
//
//   1. open without error — the estate stays usable;
//   2. serve the affected slot UNTRAINED (the float lane reports the
//      structural opt-out, never vectors pooled the old way against queries
//      pooled the new way);
//   3. refuse to restore the stale counts (`restoreCounts(into:)` returns
//      false, the same contract as the invalidation sentinel);
//   4. republish current-format basis and counts rows on the next retrain,
//      after which the float lane serves again.
//
// The stale rows are produced by rewriting a freshly trained estate's rows
// with the version byte changed, which is exactly the shape a pre-bump estate
// presents to this build. Rust twin: rust/tests/basis_format_gate_tests.rs

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import PersistenceKit
import PersistenceKitSQLite
import SynapseKit

@Suite("BasisFormatGate", .serialized)
struct BasisFormatGateTests {

    private let docs: [String] = [
        "car engine drive road vehicle",
        "vehicle road transport car fuel",
        "engine fuel combustion power car",
        "dog bark run fetch animal",
        "animal run cat dog pet",
    ]
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let modelID = "random-indexing-v1"
    private let modelVersion = "1.1.0"

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-format-gate-\(UUID().uuidString).sqlite3")
    }

    /// Real SQLite, so the persist → reopen path reads the rows back the way an
    /// estate on disk presents them.
    private func storage(at url: URL) throws -> any Storage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0)))
    }

    private func riCorpus(at url: URL) async throws -> Corpus {
        try await Corpus(storage: try storage(at: url),
                         model: .randomIndexing(provider: RandomIndexingProvider()))
    }

    @Test("BasisBlobFrame.isStaleVersion fires on the same magic under another version only")
    func frameStalenessRule() {
        let current = Data("RIB1".utf8) + Data([basisFormatVersion])
        let stale = Data("RIB1".utf8) + Data([basisFormatVersion &- 1]) + Data([0, 1, 2])
        #expect(BasisBlobFrame.isStaleVersion(persisted: stale, current: current))
        #expect(!BasisBlobFrame.isStaleVersion(persisted: current, current: current))
        // A keying error (other magic) is corruption for the decoder, not skew.
        #expect(!BasisBlobFrame.isStaleVersion(persisted: Data("PPB1".utf8) + Data([1]), current: current))
        // Too short to frame: never stale (the decoder reports the truncation).
        #expect(!BasisBlobFrame.isStaleVersion(persisted: Data("RIB".utf8), current: current))
        #expect(BasisBlobFrame.formatVersion(of: current) == basisFormatVersion)
        #expect(BasisBlobFrame.formatVersion(of: Data([1, 2])) == nil)
    }

    @Test("a basis and counts row under another format version open untrained; reindex republishes current rows")
    func staleFormatOpensUntrainedAndReindexRepublishes() async throws {
        try await GlobalTestLock.shared.withLock {
            let url = scratchURL()

            // 1. Train and persist a current-format basis + counts.
            do {
                let corpus = try await riCorpus(at: url)
                for (i, doc) in docs.enumerated() {
                    try await corpus.ingest(doc, sourceID: "doc-\(i)", now: now)
                }
                try await corpus.reindex(now: now)
                // A trained basis embeds the probe; an untrained slot returns [].
                let trained = try await corpus.embedFloat("car engine")
                #expect(!trained.isEmpty, "a trained corpus must embed through its basis")
            }

            // 2. Rewrite both rows under the previous format version — the
            //    shape an estate written by the earlier codec presents.
            let staleVersion: UInt8 = basisFormatVersion &- 1
            do {
                let storage = try storage(at: url)
                let basisStore = BasisStore(storage: storage)
                let persisted = try #require(try await basisStore.load(modelID: modelID, modelVersion: modelVersion))
                var basisBytes = [UInt8](persisted.basis)
                basisBytes[4] = staleVersion
                try await basisStore.upsert(PersistedBasis(
                    modelID: modelID, modelVersion: modelVersion,
                    basis: Data(basisBytes),
                    trainedAt: persisted.trainedAt,
                    trainedChunkCount: persisted.trainedChunkCount))

                let countsStore = CorpusProviderCountsStore(storage: storage)
                let counts = try #require(try await countsStore.load(modelID: modelID, modelVersion: modelVersion))
                var countsBytes = [UInt8](counts.counts)
                countsBytes[4] = staleVersion
                try await countsStore.upsert(PersistedCounts(
                    modelID: modelID, modelVersion: modelVersion,
                    counts: Data(countsBytes),
                    documentCount: counts.documentCount,
                    vocabSize: counts.vocabSize,
                    updatedAt: counts.updatedAt))

                // 3. The counts gate on its own: a fresh provider refuses the
                //    stale row with `false` (the sentinel contract), not a throw.
                let restored = try await countsStore.restoreCounts(
                    into: RandomIndexingProvider(), modelID: modelID, modelVersion: modelVersion)
                #expect(restored == false, "a stale-format counts row restores as 'no counts'")
            }

            // Reopen over the same file: the slot must open untrained.
            let reopened = try await riCorpus(at: url)
            let untrained = try await reopened.embedFloat("car engine")
            #expect(untrained.isEmpty,
                    "a stale-format basis must open the slot untrained (empty embedding); got \(untrained.count) dims")

            // 4. The retrain republishes current-format rows and the lane serves.
            try await reopened.reindex(now: now)
            let storage = try storage(at: url)
            let republished = try #require(try await BasisStore(storage: storage)
                .load(modelID: modelID, modelVersion: modelVersion))
            #expect(BasisBlobFrame.formatVersion(of: republished.basis) == basisFormatVersion,
                    "reindex must republish the basis in the current format")
            let countsAfter = try #require(try await CorpusProviderCountsStore(storage: storage)
                .load(modelID: modelID, modelVersion: modelVersion))
            #expect(BasisBlobFrame.formatVersion(of: countsAfter.counts) == basisFormatVersion,
                    "reindex must republish the counts in the current format")
            let retrained = try await reopened.embedFloat("car engine")
            #expect(!retrained.isEmpty, "after the retrain the basis must embed again")
        }
    }
}
