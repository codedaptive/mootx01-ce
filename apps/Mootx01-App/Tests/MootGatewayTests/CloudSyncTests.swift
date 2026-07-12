import Testing
import Foundation
@testable import MootGateway

// MARK: - CloudSync courier orchestration tests
//
// The coordinator's logic is tested with a recording courier and an
// in-memory backend — no CloudKit, no vault internals. What matters is the
// orchestration: account gating, pull-before-push ordering, engine-reconcile
// hand-off, and honest no-op when there's no account or no remote snapshot.

private actor RecordingCourier: EstateSnapshotCourier {
    let exportPayload: Data
    private(set) var exported = 0
    private(set) var imported: [Data] = []

    init(exportPayload: Data = Data("local-snapshot".utf8)) {
        self.exportPayload = exportPayload
    }
    func exportSnapshot() async throws -> Data { exported += 1; return exportPayload }
    func importSnapshot(_ data: Data) async throws { imported.append(data) }

    func exportCount() async -> Int { exported }
    func importedSnapshots() async -> [Data] { imported }
}

private actor InMemoryBackend: CloudSyncBackend {
    var available: Bool
    private var store: [String: Data] = [:]
    private(set) var uploads = 0

    init(available: Bool = true, seeded: [String: Data] = [:]) {
        self.available = available
        self.store = seeded
    }
    func accountAvailable() async -> Bool { available }
    func upload(key: String, data: Data) async throws { store[key] = data; uploads += 1 }
    func download(key: String) async throws -> Data? { store[key] }

    func uploadCount() async -> Int { uploads }
    func stored(_ key: String) async -> Data? { store[key] }
}

@Suite("CloudSyncCoordinator — courier orchestration")
struct CloudSyncTests {

    @Test("no iCloud account: nothing exported, nothing uploaded")
    func skipWithoutAccount() async throws {
        let courier = RecordingCourier()
        let backend = InMemoryBackend(available: false)
        let coord = CloudSyncCoordinator(courier: courier, backend: backend)

        let outcomes = try await coord.sync()
        #expect(outcomes == [.skippedNoAccount])
        #expect(await courier.exportCount() == 0, "must not touch the estate without an account")
        #expect(await backend.uploadCount() == 0)
    }

    @Test("push exports the local snapshot and uploads it under the snapshot key")
    func pushUploads() async throws {
        let courier = RecordingCourier(exportPayload: Data("v1".utf8))
        let backend = InMemoryBackend()
        let coord = CloudSyncCoordinator(courier: courier, backend: backend)

        let outcome = try await coord.push()
        #expect(outcome == .pushed(bytes: 2))
        #expect(await backend.stored(CloudSyncCoordinator.snapshotKey) == Data("v1".utf8))
    }

    @Test("pull hands the remote snapshot to the engine to reconcile")
    func pullImports() async throws {
        let remote = Data("remote-snapshot".utf8)
        let courier = RecordingCourier()
        let backend = InMemoryBackend(seeded: [CloudSyncCoordinator.snapshotKey: remote])
        let coord = CloudSyncCoordinator(courier: courier, backend: backend)

        let outcome = try await coord.pull()
        #expect(outcome == .pulled(bytes: remote.count))
        #expect(await courier.importedSnapshots() == [remote], "the engine receives exactly the remote bytes")
    }

    @Test("pull on the first device (no remote snapshot) imports nothing")
    func pullNothingRemote() async throws {
        let courier = RecordingCourier()
        let backend = InMemoryBackend()   // empty store
        let coord = CloudSyncCoordinator(courier: courier, backend: backend)

        #expect(try await coord.pull() == .nothingRemote)
        #expect(await courier.importedSnapshots().isEmpty)
    }

    @Test("sync pulls before it pushes: remote merges in, then local re-publishes")
    func syncPullsThenPushes() async throws {
        let remote = Data("remote".utf8)
        let courier = RecordingCourier(exportPayload: Data("merged-local".utf8))
        let backend = InMemoryBackend(seeded: [CloudSyncCoordinator.snapshotKey: remote])
        let coord = CloudSyncCoordinator(courier: courier, backend: backend)

        let outcomes = try await coord.sync()
        #expect(outcomes == [.pulled(bytes: remote.count), .pushed(bytes: 12)])
        // Remote was imported (engine merges), then the local state re-uploaded.
        #expect(await courier.importedSnapshots() == [remote])
        #expect(await backend.stored(CloudSyncCoordinator.snapshotKey) == Data("merged-local".utf8))
    }
}
