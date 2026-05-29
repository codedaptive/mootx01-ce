// PostgreSQLVectorIndex.swift
//
// pgvector-backed vector index.

import Foundation
import PersistenceKit
@preconcurrency import PostgresNIO
import Logging

final class PostgreSQLVectorIndex: VectorIndex, Sendable {
    let backend: PostgreSQLBackend
    let txn: PostgreSQLTransactionContext?

    init(backend: PostgreSQLBackend, txn: PostgreSQLTransactionContext? = nil) {
        self.backend = backend
        self.txn = txn
    }

    private func withConnection<T: Sendable>(_ block: @Sendable (PostgresConnection) async throws -> T) async throws -> T {
        if let txn { return try await block(txn.connection) }
        let conn = try await backend.pool.acquire()
        defer { Task { await backend.pool.release(conn) } }
        return try await block(conn)
    }

    private func ensureVectorTable(_ conn: PostgresConnection, dim: Int) async throws {
        try await conn.executeSimple("CREATE EXTENSION IF NOT EXISTS vector", logger: Logger(label: "pg.vec"))
        try await conn.executeSimple("""
            CREATE TABLE IF NOT EXISTS "_storagekit_vectors" (
              "key" UUID PRIMARY KEY,
              "embedding" vector(\(dim)) NOT NULL,
              "metadata_json" TEXT NOT NULL DEFAULT '{}'
            )
            """, logger: Logger(label: "pg.vec"))
    }

