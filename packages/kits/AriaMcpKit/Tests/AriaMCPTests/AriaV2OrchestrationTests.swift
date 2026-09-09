import Foundation
import Testing
@testable import AriaMCP

@Suite("ARIA v2 typed orchestration foundation")
struct AriaV2OrchestrationTests {
    private let estateID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let branchID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let loserID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

    @Test("Strict canonical requests reject legacy and unknown spelling")
    func strictRequests() async throws {
        let service = orchestration(provider: FixtureProvider())
        await #expect(throws: JSONRPCError.self) {
            _ = try await service.confirmMigration(arguments: .object(["winnerBranchID": .string(branchID.uuidString)]))
        }
        await #expect(throws: JSONRPCError.self) {
            _ = try await service.synthesize(arguments: .object(["unknown": .bool(true)]))
        }
        await #expect(throws: JSONRPCError.self) {
            _ = try await service.federatedSearch(arguments: .object(["limit": .integer(0)]))
        }
    }

    @Test("Migration evaluation never invokes confirmation")
    func runDoesNotAutoConfirm() async throws {
        let provider = FixtureProvider()
        let response = try await orchestration(provider: provider).runMigration(arguments: .object([
            "corpusName": .string("fixture"),
            "entries": .array([.object(["id": .string("one"), "content": .string("fixture")])]),
            "plans": .array([.object(["name": .string("flat"), "room": .string("Planning"), "latticeCode": .string("001"), "embeddingModelID": .string("fixture")])]),
        ]))
        let value = data(response)
        #expect(value?["winner_branch_id"] == .string(branchID.uuidString.lowercased()))
        #expect(value?["reports"] == .array([.object([
            "branch_id": .string(branchID.uuidString.lowercased()),
            "query_count": .integer(1),
            "recall_overlap": .double(1),
            "recall_precision": .double(1),
            "mean_reciprocal_rank": .double(1),
            "not_found_in_branch": .array([]),
            "new_in_branch": .array([]),
            "evaluated_at": .string("2026-09-08T00:00:00Z"),
        ])]))
        #expect(await provider.operations == [.runMigration])
    }

    @Test("Confirmation returns only verified cleanup outcomes")
    func confirmationUsesVerifiedOutcomes() async throws {
        let provider = FixtureProvider()
        let response = try await orchestration(provider: provider).confirmMigration(arguments: .object([
            "winner_branch_id": .string(branchID.uuidString),
            "discard_branch_ids": .array([.string(loserID.uuidString)]),
        ]))
        let value = data(response)
        #expect(value?["status"] == .string("promoted"))
        #expect(value?["promoted_branch_id"] == .string(branchID.uuidString.lowercased()))
        #expect(value?["discarded_branch_ids"] == .array([.string(loserID.uuidString.lowercased())]))
        #expect(value?["discard_outcomes"]?.arrayValue?.first?.objectValue?["status"] == .string("discarded"))
        #expect(await provider.operations == [.confirmMigration])
    }

    @Test("Synthesis and federation preserve stable typed identities")
    func readDataCarriesStableIDs() async throws {
        let service = orchestration(provider: FixtureProvider())
        let synthesize = try await service.synthesize(arguments: .object([:]))
        let federated = try await service.federatedSearch(arguments: .object([:]))
        #expect(data(synthesize)?["results"]?.arrayValue?.first?.objectValue?["memory_id"] == .string(FixtureProvider.memoryID.uuidString.lowercased()))
        #expect(data(synthesize)?["results"]?.arrayValue?.first?.objectValue?["excerpt"] == .string("grounded excerpt"))
        #expect(data(federated)?["source_estate_id"] == .string(FixtureProvider.sourceEstateID.uuidString.lowercased()))
        #expect(data(federated)?["requester_estate_id"] == .string(estateID.uuidString.lowercased()))
        #expect(data(federated)?["grant_id"] == .string(FixtureProvider.grantID.uuidString.lowercased()))
    }

    @Test("stable lower migration and federation refusal codes remain distinct")
    func stableLowerRefusalCodes() {
        #expect(AriaV2OrchestrationLowerError.unknownMigrationBranch(branchID).code == "unknown_branch")
        #expect(AriaV2OrchestrationLowerError.disqualifiedMigrationBranch(branchID).code == "disqualified_branch")
        #expect(AriaV2OrchestrationLowerError.terminalMigrationBranch(branchID, status: "won").code == "terminal_branch")
        #expect(AriaV2OrchestrationLowerError.noAuthorizedFederationSource.code == "no_authorized_federation_source")
        #expect(AriaV2OrchestrationLowerError.multipleAuthorizedFederationSources.code == "multiple_authorized_federation_sources")
    }

    private func orchestration(provider: FixtureProvider) -> AriaV2Orchestration {
        .init(provider: provider, context: .init(estateID: estateID, serverIdentity: "server", sessionID: "session", now: { Date(timeIntervalSince1970: 1_700_000_000) }))
    }

    private func data(_ response: JSONValue) -> [String: JSONValue]? {
        response.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
    }

    private actor FixtureProvider: AriaV2OrchestrationProvider {
        static let memoryID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        static let sourceEstateID = UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!
        static let grantID = UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!
        static let fixtureBranchID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        private(set) var operations: [AriaV2OrchestrationOperation] = []

        func synthesize(_ request: AriaV2SynthesizeRequest, context: AriaV2OrchestrationContext) async throws -> AriaV2SynthesisData {
            _ = request; _ = context; operations.append(.synthesize)
            return .init(
                summary: "grounded", cues: ["grounded"],
                results: [.init(memoryID: Self.memoryID, excerpt: "grounded excerpt")])
        }
        func runMigration(_ request: AriaV2RunMigrationRequest, context: AriaV2OrchestrationContext) async throws -> AriaV2MigrationData {
            _ = request; _ = context; operations.append(.runMigration)
            return .init(
                reports: [.init(
                    branchID: Self.fixtureBranchID,
                    queryCount: 1,
                    recallOverlap: 1,
                    recallPrecision: 1,
                    meanReciprocalRank: 1,
                    notFoundInBranch: [],
                    newInBranch: [],
                    evaluatedAt: "2026-09-08T00:00:00Z"
                )],
                winnerBranchID: Self.fixtureBranchID,
                winnerPlanName: "flat",
                rankings: [],
                disqualified: []
            )
        }
        func confirmMigration(_ request: AriaV2ConfirmMigrationRequest, context: AriaV2OrchestrationContext) async throws -> AriaV2MigrationConfirmationData {
            _ = context; operations.append(.confirmMigration)
            return .init(promotedBranchID: request.winnerBranchID, discardedBranchIDs: request.discardBranchIDs, discardOutcomes: request.discardBranchIDs.map { .init(branchID: $0, status: .discarded) })
        }
        func federatedSearch(_ request: AriaV2FederatedSearchRequest, context: AriaV2OrchestrationContext) async throws -> AriaV2FederatedSearchData {
            _ = request; operations.append(.federatedSearch)
            return .init(sourceEstateID: Self.sourceEstateID, requesterEstateID: context.estateID, grantID: Self.grantID, results: [.init(memoryID: Self.memoryID)])
        }
    }
}
