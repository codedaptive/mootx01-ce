import Foundation
import Testing
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

        let store = RecordingIdentityKeyStore()
        _ = try await CommunityResidentMain.makeCommunityDispatch(
            layoutURL: layout,
            ownerIdentifier: "community-resident-test",
            keyProvider: { _ in .plaintext },
            identityKeyStore: store,
            state: CommunityProviderState(
                instanceIdentifier: UUID(),
                estateIdentifier: UUID()
            ),
            obsidianWatcherPollSeconds: 600,
            obsidianEstatePollSeconds: 3_600,
            obsidianHealthCheckSeconds: 600
        )

        #expect(store.storeCount == 1)
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
