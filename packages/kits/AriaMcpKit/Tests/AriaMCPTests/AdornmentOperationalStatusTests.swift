import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
@testable import AriaMCP

@Suite("Adornment operational status")
struct AdornmentOperationalStatusTests {
    private func makeDispatcher(
        provider: AdornmentOperationalStatusProvider? = nil
    ) async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "adornment-status-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore()
        )
        return ToolDispatcher(
            kit: kit,
            handle: handle,
            adornmentStatusProvider: provider
        )
    }

    private func text(of result: JSONValue) -> String {
        result.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue ?? ""
    }

    @Test("host without a provider does not fabricate miner state")
    func unavailableProviderIsAbsent() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        #expect(!text(of: result).contains("adornment_miner:"))
    }

    @Test("disabled state is explicit without fabricated counters")
    func disabledState() async throws {
        let dispatcher = try await makeDispatcher {
            AdornmentOperationalStatus(state: .disabled)
        }
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let body = text(of: result)
        #expect(body.contains("adornment_miner: disabled, identity: none"))
        #expect(!body.contains("adornment_miner_lifecycle:"))
    }

    @Test("active lifecycle counters and pending debt are surfaced")
    func activeLifecycle() async throws {
        let dispatcher = try await makeDispatcher {
            AdornmentOperationalStatus(
                state: .pending,
                identity: "nuextract-tiny-v1.5-b1-q8-p1-s1",
                pendingPairs: 1,
                logicalRequests: 17,
                requestAttempts: 18,
                processStarts: 2,
                launchFailures: 0,
                boundedRecycles: 1,
                idleReaps: 0,
                unexpectedExits: 1,
                crashRetries: 1,
                perPromptFailures: 0,
                activeChildren: 1,
                requestsInActiveChildren: 1
            )
        }
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let body = text(of: result)
        #expect(body.contains("adornment_miner: pending"))
        #expect(body.contains("pending_pairs: 1"))
        #expect(body.contains("logical_requests: 17"))
        #expect(body.contains("bounded_recycles: 1"))
        #expect(body.contains("active_children: 1"))
    }

    @Test("host detail cannot inject a status line")
    func detailIsSingleLine() async throws {
        let dispatcher = try await makeDispatcher {
            AdornmentOperationalStatus(
                state: .blocked,
                detail: "asset missing\nmemories: 999"
            )
        }
        let result = try await dispatcher.dispatch(
            name: "moot_estate_status", arguments: .object([:]))
        let body = text(of: result)
        #expect(body.contains("detail: asset missing memories: 999"))
        #expect(!body.contains("\nmemories: 999"))
    }
}
