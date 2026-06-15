// BlobStore.swift
//
// Blob I/O protocol. Keys are arbitrary strings (typically
// content-addressed hashes or row UUID + column name).

import Foundation

public typealias BlobKey = String

public protocol BlobStore: Sendable {
    func put(key: BlobKey, bytes: Data) async throws
    func get(key: BlobKey) async throws -> Data?
    func delete(key: BlobKey) async throws
    func exists(key: BlobKey) async throws -> Bool
    func size(key: BlobKey) async throws -> Int?

    /// Return all keys currently stored in the blob store.
    ///
    /// Required by the replication primitive to enumerate blobs for a full-snapshot
    /// copy. The order of returned keys is unspecified and may differ between calls
    /// and backends; the replication primitive sorts them for deterministic ordering.
    func listKeys() async throws -> [BlobKey]
}
