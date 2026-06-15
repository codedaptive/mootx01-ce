// InMemoryBlobStore.swift

import Foundation
import PersistenceKit

final class InMemoryBlobStore: BlobStore, Sendable {
    private let stateActor: InMemoryStateActor

    init(stateActor: InMemoryStateActor) {
        self.stateActor = stateActor
    }

    func put(key: BlobKey, bytes: Data) async throws { await stateActor.putBlob(key, bytes: bytes) }
    func get(key: BlobKey) async throws -> Data? { await stateActor.getBlob(key) }
    func delete(key: BlobKey) async throws { await stateActor.deleteBlob(key) }
    func exists(key: BlobKey) async throws -> Bool { await stateActor.blobExists(key) }
    func size(key: BlobKey) async throws -> Int? { await stateActor.blobSize(key) }
    func listKeys() async throws -> [BlobKey] { await stateActor.listBlobKeys() }
}
