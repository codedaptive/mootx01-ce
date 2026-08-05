// ExpungePartialLineageTests.swift
//
// Honesty tests for a PARTIAL lineage expunge (MXE-FA).
//
// The audit gate refuses `accepted → tombstoned` (S-3), so a lineage
// expunge that meets an accepted sibling scrubs only the admitted
// members. These tests pin the end-to-end consequences of that refusal
// at the GLK layer:
//
//   P1 — The refused (accepted) sibling keeps BOTH its content and its
//        vector-lane entries. Deleting the vector for a row whose content
//        survives would make the row unrecallable by search while still
//        readable by id — a third inconsistent state.
//   P2 — Scrubbed members lose both content and vector, exactly as a
//        full expunge does.
//   P3 — The expunge verb returns the refusal to the caller: an expunge
//        that refused a sibling is not a success, and a layer that
//        summarises it as one is the defect.
//   P4 — A lineage with no accepted members expunges fully and reports
//        no refusals — the pre-existing contract is unchanged.

import Testing
import Foundation
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
import SubstrateML
@testable import LocusKit     // Estate.store access for ledger/byte-identity probes
@testable import GeniusLocusKit

@Suite("Expunge — a refused sibling makes the expunge partial, honestly")
struct ExpungePartialLineageTests {

    // MARK: - Helpers

    /// Provision a full `.glk` estate (LocusKit + Corpus + VectorStore wired).
    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-expunge-partial-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Expunge Partial Lineage Test Estate",
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

