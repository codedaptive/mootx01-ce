import Foundation
import GeniusLocusKit
import Testing
import AriaMCP
@testable import MootCommunityDaemon
import LocusKit
import PersistenceKit

@Suite("Community resident identity custody")
struct CommunityResidentIdentityCustodyTests {
    @Test("production dispatcher identity matches the signed client contract")
    func productionDispatcherIdentityMatchesClientContract() {
        #expect(CommunityResidentMain.dispatcherServerName == "ARIA_MCP")
    }

    @Test("temporary composition uses the injected identity store")
    func injectedIdentityStoreReceivesTheOnlyIdentityKey() async throws {
        let layout = FileManager.default.temporaryDirectory
            .appendingPathComponent("community-resident-identity-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: layout) }

        // A transient record over the scratch directory with an injected identity
        // store: the one estate the composition opens mints its one identity key
        // into that store and nowhere else, so a proof or test host leaves no
        // Keychain residue.
        let store = RecordingIdentityKeyStore()
        let host = CommunityEstateHost(
            record: EstateRecord(name: layout.lastPathComponent, directory: layout, kind: .transient),
            kit: GeniusLocusKit(),
            ownerIdentifier: "community-resident-test",
            identityKeyStore: store)
        _ = try await CommunityResidentMain.makeCommunityDispatch(
            host: host,
            layoutURL: layout,
            state: CommunityProviderState(
                instanceIdentifier: UUID(),
                estateIdentifier: UUID()
            ),
            obsidianWatcherPollSeconds: 600,
            obsidianEstatePollSeconds: 3_600,
            obsidianHealthCheckSeconds: 600
        )

        #expect(store.storeCount == 1)
        try await host.closeEstate()
    }

    @Test("stable provider context resolves the daemon's refreshed handle after reopen")
    func stableProviderContextRefreshesHandleAfterReopen() async throws {
        let layout = FileManager.default.temporaryDirectory
            .appendingPathComponent("community-first-party-route-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: layout) }

        let host = CommunityEstateHost(
            record: EstateRecord(name: layout.lastPathComponent, directory: layout, kind: .transient),
            kit: GeniusLocusKit(),
            ownerIdentifier: "community-first-party-route-test",
            identityKeyStore: RecordingIdentityKeyStore())
        let provider = EstateContextRecordingProvider()
        _ = try await CommunityResidentMain.makeCommunityDispatch(
            host: host,
            layoutURL: layout,
            state: CommunityProviderState(instanceIdentifier: UUID(), estateIdentifier: UUID()),
            firstPartyProvider: provider,
            obsidianWatcherPollSeconds: 600,
            obsidianEstatePollSeconds: 3_600,
            obsidianHealthCheckSeconds: 600)

        #expect(await provider.installCount == 1)
        let beforeClose = try await provider.currentEstateSession()
        #expect(await beforeClose.kit.mountState(for: beforeClose.handle) == .mounted)

        // The provider receives a resolver, never a `ToolDispatcher`. A closed
        // session becomes stale; asking the context again opens the same estate
        // through the daemon host and returns a mounted current session.
        try await host.closeEstate()
        #expect(await beforeClose.kit.mountState(for: beforeClose.handle) != .mounted)
        let afterReopen = try await provider.currentEstateSession()
        #expect(await afterReopen.kit.mountState(for: afterReopen.handle) == .mounted)
        try await host.closeEstate()
    }
}

private actor EstateContextRecordingProvider: FirstPartyProvider, FirstPartyProviderExecutorContextConsumer {
    private var context: (any FirstPartyProviderExecutorContext)?
    private(set) var installCount = 0

    func isFirstPartyProviderTool(_ name: String) async -> Bool {
        name == "first_party.context.test"
    }

    var firstPartyProviderToolList: [ProjectedTool] {
        get async {
            [ProjectedTool(
                name: "first_party.context.test",
                description: "Test stable provider context.",
                inputSchema: .object(["type": .string("object")]),
                provenance: .product)]
        }
    }

    func installFirstPartyProviderExecutorContext(_ context: any FirstPartyProviderExecutorContext) async {
        self.context = context
        installCount += 1
    }

    func dispatchFirstPartyProviderTool(
        name: String,
        arguments: JSONValue,
        context: FirstPartyProviderCallContext
    ) async throws -> JSONValue {
        guard name == "first_party.context.test" else {
            throw JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "Method not found: \(name)")
        }
        return .object(["source": .string("test-provider")])
    }

    func currentEstateSession() async throws -> FirstPartyProviderEstateSession {
        guard let context else {
            throw JSONRPCError(code: JSONRPCErrorCode.internalError, message: "provider context not installed")
        }
        return try await context.currentEstateSession()
    }
}

private final class RecordingIdentityKeyStore: EstateIdentityKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: Data] = [:]
    private var stores = 0

    var storeCount: Int { lock.withLock { stores } }

    func loadPrivateKey(forEstateID estateID: UUID) throws -> Data? {
        lock.withLock { keys[estateID] }
    }

    func storePrivateKey(_ keyData: Data, forEstateID estateID: UUID) throws {
        lock.withLock {
            stores += 1
            keys[estateID] = keyData
        }
    }

    func deletePrivateKey(forEstateID estateID: UUID) throws {
        _ = lock.withLock { keys.removeValue(forKey: estateID) }
    }
}
