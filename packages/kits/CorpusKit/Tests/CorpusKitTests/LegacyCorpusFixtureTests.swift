// LegacyCorpusFixtureTests.swift
//
// Legacy-v7 corpus-lane fixture coverage (GLK shared-content 1.1, P0).
//
// Pins the structural identity of the historical v7-era corpus lane —
// the layout the P4 legacy detector must DISTINGUISH from the current
// pre-cutover layout — and proves the fixture builder produces the
// deterministic legacy-shaped rows destructive migration tests replay.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite
import VectorKit

@testable import CorpusKit

@Suite("LegacyCorpusFixture", .serialized)
struct LegacyCorpusFixtureTests {

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legacy_v7_corpus_lane_signature.txt")
    }

    @Test func legacySignatureMatchesFrozenCrossPortFixture() throws {
        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
        let actual = LegacyCorpusFixtures.legacyCorpusLaneDeclaration.layoutSignatureText()
        #expect(actual == expected,
                "legacy corpus-lane signature diverged — the legacy declarations are FROZEN history and must not track live declarations")
    }

    @Test func legacyLayoutIsDistinguishableFromCurrentLayout() {
        let legacy = LegacyCorpusFixtures.legacyCorpusLaneDeclaration.layoutSignatureText()
        let current = LegacyCorpusFixtures.currentCorpusLaneDeclaration.layoutSignatureText()
        #expect(legacy != current)

        // The distinguishing marks the detector keys on:
        // v3 BundleStore added content_hash + corpus_metadata; VectorKit v4
        // added the filed_at index.
        #expect(!legacy.contains("col=content_hash"))
        #expect(current.contains("col=content_hash"))
        #expect(!legacy.contains("table=corpus_metadata"))
        #expect(current.contains("table=corpus_metadata"))
        #expect(!legacy.contains("index=idx_vectors_filed_at_item"))
        #expect(current.contains("index=idx_vectors_filed_at_item"))
    }

    @Test func builderProducesDeterministicLegacyRows() async throws {
        let storage = try makeScratchStorage()
        let chunkIDs = try await LegacyCorpusFixtures.buildLegacyV7CorpusLane(storage: storage)

        // One chunk + one chunk-keyed vector per legacy source; no
        // corpus_metadata table exists at v7.
        #expect(chunkIDs.count == LegacyCorpusFixtures.legacySources.count)
        let chunkCount = try await storage.rowStore.count(table: "chunks", where: nil)
        let vectorCount = try await storage.rowStore.count(table: "vectors", where: nil)
        #expect(chunkCount == 2)
        #expect(vectorCount == 2)
        await #expect(throws: (any Error).self) {
            _ = try await storage.rowStore.count(table: "corpus_metadata", where: nil)
        }

        // Vector rows are keyed by the legacy chunk UUIDs — the exact-key
        // deletion inventory the migration captures.
        let vectorRows = try await storage.rowStore.query(
            table: "vectors", where: nil, orderBy: [], limit: nil, offset: nil)
        let allChunkIDStrings = Set(chunkIDs.values.flatMap { $0 }.map(\.uuidString))
        for row in vectorRows {
            guard case let .text(itemID)? = row["item_id"] else { continue }
            #expect(allChunkIDStrings.contains(itemID))
        }

        // Deterministic across builds: an identical fixture in a fresh
        // storage folds identically (fixture stamps are fixed, so no
        // exclusions are needed).
        let storage2 = try makeScratchStorage()
        _ = try await LegacyCorpusFixtures.buildLegacyV7CorpusLane(storage: storage2)
        let inv1 = try await DatabaseInventory.capture(
            storage: storage, tables: ["chunks", "vectors"])
        let inv2 = try await DatabaseInventory.capture(
            storage: storage2, tables: ["chunks", "vectors"])
        #expect(inv1 == inv2)
    }
}
