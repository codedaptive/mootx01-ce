// SSCFactsBackfillTests.swift
//
// The upgrade-time SSC facts backfill (contract sheet §6): rows whose
// `ssc_facts` column is NULL get their facts written once; rows that already
// carry facts, and rows whose content anchors nothing, are left alone.
//
// Rust twin: rust/tests/ssc_facts_backfill.rs.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("SSC facts backfill")
struct SSCFactsBackfillTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-ssc-backfill-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func frame(_ content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "backfill",
            latticeAnchor: .udc("000"),
            addedBy: "ssc-backfill-tests",
            embeddingModelID: "test-model-v1")
    }

    @Test("NULL rows get their facts; written rows and anchorless rows are left alone")
    func backfillWritesOnlyTheRowsThatOweFacts() async throws {
        // Failure modes: a pass that recomputes every row would report a
        // non-zero count on a converged estate and trigger a needless BM25
        // rebuild; a pass that skips NULL rows would leave migrated estates
        // without SSC terms in BM25.
        let (kit, handle) = try await openEstate()
        let anchored = "Sanjay loves painting in Brazil and runs marathons in Rio."
        let owed = try await kit.capture(handle, frame(anchored))
        let kept = try await kit.capture(handle, frame("Priya reviewed the Geneva contract with Sarah."))
        let estate = try await kit.estate(for: handle)
        let expected = try #require(EnrichmentStage.facts(forContent: anchored),
                                    "fixture content must anchor facts")
        let keptFacts = try #require(try await estate.getDrawers(ids: [kept.id]).first?.sscFacts,
                                     "the capture path writes facts at capture")

        // A migrated estate: the column is NULL on a row that owes facts.
        _ = try await estate.setSSCFacts(nil, for: owed.id)

        let written = try await kit.backfillSSCFacts(handle: handle)
        #expect(written == 1, "exactly the NULL row is written; got \(written)")
        let owedRow = try #require(try await estate.getDrawers(ids: [owed.id]).first)
        #expect(owedRow.sscFacts == expected)
        let keptRow = try #require(try await estate.getDrawers(ids: [kept.id]).first)
        #expect(keptRow.sscFacts == keptFacts, "a row that already carries facts is untouched")

        // Idempotent: a second pass finds nothing to write.
        #expect(try await kit.backfillSSCFacts(handle: handle) == 0)
    }
}
