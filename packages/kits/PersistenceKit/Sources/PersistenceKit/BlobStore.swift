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
}