    private func captureFrame(content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "expunge-partial-tests",
            latticeAnchor: .udc("000"),
            addedBy: "expunge-partial-tests",
            embeddingModelID: "test-model-v1"
        )
    }

    /// Capture an accepted head (D1) and an active sibling (D2) in the SAME
    /// lineage, both encoded impatiently so each carries live corpus vectors.
    ///
    /// Order matters: D1 is promoted to `.accepted` BEFORE D2 is captured —
    /// an accepted row is not an active predecessor, so the D2 capture does
    /// not supersede it (same recipe as the MXE-EZ DrawerStore-layer tests).
    private func seedAcceptedSiblingLineage(
        kit: GeniusLocusKit, handle: EstateHandle
    ) async throws -> (accepted: Drawer, head: Drawer) {
        let d1 = try await kit.capture(
            handle,
            captureFrame(content: "accepted ruthenium ledger entry kept verbatim for audit"),
            mode: .impatient)
        // S-1: accept requires trust ≥ canonical.
        try await kit.mutate(handle, MutateFrame(rowID: d1.id, kind: .correctTrust(.canonical)))
        try await kit.mutate(handle, MutateFrame(rowID: d1.id, kind: .accept))

        var d2Frame = captureFrame(
            content: "active ruthenium draft note superseding nothing yet")
        d2Frame.lineageID = d1.lineageID
        let d2 = try await kit.capture(handle, d2Frame, mode: .impatient)
        return (d1, d2)
    }

    /// True when the corpus recall index still returns `drawerID` for `query`.
    private func corpusRecalls(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        query: String, drawerID: String
    ) async throws -> Bool {
        let corpus = try #require(
            await kit.corpusKits[handle],
            "a .glk estate must have a registered Corpus")
        let chunks = try await corpus.recall(query, limit: 10, now: Date())
        return chunks.contains { $0.id == drawerID }
    }

    // MARK: - P1+P2: refused sibling keeps content AND vector; scrubbed members lose both

    /// Expunging a lineage whose sibling is accepted must scrub ONLY the
    /// admitted members. The refused sibling stays byte-identical in storage
    /// AND recallable through the corpus lane — vectors are deleted only for
    /// members that were actually scrubbed.
    @Test
    func partialExpungePreservesAcceptedSiblingContentAndVector() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let (d1, d2) = try await seedAcceptedSiblingLineage(kit: kit, handle: handle)

        // Sanity: both lineage members are recallable before the expunge.
        #expect(try await corpusRecalls(kit, handle, query: "ruthenium ledger audit", drawerID: d1.id),
                "accepted sibling must be corpus-recallable before expunge")
        #expect(try await corpusRecalls(kit, handle, query: "ruthenium draft note", drawerID: d2.id),
                "head must be corpus-recallable before expunge")

        let estate = try await kit.estate(for: handle)
        let d1Before = try #require(try await estate.drawerById(rowID: d1.id))

        // Expunge the head. The gate refuses the accepted sibling (S-3).
        // P3 — the verb returns the refusal to the caller instead of
        // summarising the partial expunge as a plain success.
        let outcome = try await kit.expunge(handle, ExpungeFrame(
            rowID: d2.id, reason: "partial lineage expunge probe", confirmation: true))
        #expect(outcome.refusedSiblingIDs == [d1.id],
                "the verb must name exactly the refused accepted sibling; got \(outcome.refusedSiblingIDs)")

        // P2 — the admitted head is scrubbed: content gone, vector gone.
        let d2After = try #require(try await estate.allDrawers().first { $0.id == d2.id })
        #expect(d2After.state == .tombstoned, "the expunge target must be tombstoned")
        #expect(d2After.content.isEmpty, "the expunge target's content must be scrubbed")
        #expect(!(try await corpusRecalls(kit, handle, query: "ruthenium draft note", drawerID: d2.id)),
                "the scrubbed head must no longer be corpus-recallable")

        // P1 — the refused sibling is byte-identical AND still has its vector.
        // The content read below also proves the erasure ledger recorded only
        // what was actually erased: PersistenceKit's read-time ErasureOverlay
        // nulls content for any ledgered id, so a ledger record for D1 would
        // fail the byte-identity assertion even if the row bytes survived.
        let d1After = try #require(try await estate.drawerById(rowID: d1.id))
        #expect(d1After.state == .accepted, "refused sibling state must remain accepted")
        #expect(d1After.content == d1Before.content,
                "refused sibling content must survive byte-identical")
        #expect(d1After.adjectiveBitmap == d1Before.adjectiveBitmap,
                "refused sibling adjective bitmap must be untouched")
        #expect(try await corpusRecalls(kit, handle, query: "ruthenium ledger audit", drawerID: d1.id),
                "refused sibling must STILL be corpus-recallable: its content survives, so deleting its vector would create a row readable by id but invisible to search")
    }

    // MARK: - P4: a lineage with no accepted members is unchanged

    /// Full-lineage expunge with no accepted member behaves exactly as today:
    /// every member is scrubbed and no refusal is reported.
    @Test
    func fullExpungeOfUnprotectedLineageScrubsEveryMember() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        defer { Task { try? await kit.close(handle) } }

        let v1 = try await kit.capture(
            handle, captureFrame(content: "plain hafnium note first draft"), mode: .impatient)
        var v2Frame = captureFrame(content: "plain hafnium note second draft")
        v2Frame.lineageID = v1.lineageID
        let v2 = try await kit.capture(handle, v2Frame, mode: .impatient)

        let outcome = try await kit.expunge(handle, ExpungeFrame(
            rowID: v2.id, reason: "full lineage expunge control", confirmation: true))
        #expect(outcome.refusedSiblingIDs.isEmpty,
                "a lineage with no accepted members must report no refusals")

        let estate = try await kit.estate(for: handle)
        for id in [v1.id, v2.id] {
            let row = try #require(try await estate.allDrawers().first { $0.id == id })
            #expect(row.state == .tombstoned, "member \(id) must be tombstoned")
            #expect(row.content.isEmpty, "member \(id) content must be scrubbed")
        }
        #expect(!(try await corpusRecalls(kit, handle, query: "hafnium note draft", drawerID: v1.id)))
        #expect(!(try await corpusRecalls(kit, handle, query: "hafnium note draft", drawerID: v2.id)))
    }
}
