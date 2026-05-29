// InMemoryVectorIndex.swift

import Foundation
import PersistenceKit

final class InMemoryVectorIndex: VectorIndex, Sendable {
    private let stateActor: InMemoryStateActor

    init(stateActor: InMemoryStateActor) {
        self.stateActor = stateActor
    }

    func add(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws {
        await stateActor.putVector(key, vector: vector, metadata: metadata)
    }

    func update(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws {
        await stateActor.putVector(key, vector: vector, metadata: metadata)
    }

    func delete(key: RowKey) async throws {
        await stateActor.deleteVector(key)
    }

    func knn(
        query: [Float],
        k: Int,
        metric: DistanceMetric,
        filter: StoragePredicate?,
        searchParameters: SearchParameters?
    ) async throws -> [VectorSearchResult] {
        let vectors = await stateActor.vectorSnapshot()
        var scored: [VectorSearchResult] = []
        for (key, entry) in vectors {
            if let p = filter, !PredicateEvaluator.evaluate(p, against: entry.metadata) {
                continue
            }
            let distance = Self.computeDistance(query, entry.vector, metric: metric)
            scored.append(VectorSearchResult(key: key, distance: distance, metadata: entry.metadata))
        }
        scored.sort { $0.distance < $1.distance }
        return Array(scored.prefix(k))
    }

    func reindex(parameters: IndexParameters) async throws { /* no-op */ }

    func count() async throws -> Int { await stateActor.vectorCount() }

    private static func computeDistance(_ a: [Float], _ b: [Float], metric: DistanceMetric) -> Float {
        guard a.count == b.count else { return .greatestFiniteMagnitude }
        switch metric {
        case .l2:
            var sum: Float = 0
            for i in 0..<a.count {
                let d = a[i] - b[i]
                sum += d * d
            }
            return sum.squareRoot()
        case .cosine:
            var dot: Float = 0
            var na: Float = 0
            var nb: Float = 0
            for i in 0..<a.count {
                dot += a[i] * b[i]
                na += a[i] * a[i]
                nb += b[i] * b[i]
            }
            let denom = na.squareRoot() * nb.squareRoot()
            return denom > 0 ? 1.0 - (dot / denom) : 1.0
        case .dot:
            var dot: Float = 0
            for i in 0..<a.count { dot += a[i] * b[i] }
            return -dot
        }
    }
}
