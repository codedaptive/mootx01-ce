// LocusDrawerCorpusContentSourceTests.swift
//
// `LocusDrawerCorpusContentSource` composes the `CorpusContentRecord` the one
// indexing engine consumes: verbatim `content` for both lanes, the
// `ssc_facts` column riding beside it for the engine's BM25 supplement. These
// tests pin that composition byte for byte and pin the column-to-record
// hand-off the enrichment stage depends on.
//
// Rust twin: rust/src/intake.rs (`LocusDrawerContentSource`).

import CorpusKit
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import Testing

@testable import GeniusLocusKit

@Suite("LocusDrawerCorpusContentSource — record composition")
struct LocusDrawerCorpusContentSourceTests {

    private static let owner = OwnerCredentials(ownerIdentifier: "adapter-owner")
    private static let addedBy = "adapter-test"
    private static let content = "Alice moved to Lisbon in March. She keeps bees."
    private static let facts = "entity: alice, place: lisbon"

    /// A fresh on-disk estate carrying one drawer with content and a stored
    /// `ssc_facts` value.
    private static func fixture() async throws -> (estate: LocusKit.Estate, drawerID: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: dir.appendingPathComponent("estate.sqlite3"), busyTimeout: 5.0)))
        let estate = try await LocusKit.Estate.create(storage: storage, owner: owner)

        let drawer = try await estate.capture(CaptureFrame(
            content: content,
            channel: .typed,
            room: "adapter-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: addedBy,
            embeddingModelID: "no-embedding",
            lineageID: UUID()))
        let written = try await estate.setSSCFacts(facts, for: drawer.id)
        #expect(written == 1)
        return (estate, drawer.id)
    }

    private static func record(
        _ estate: LocusKit.Estate, _ id: String
    ) async throws -> CorpusContentRecord {
        let source = LocusDrawerCorpusContentSource(estate: estate)
        return try #require(try await source.record(for: id))
    }

    @Test("the record composes the verbatim content for both lanes")
    func recordComposesVerbatimContent() async throws {
        // Failure mode: an adapter that reaches for a text the schema no
        // longer stores (a distillate or an adornment) would change `text` or
        // set a dense composition; both must stay pinned to the column.
        let (estate, id) = try await Self.fixture()
        let rec = try await Self.record(estate, id)
        #expect(rec.text == Self.content)
        #expect(rec.denseCompositionText == nil)
        #expect(rec.effectiveDenseText == Self.content)
        #expect(rec.digest == CorpusContentDigest.digest(Self.content))
        #expect(rec.revision == 1)
    }

    @Test("the ssc_facts column rides the record for the BM25 supplement")
    func sscFactsRideTheRecord() async throws {
        // Failure mode: an adapter that drops the column leaves the engine
        // with no facts to tokenise, so every SSC term vanishes from BM25.
        let (estate, id) = try await Self.fixture()
        let rec = try await Self.record(estate, id)
        #expect(rec.sscFacts == Self.facts)
        // Clearing the column clears the record, so a regenerated NULL after
        // a content write is what the engine sees, never a stale value.
        _ = try await estate.setSSCFacts(nil, for: id)
        let cleared = try await Self.record(estate, id)
        #expect(cleared.sscFacts == nil)
        #expect(cleared.text == Self.content)
    }
}