    func add(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws {
        try await withConnection { conn in
            try await ensureVectorTable(conn, dim: vector.count)
            let vecStr = "[" + vector.map { String($0) }.joined(separator: ",") + "]"
            let metaJSON = encodeMetadata(metadata)
            _ = try await conn.executeParameterized("""
                INSERT INTO "_storagekit_vectors" ("key", "embedding", "metadata_json")
                VALUES ($1, $2::vector, $3)
                ON CONFLICT ("key") DO UPDATE
                  SET "embedding" = EXCLUDED."embedding", "metadata_json" = EXCLUDED."metadata_json"
                """, bindings: [.uuid(key), .text(vecStr), .text(metaJSON)], logger: Logger(label: "pg.vec.add"))
        }
    }

    func update(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws {
        try await add(key: key, vector: vector, metadata: metadata)
    }

    func delete(key: RowKey) async throws {
        try await withConnection { conn in
            _ = try await conn.executeParameterized(
                "DELETE FROM \"_storagekit_vectors\" WHERE \"key\" = $1",
                bindings: [.uuid(key)],
                logger: Logger(label: "pg.vec.del")
            )
        }
    }

    func knn(
        query: [Float],
        k: Int,
        metric: DistanceMetric,
        filter: StoragePredicate?,
        searchParameters: SearchParameters?
    ) async throws -> [VectorSearchResult] {
        let vecStr = "[" + query.map { String($0) }.joined(separator: ",") + "]"
        let op: String
        switch metric {
        case .cosine: op = "<=>"
        case .l2: op = "<->"
        case .dot: op = "<#>"
        }
        let sql = """
            SELECT "key", ("embedding" \(op) $1::vector) AS distance, "metadata_json"
            FROM "_storagekit_vectors"
            ORDER BY "embedding" \(op) $1::vector
            LIMIT \(k)
            """
        return try await withConnection { conn in
            // Make sure table exists; otherwise return empty.
            let check = try await conn.executeParameterized(
                "SELECT to_regclass('_storagekit_vectors') AS reg",
                bindings: [],
                logger: Logger(label: "pg.vec.check")
            )
            var exists = false
            for try await row in check {
                let access = row.makeRandomAccess()
                if let cell = try? access["reg"] {
                    if let s: String? = try? cell.decode(String?.self, context: .default), s != nil {
                        exists = true
                    }
                }
            }
            if !exists { return [] }

            let pgRows = try await conn.executeParameterized(sql, bindings: [.text(vecStr)], logger: Logger(label: "pg.vec.knn"))
            var results: [VectorSearchResult] = []
            for try await row in pgRows {
                let access = row.makeRandomAccess()
                guard let keyCell = try? access["key"],
                      let key: UUID = try? keyCell.decode(UUID.self, context: .default) else { continue }
                let distance: Double = (try? access["distance"].decode(Double.self, context: .default)) ?? 0
                let metaStr: String = (try? access["metadata_json"].decode(String.self, context: .default)) ?? "{}"
                let metadata = decodeMetadata(metaStr)
                // Filter in-memory until predicate compilation against JSONB columns is added.
                if let f = filter, !evaluateFilter(f, against: metadata) { continue }
                results.append(VectorSearchResult(key: key, distance: Float(distance), metadata: metadata))
            }
            return results
        }
    }

    func reindex(parameters: IndexParameters) async throws {
        // pgvector: HNSW index creation is per-table; skip for v1.0 unless explicitly requested.
    }

    func count() async throws -> Int {
        try await withConnection { conn in
            let check = try await conn.executeParameterized(
                "SELECT to_regclass('_storagekit_vectors') AS reg",
                bindings: [],
                logger: Logger(label: "pg.vec.check")
            )
            var exists = false
            for try await row in check {
                let access = row.makeRandomAccess()
                if let cell = try? access["reg"] {
                    if let s: String? = try? cell.decode(String?.self, context: .default), s != nil {
                        exists = true
                    }
                }
            }
            if !exists { return 0 }
            let rows = try await conn.executeParameterized(
                "SELECT COUNT(*) AS \"c\" FROM \"_storagekit_vectors\"",
                bindings: [],
                logger: Logger(label: "pg.vec.count")
            )
            for try await row in rows {
                let access = row.makeRandomAccess()
                if let cell = try? access["c"], let i: Int64 = try? cell.decode(Int64.self, context: .default) {
                    return Int(i)
                }
            }
            return 0
        }
    }
}

// MARK: - Metadata helpers

private func encodeMetadata(_ m: [String: TypedValue]) -> String {
    var obj: [String: Any] = [:]
    for (k, v) in m {
        switch v {
        case .null: obj[k] = NSNull()
        case .bool(let b): obj[k] = b
        case .int(let i), .bitmap(let i): obj[k] = i
        case .float(let f): obj[k] = f
        case .text(let s): obj[k] = s
        case .uuid(let u): obj[k] = u.uuidString
        case .timestamp(let d): obj[k] = ISO8601DateFormatter().string(from: d)
        default: continue
        }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
}

private func decodeMetadata(_ s: String) -> [String: TypedValue] {
    guard let data = s.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    var out: [String: TypedValue] = [:]
    for (k, v) in obj {
        if let s = v as? String { out[k] = .text(s) }
        else if let b = v as? Bool { out[k] = .bool(b) }
        else if let i = v as? Int64 { out[k] = .int(i) }
        else if let i = v as? Int { out[k] = .int(Int64(i)) }
        else if let f = v as? Double { out[k] = .float(f) }
        else if v is NSNull { out[k] = .null }
    }
    return out
}

private func evaluateFilter(_ p: StoragePredicate, against meta: [String: TypedValue]) -> Bool {
    switch p {
    case .and(let xs): return xs.allSatisfy { evaluateFilter($0, against: meta) }
    case .or(let xs): return xs.contains { evaluateFilter($0, against: meta) }
    case .not(let inner): return !evaluateFilter(inner, against: meta)
    case .isTrue: return true
    case .isFalse: return false
    case .eq(let c, let v): return (meta[c.name] ?? .null) == v
    case .neq(let c, let v): return (meta[c.name] ?? .null) != v
    case .isNull(let c): return (meta[c.name] ?? .null).isNull
    case .isNotNull(let c): return !(meta[c.name] ?? .null).isNull
    default: return true
    }
}
