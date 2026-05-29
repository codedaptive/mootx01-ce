// VectorIndex.swift
//
// Vector storage and k-NN search protocol per
// DECISION_STORAGEKIT_DESIGN §7 (Q5). Closed enums; no extension
// dict. Backends translate to native parameters.

import Foundation

public enum DistanceMetric: Sendable {
    case cosine
    case l2
    case dot
}

public enum IndexParameters: Sendable {
    case flat
    case ivf(lists: Int)
    case hnsw(m: Int, efConstruction: Int)
}

public enum SearchParameters: Sendable {
    case flat
    case ivf(probes: Int)
    case hnsw(efSearch: Int)
}

public struct VectorSearchResult: Sendable {
    public let key: RowKey
    public let distance: Float
    public let metadata: [String: TypedValue]

    public init(key: RowKey, distance: Float, metadata: [String: TypedValue]) {
        self.key = key
        self.distance = distance
        self.metadata = metadata
    }
}

public protocol VectorIndex: Sendable {
    func add(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws
    func update(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws
    func delete(key: RowKey) async throws
    func knn(
        query: [Float],
        k: Int,
        metric: DistanceMetric,
        filter: StoragePredicate?,
        searchParameters: SearchParameters?
    ) async throws -> [VectorSearchResult]
    func reindex(parameters: IndexParameters) async throws
    func count() async throws -> Int
}
