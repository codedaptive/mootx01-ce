// SQLiteVectorIndex.swift
//
// Vector index backed by sqlite-vec vec0 virtual table.
// Lazy-creates the vec0 table on first add() to capture
// dimensionality.

import Foundation
import SQLite3
import PersistenceKit

final class SQLiteVectorIndex: VectorIndex, Sendable {
    let backend: SQLiteBackend
    init(backend: SQLiteBackend) { self.backend = backend }

    func add(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws {
        try await backend.addVector(key: key, vector: vector, metadata: metadata)
    }
    func update(key: RowKey, vector: [Float], metadata: [String: TypedValue]) async throws {
        try await backend.updateVector(key: key, vector: vector, metadata: metadata)
    }
    func delete(key: RowKey) async throws {
        try await backend.deleteVector(key: key)
    }
    func knn(
        query: [Float],
        k: Int,
        metric: DistanceMetric,
        filter: StoragePredicate?,
        searchParameters: SearchParameters?
    ) async throws -> [VectorSearchResult] {
        try await backend.knnVector(query: query, k: k, metric: metric, filter: filter)
    }
    func reindex(parameters: IndexParameters) async throws {
        // sqlite-vec vec0 is updated incrementally; reindex is a no-op for now.
    }
    func count() async throws -> Int {
        try await backend.vectorCount()
    }
}

// MARK: - Backend vector operations

extension SQLiteBackend {

    func ensureVec0Table(dimensions: Int) throws {
        // Idempotent. Creates the vec0 virtual table if not present.
        let stmt = try connection.prepare("""
            SELECT name FROM sqlite_master WHERE type='table' AND name='_storagekit_vectors'
            """)
        defer { stmt.finalize() }
        if try stmt.step() { return }
        // Create with the requested dimensionality.
        let sql = """
            CREATE VIRTUAL TABLE "_storagekit_vectors" USING vec0(
              embedding FLOAT[\(dimensions)]
            )
            """
        try connection.exec(sql)
    }

    func addVector(key: RowKey, vector: [Float], metadata: [String: TypedValue]) throws {
        try ensureVec0Table(dimensions: vector.count)

        // Encode vector as little-endian Float32 blob (vec0 native format).
        var blob = Data()
        for f in vector {
            var v = f.bitPattern.littleEndian
            blob.append(Data(bytes: &v, count: 4))
        }

        // Insert into vec0 table to get a rowid.
        let vecInsert = try connection.prepare("""
            INSERT INTO "_storagekit_vectors" (embedding) VALUES (?)
            """)
        defer { vecInsert.finalize() }
        try vecInsert.bind(.blob(blob), at: 1)
        _ = try vecInsert.step()
        let vecRowid = sqlite3_last_insert_rowid(connection.handle)

        // Insert mapping in metadata table.
        let metaJSON = encodeMetadata(metadata)
        let metaInsert = try connection.prepare("""
            INSERT INTO "_storagekit_vector_meta" ("key", "vec_rowid", "metadata_json")
            VALUES (?, ?, ?)
            ON CONFLICT("key") DO UPDATE SET "vec_rowid" = excluded.vec_rowid, "metadata_json" = excluded.metadata_json
            """)
        defer { metaInsert.finalize() }
        try metaInsert.bind(.text(key.uuidString), at: 1)
        try metaInsert.bind(.int(vecRowid), at: 2)
        try metaInsert.bind(.text(metaJSON), at: 3)
        _ = try metaInsert.step()
    }

    func updateVector(key: RowKey, vector: [Float], metadata: [String: TypedValue]) throws {
        // Look up existing vec_rowid; if absent, treat as add.
        let lookup = try connection.prepare("""
            SELECT "vec_rowid" FROM "_storagekit_vector_meta" WHERE "key" = ?
            """)
        defer { lookup.finalize() }
        try lookup.bind(.text(key.uuidString), at: 1)
        guard try lookup.step() else {
            try addVector(key: key, vector: vector, metadata: metadata)
            return
        }
        let vecRowid = lookup.columnInt64(0)

        var blob = Data()
        for f in vector {
            var v = f.bitPattern.littleEndian
            blob.append(Data(bytes: &v, count: 4))
        }

        let upd = try connection.prepare("""
            UPDATE "_storagekit_vectors" SET embedding = ? WHERE rowid = ?
            """)
        defer { upd.finalize() }
        try upd.bind(.blob(blob), at: 1)
        try upd.bind(.int(vecRowid), at: 2)
        _ = try upd.step()

        let metaUpd = try connection.prepare("""
            UPDATE "_storagekit_vector_meta" SET "metadata_json" = ? WHERE "key" = ?
            """)
        defer { metaUpd.finalize() }
        try metaUpd.bind(.text(encodeMetadata(metadata)), at: 1)
        try metaUpd.bind(.text(key.uuidString), at: 2)
        _ = try metaUpd.step()
    }

