import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("ARIA v2 orchestration lower adapter contracts")
struct AriaV2OrchestrationLowerTests {
    @Test("terminal and disqualified migration failures remain distinct")
    func migrationFailureCodesStayDistinct() {
        let branchID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        #expect(
            AriaV2OrchestrationLowerError.disqualifiedMigrationBranch(branchID).code
                == "disqualified_branch"
        )
        #expect(
            AriaV2OrchestrationLowerError.terminalMigrationBranch(branchID, status: "won").code
                == "terminal_branch"
        )
    }

    @Test("cleanup outcome status is explicit and does not require requested ids")
    func cleanupStatusesRemainObservable() {
        let branchID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let receipt = AriaV2MigrationConfirmationData(
            promotedBranchID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            discardedBranchIDs: [],
            discardOutcomes: [.init(branchID: branchID, status: .failed)]
        )
        #expect(receipt.promotedBranchID.uuidString.lowercased() == "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        #expect(receipt.discardOutcomes == [.init(branchID: branchID, status: .failed)])
    }

    @Test("production confirmation returns canonical observed cleanup receipts")
    func productionConfirmationOrdersObservedCleanup() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-orchestration-lower")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let winner = try await NeuronKit.deriveBranch(name: "winner", from: handle, in: kit)
        let firstLoser = try await NeuronKit.deriveBranch(name: "first loser", from: handle, in: kit)
        let secondLoser = try await NeuronKit.deriveBranch(name: "second loser", from: handle, in: kit)
        let unknown = UUID()
        let provider = AriaV2GeniusLocusOrchestrationProvider(
            kit: kit, handle: handle, federationSources: [])
        let request = try AriaV2ConfirmMigrationRequest(arguments: .object([
            "winner_branch_id": .string(winner.branchID.uuidString),
            // Deliberately noncanonical: public v2 UUID lists must be sorted
            // by canonical branch identity, not echoed request order.
            "discard_branch_ids": .array([
                .string(winner.branchID.uuidString),
                .string(secondLoser.branchID.uuidString),
                .string(unknown.uuidString),
                .string(firstLoser.branchID.uuidString),
            ]),
        ]))
        let receipt = try await provider.confirmMigration(
            request,
            context: .init(estateID: handle.estateUUID, serverIdentity: "test", sessionID: "test")
        )

        let expectedOutcomeIDs = [winner.branchID, firstLoser.branchID, secondLoser.branchID, unknown]
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        let expectedDiscardedIDs = [firstLoser.branchID, secondLoser.branchID]
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        #expect(receipt.promotedBranchID == winner.branchID)
        #expect(receipt.discardOutcomes.map(\.branchID) == expectedOutcomeIDs)
        #expect(receipt.discardedBranchIDs == expectedDiscardedIDs)
        #expect(receipt.discardOutcomes.first(where: { $0.branchID == winner.branchID })?.status == .winnerSkipped)
        #expect(receipt.discardOutcomes.first(where: { $0.branchID == unknown })?.status == .unknown)
        #expect(receipt.discardOutcomes.filter { $0.status == .discarded }.map(\.branchID) == expectedDiscardedIDs)
    }

    @Test("a federation response carries the lower engine grant identity")
    func federatedReceiptCarriesGrantIdentity() {
        let source = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let requester = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let grant = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let data = AriaV2FederatedSearchData(
            sourceEstateID: source,
            requesterEstateID: requester,
            grantID: grant,
            results: []
        )
        #expect(data.sourceEstateID == source)
        #expect(data.requesterEstateID == requester)
        #expect(data.grantID == grant)
    }

    @Test("federated lower returns an actual registered peer grant receipt")
    func federatedLowerUsesAuthorizedPeer() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-v2-federation-lower")
        let requesterStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let sourceStorage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: requesterStorage, owner: owner)
        _ = try await LocusKit.Estate.create(storage: sourceStorage, owner: owner)
        let requester = try await kit.open(
            storage: requesterStorage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: true)
        let source = try await kit.open(
            storage: sourceStorage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore(), federate: true)
        let grant = try await kit.issueGrant(source, GrantOptions(
            granteeEstateID: requester.estateUUID,
            scope: .wholeEstate,
            custodyMode: .mediated,
            lifetime: .permanent
        ))
        _ = try await kit.capture(source, CaptureFrame(
            content: "peer-only-v2-federation-row",
            channel: .typed,
            room: "aria-v2-federation",
            latticeAnchor: .udc("004"),
            addedBy: "aria-v2-orchestration-lower-tests",
            embeddingModelID: "test-model-v1",
            subject: "peer-only-v2-federation-row"
        ))

        let provider = AriaV2GeniusLocusOrchestrationProvider(
            kit: kit, handle: requester, federationSources: [requester, source])
        let data = try await provider.federatedSearch(
            AriaV2FederatedSearchRequest(arguments: .object([
                "filter": .string("unconfirmed"),
                "hydration_level": .string("full"),
            ])),
            context: .init(
                estateID: requester.estateUUID,
                serverIdentity: "aria-v2-test",
                sessionID: "federation-test"
            )
        )

        #expect(data.sourceEstateID == source.estateUUID)
        #expect(data.requesterEstateID == requester.estateUUID)
        #expect(data.grantID == grant.grant.id)
        #expect(data.results.contains { $0.context == "peer-only-v2-federation-row" })
    }
}
