// EnrichmentAcceptanceTests.swift
//
// Force-tests for the Q-ID-completion acceptance path
// (GeniusLocusKit.resolveEnrichmentProposal), the terminal wiring of the
// enrichment Q-ID pipeline (cookbook §2.5).
//
// The maintenance daemon files an enrichment proposal and moves a drawer
// whose Q-ID could not be resolved by deterministic inference to the
// terminal in-workflow state `qidProposed` (4). When that proposal is
// accepted with a human/agent-supplied Q-ID, `resolveEnrichmentProposal`
// completes the resolution in two atomic, audited writes:
//   1. the resolved Q-ID is written into the drawer's lattice anchor, and
//   2. the enrichment-status bits flip from qidProposed (4) to
//      qidCompleted (2).
//
// These tests prove the acceptance wire end to end against a live in-memory
// estate: stage a drawer at qidProposed, accept, then read the drawer back
// and assert the anchor carries the Q-ID and the status is terminal
// qidCompleted. No assertion ends at a durable-pending state.

import Testing
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import GeniusLocusKit

@Suite("Q-ID-completion acceptance path — accepted enrichment proposal resolves the drawer")
struct EnrichmentAcceptanceTests {

    private func provisionGLKEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-enrichment-acceptance")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        let params = EstateProvisionParams(
            estateName: "Enrichment Acceptance Estate",
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

    /// A capture frame whose anchor carries an MDCC code but NO Q-ID — the
    /// shape of a drawer that inference resolved a code for but could not
    /// resolve a Q-ID (Mode B).
    private func captureFrame(_ content: String) -> CaptureFrame {
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "enrichment-acceptance",
            latticeAnchor: .udc("510.000"),  // code present, no Q-ID
            addedBy: "enrichment-acceptance",
            embeddingModelID: "test-model-v1"
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Enrichment-status field mask at bits 36-41 (cookbook §2.5).
    private let statusMask: Int64 = 0x3F << 36

    @Test("accepted enrichment proposal writes the Q-ID into the anchor and flips status to qidCompleted")
    func acceptedProposalResolvesDrawer() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        let drawer = try await kit.capture(handle, captureFrame("differential geometry"))

        // Stage the drawer at the terminal in-workflow state qidProposed (4),
        // as the maintenance daemon's completion branch would have left it.
        let qidProposedProvenance = (drawer.provenance & ~statusMask)
            | (Int64(EnrichmentStatus.qidProposed.rawValue) << 36)
        try await kit.updateEnrichmentStatus(
            in: handle,
            rowID: drawer.id,
            newProvenance: qidProposedProvenance,
            changedBy: "maintenance-daemon",
            now: t0
        )

        // Accept the proposal with a human/agent-supplied Q-ID.
        let resolvedQID = "Q161254"  // differential geometry
        try await kit.resolveEnrichmentProposal(
            in: handle,
            rowID: drawer.id,
            wikidataQID: resolvedQID,
            changedBy: "reviewer-alice",
            now: t0.addingTimeInterval(60)
        )

        // Read the drawer back and assert both halves of the acceptance wire.
        let after = try await kit.allDrawers(in: handle)
            .first(where: { $0.id == drawer.id })
        let resolved = try #require(after)

        // 1. Anchor update — the Q-ID is now present; the code is preserved.
        #expect(resolved.wikidataQID == resolvedQID)
        #expect(resolved.udcCode == "510.000")
        // 2. Provenance flip — status is terminal qidCompleted (2), NOT
        //    qidProposed and NOT durable-pending.
        #expect(resolved.enrichmentStatus == .qidCompleted)
    }

    @Test("resolution preserves the drawer's other provenance bits")
    func resolutionPreservesOtherProvenanceBits() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        let drawer = try await kit.capture(handle, captureFrame("topology"))

        // Stage qidProposed while also setting an unrelated provenance bit
        // (confidence field, bits 24-29 = medium 32) to prove the status flip
        // masks ONLY bits 36-41.
        let confidenceMedium: Int64 = 32 << 24
        let staged = ((drawer.provenance & ~statusMask)
            | (Int64(EnrichmentStatus.qidProposed.rawValue) << 36))
            | confidenceMedium
        try await kit.updateEnrichmentStatus(
            in: handle,
            rowID: drawer.id,
            newProvenance: staged,
            changedBy: "maintenance-daemon",
            now: t0
        )

        try await kit.resolveEnrichmentProposal(
            in: handle,
            rowID: drawer.id,
            wikidataQID: "Q43229",
            changedBy: "reviewer-bob",
            now: t0.addingTimeInterval(60)
        )

        let resolved = try #require(
            try await kit.allDrawers(in: handle).first(where: { $0.id == drawer.id }))
        // Status terminal, AND the unrelated confidence bits survived.
        #expect(resolved.enrichmentStatus == .qidCompleted)
        #expect((resolved.provenance & (0x3F << 24)) == confidenceMedium)
    }

    @Test("resolving an absent drawer throws, not silently completing")
    func resolvingAbsentDrawerThrows() async throws {
        let (kit, handle) = try await provisionGLKEstate()
        await #expect(throws: GeniusLocusKitError.self) {
            try await kit.resolveEnrichmentProposal(
                in: handle,
                rowID: "does-not-exist",
                wikidataQID: "Q1",
                changedBy: "reviewer",
                now: t0
            )
        }
    }
}
