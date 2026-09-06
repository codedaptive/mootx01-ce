// IndexCompositionPolicyAdapterTests.swift
//
// `LocusDrawerCorpusContentSource` composes the `CorpusContentRecord` the one
// indexing engine consumes. At schema 19 every named `IndexCompositionPolicy`
// resolves to the same composition — verbatim `content` for both lanes, the
// `ssc_facts` column riding beside it for the engine's BM25 supplement — and
// the policy id is retained only so estates provisioned under an earlier id
// keep opening. These tests pin that composition byte for byte and pin the
// column-to-record hand-off the enrichment stage depends on.
//
// Rust twin: rust/src/intake.rs tests (`LocusDrawerContentSource`).

import CorpusKit
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import Testing

@testable import GeniusLocusKit

@Suite("LocusDrawerCorpusContentSource — record composition")
struct IndexCompositionPolicyAdapterTests {

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
        _ estate: LocusKit.Estate, _ id: String, policy: IndexCompositionPolicy
    ) async throws -> CorpusContentRecord {
        let source = LocusDrawerCorpusContentSource(estate: estate, compositionPolicy: policy)
        return try #require(try await source.record(for: id))
    }

    @Test("every named policy composes the verbatim content for both lanes")
    func everyPolicyComposesVerbatimContent() async throws {
        // Failure mode: a policy branch that reaches for a text the schema no
        // longer stores (a distillate or an adornment) would change `text` or
        // set a dense composition; both must stay pinned to the column.
        let (estate, id) = try await Self.fixture()
        let implicit = try #require(
            try await LocusDrawerCorpusContentSource(estate: estate).record(for: id))
        #expect(implicit.text == Self.content)
        #expect(implicit.denseCompositionText == nil)
        #expect(implicit.effectiveDenseText == Self.content)
        for policy in [IndexCompositionPolicy.current, .lexicalAdornments, .denseAdornments,
                       .bothAdornments, .lexicalBaseline] {
            let rec = try await Self.record(estate, id, policy: policy)
            #expect(rec == implicit, "policy \(policy.id) must compose the same record")
            #expect(rec.digest == CorpusContentDigest.digest(Self.content))
            #expect(rec.revision == 1)
        }
    }

    @Test("the ssc_facts column rides the record for the BM25 supplement")
    func sscFactsRideTheRecord() async throws {
        // Failure mode: an adapter that drops the column leaves the engine
        // with no facts to tokenise, so every SSC term vanishes from BM25.
        let (estate, id) = try await Self.fixture()
        let rec = try await Self.record(estate, id, policy: .current)
        #expect(rec.sscFacts == Self.facts)
        // Clearing the column clears the record, so a regenerated NULL after
        // a content write is what the engine sees, never a stale value.
        _ = try await estate.setSSCFacts(nil, for: id)
        let cleared = try await Self.record(estate, id, policy: .current)
        #expect(cleared.sscFacts == nil)
        #expect(cleared.text == Self.content)
    }
}