    func deleteVector(key: RowKey) throws {
        let lookup = try connection.prepare("""
            SELECT "vec_rowid" FROM "_storagekit_vector_meta" WHERE "key" = ?
            """)
        defer { lookup.finalize() }
        try lookup.bind(.text(key.uuidString), at: 1)
        guard try lookup.step() else { return }
        let vecRowid = lookup.columnInt64(0)

        let delVec = try connection.prepare("DELETE FROM \"_storagekit_vectors\" WHERE rowid = ?")
        defer { delVec.finalize() }
        try delVec.bind(.int(vecRowid), at: 1)
        _ = try delVec.step()

        let delMeta = try connection.prepare("DELETE FROM \"_storagekit_vector_meta\" WHERE \"key\" = ?")
        defer { delMeta.finalize() }
        try delMeta.bind(.text(key.uuidString), at: 1)
        _ = try delMeta.step()
    }

    func knnVector(
        query: [Float],
        k: Int,
        metric: DistanceMetric,
        filter: StoragePredicate?
    ) throws -> [VectorSearchResult] {
        // Check if vec0 table exists; if not, no results.
        let check = try connection.prepare("""
            SELECT name FROM sqlite_master WHERE type='table' AND name='_storagekit_vectors'
            """)
        defer { check.finalize() }
        guard try check.step() else { return [] }

        var blob = Data()
        for f in query {
            var v = f.bitPattern.littleEndian
            blob.append(Data(bytes: &v, count: 4))
        }

        // vec0 KNN syntax: WHERE embedding MATCH ? ORDER BY distance LIMIT ?
        // Note: vec0 uses L2 by default. For cosine, we'd normalize inputs
        // (caller is responsible for that until we expose metric routing).
        // vec0 requires the k constraint in the WHERE clause, not just LIMIT.
        let sql = """
            SELECT m."key", v.distance, m."metadata_json"
            FROM "_storagekit_vectors" v
            JOIN "_storagekit_vector_meta" m ON m."vec_rowid" = v.rowid
            WHERE v.embedding MATCH ? AND k = ?
            ORDER BY v.distance
            """
        let stmt = try connection.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(.blob(blob), at: 1)
        try stmt.bind(.int(Int64(k)), at: 2)

        var results: [VectorSearchResult] = []
        while try stmt.step() {
            let keyStr = stmt.columnText(0) ?? ""
            guard let key = UUID(uuidString: keyStr) else { continue }
            let distance = Float(stmt.columnDouble(1))
            let metaJSON = stmt.columnText(2) ?? "{}"
            let metadata = decodeMetadata(metaJSON)

            // Filter metadata in-memory (predicate compilation against
            // JSON columns is a v1.x improvement).
            if let filter, !evaluateFilter(filter, against: metadata) {
                continue
            }
            // Adjust distance for cosine/dot if caller asked. For v1.0 we
            // pass through; advanced metric routing is a follow-up.
            let _ = metric
            results.append(VectorSearchResult(key: key, distance: distance, metadata: metadata))
        }
        return results
    }

    func vectorCount() throws -> Int {
        let check = try connection.prepare("""
            SELECT name FROM sqlite_master WHERE type='table' AND name='_storagekit_vector_meta'
            """)
        defer { check.finalize() }
        guard try check.step() else { return 0 }
        let stmt = try connection.prepare("SELECT COUNT(*) FROM \"_storagekit_vector_meta\"")
        defer { stmt.finalize() }
        guard try stmt.step() else { return 0 }
        return Int(stmt.columnInt64(0))
    }

    // MARK: - Metadata helpers

    private func encodeMetadata(_ meta: [String: TypedValue]) -> String {
        var dict: [String: String] = [:]
        for (k, v) in meta {
            dict[k] = String(describing: v)  // simple serialization for v1.0
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    private func decodeMetadata(_ json: String) -> [String: TypedValue] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return obj.mapValues { .text($0) }
    }

    private func evaluateFilter(_ predicate: StoragePredicate, against metadata: [String: TypedValue]) -> Bool {
        switch predicate {
        case .isTrue: return true
        case .isFalse: return false
        case .and(let preds): return preds.allSatisfy { evaluateFilter($0, against: metadata) }
        case .or(let preds): return preds.contains { evaluateFilter($0, against: metadata) }
        case .not(let p): return !evaluateFilter(p, against: metadata)
        case .eq(let col, let v): return metadata[col.name] == v
        case .neq(let col, let v): return metadata[col.name] != v
        case .isNull(let col): return (metadata[col.name] ?? .null).isNull
        case .isNotNull(let col): return !(metadata[col.name] ?? .null).isNull
        default: return true  // Conservative: pass anything we can't evaluate locally
        }
    }
}
