// PostgreSQLStores.swift
//
// RowStore, BlobStore, AuditLog implementations for PostgreSQL.

import Foundation
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes
@preconcurrency import PostgresNIO
import Logging

// MARK: - RowStore

final class PostgreSQLRowStore: RowStore, Sendable {
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

    func insert(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        // At-rest encryption seam (Mode 2 / RowEncryption): encrypt the content
        // column and stamp the keyID before binding. No-op for plaintext. The
        // structural invariant then confirms a content row carries a keyID, so
        // the seam cannot silently write unreadable plaintext content.
        let values = try encryptedForWrite(values, config: backend.encryptionConfig)
        try assertContentKeyIDInvariant(values, table: table, config: backend.encryptionConfig)
        let cols = Array(values.keys).sorted()
        let placeholders = (1...cols.count).map { "$\($0)" }.joined(separator: ", ")
        let colList = cols.map { "\"\($0)\"" }.joined(separator: ", ")
        let sql = "INSERT INTO \"\(table)\" (\(colList)) VALUES (\(placeholders))"
        let bindings = cols.map { values[$0]! }
        let pk = await backend.primaryKey(for: table)
        let key: RowKey
        if pk.count == 1, let pkVal = values[pk[0]], case let .uuid(u) = pkVal {
            key = u
        } else {
            key = UUID()
        }
        try await withConnection { conn in
            _ = try await conn.executeParameterized(sql, bindings: bindings, logger: Logger(label: "pg.row.insert"))
        }
        return RowHandle(table: table, key: key)
    }

    func upsert(table: String, values: [String: TypedValue], conflictColumns: [String]) async throws -> RowHandle {
        // upsert is not wired to encrypt: in the LocusKit schema it is only
        // called for non-content tables. The structural invariant guards
        // against a future content-bearing upsert writing plaintext with a
        // null keyID — it must extend the encryption seam first.
        try assertContentKeyIDInvariant(values, table: table, config: backend.encryptionConfig)
        let cols = Array(values.keys).sorted()
        let placeholders = (1...cols.count).map { "$\($0)" }.joined(separator: ", ")
        let colList = cols.map { "\"\($0)\"" }.joined(separator: ", ")
        let conflictList = conflictColumns.map { "\"\($0)\"" }.joined(separator: ", ")
        let updateSets = cols
            .filter { !conflictColumns.contains($0) }
            .map { "\"\($0)\" = EXCLUDED.\"\($0)\"" }
            .joined(separator: ", ")
        let onConflict: String
        if updateSets.isEmpty {
            onConflict = "ON CONFLICT (\(conflictList)) DO NOTHING"
        } else {
            onConflict = "ON CONFLICT (\(conflictList)) DO UPDATE SET \(updateSets)"
        }
        let sql = "INSERT INTO \"\(table)\" (\(colList)) VALUES (\(placeholders)) \(onConflict)"
        let bindings = cols.map { values[$0]! }
        try await withConnection { conn in
            _ = try await conn.executeParameterized(sql, bindings: bindings, logger: Logger(label: "pg.row.upsert"))
        }
        let pk = await backend.primaryKey(for: table)
        if pk.count == 1, let pkVal = values[pk[0]], case let .uuid(u) = pkVal {
            return RowHandle(table: table, key: u)
        }
        return RowHandle(table: table, key: UUID())
    }

    func update(table: String, values: [String: TypedValue], where predicate: StoragePredicate) async throws -> Int {
        // update does not run the encryption seam, so a content update on an
        // encrypting estate would write plaintext with a null keyID. Guard it
        // like the other write paths; all current callers update only
        // bitmap/timestamp columns, so this is a no-op for them.
        try assertContentKeyIDInvariant(values, table: table, config: backend.encryptionConfig)
        let cols = Array(values.keys).sorted()
        var bindings: [TypedValue] = []
        for c in cols { bindings.append(values[c]!) }
        var setClauses: [String] = []
        for (i, c) in cols.enumerated() {
            setClauses.append("\"\(c)\" = $\(i + 1)")
        }
        // Compile predicate with bindings starting at $\(cols.count + 1)
        var predBindings: [TypedValue] = []
        let predSQL = renderPredicate(predicate, startIndex: cols.count + 1, bindings: &predBindings)
        bindings.append(contentsOf: predBindings)
        let sql = "UPDATE \"\(table)\" SET \(setClauses.joined(separator: ", ")) WHERE \(predSQL)"
        let _sql = sql
        let _bindings = bindings
        return try await withConnection { conn in
            let rows = try await conn.executeParameterized(_sql, bindings: _bindings, logger: Logger(label: "pg.row.update"))
            var count = 0
            for try await _ in rows { count += 1 }
            return count
        }
    }

    func delete(table: String, where predicate: StoragePredicate) async throws -> Int {
        var bindings: [TypedValue] = []
        let predSQL = renderPredicate(predicate, startIndex: 1, bindings: &bindings)
        let sql = "DELETE FROM \"\(table)\" WHERE \(predSQL)"
        let _sql = sql
        let _bindings = bindings
        return try await withConnection { conn in
            _ = try await conn.executeParameterized(_sql, bindings: _bindings, logger: Logger(label: "pg.row.delete"))
            return 1
        }
    }

    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?
    ) async throws -> [StorageRow] {
        let columns = await backend.columns(for: table)
        let colSelect = columns.isEmpty ? "*" : columns.map { "\"\($0.name)\"" }.joined(separator: ", ")
        var sql = "SELECT \(colSelect) FROM \"\(table)\""
        var bindings: [TypedValue] = []
        if let p = predicate {
            let where_ = renderPredicate(p, startIndex: 1, bindings: &bindings)
            sql += " WHERE \(where_)"
        }
        if !orderBy.isEmpty {
            let parts = orderBy.map { "\"\($0.column.name)\" \($0.direction == .ascending ? "ASC" : "DESC")" }
            sql += " ORDER BY " + parts.joined(separator: ", ")
        }
        if let lim = limit { sql += " LIMIT \(lim)" }
        if let off = offset { sql += " OFFSET \(off)" }

        let _sql = sql
        let _bindings = bindings
        let _columns = columns
        // Capture the encryption config for the @Sendable closure; the per-row
        // decrypt seam reverses encryptedForWrite on read (no-op for plaintext).
        let _encConfig = backend.encryptionConfig
        return try await withConnection { conn in
            let pgRows = try await conn.executeParameterized(_sql, bindings: _bindings, logger: Logger(label: "pg.row.query"))
            var out: [StorageRow] = []
            for try await row in pgRows {
                let decoded = try decryptedForRead(decodeRow(row, columns: _columns), config: _encConfig)
                out.append(StorageRow(values: decoded))
            }
            return out
        }
    }

    func count(table: String, where predicate: StoragePredicate?) async throws -> Int {
        var sql = "SELECT COUNT(*) AS \"c\" FROM \"\(table)\""
        var bindings: [TypedValue] = []
        if let p = predicate {
            sql += " WHERE \(renderPredicate(p, startIndex: 1, bindings: &bindings))"
        }
        let _sql = sql
        let _bindings = bindings
        return try await withConnection { conn in
            let pgRows = try await conn.executeParameterized(_sql, bindings: _bindings, logger: Logger(label: "pg.row.count"))
            for try await row in pgRows {
                let access = row.makeRandomAccess()
                if let i: Int64 = try? access["c"].decode(Int64.self, context: .default) {
                    return Int(i)
                }
            }
            return 0
        }
    }

    /// Predicate render with custom $-index start (for UPDATE statements).
    private func renderPredicate(_ p: StoragePredicate, startIndex: Int, bindings: inout [TypedValue]) -> String {
        // Compile and then renumber parameters.
        let compiled = PostgreSQLPredicateCompiler.compile(p)
        bindings.append(contentsOf: compiled.bindings)
        // Replace $1 → $\(startIndex), $2 → $\(startIndex+1), ...
        guard startIndex != 1 else { return compiled.sql }
        var sql = compiled.sql
        // Renumber in reverse to avoid clobbering ($10 first then $1, etc).
        for i in (1...compiled.bindings.count).reversed() {
            sql = sql.replacingOccurrences(of: "$\(i)", with: "$\(i + startIndex - 1)")
        }
        return sql
    }
}

// MARK: - BlobStore

final class PostgreSQLBlobStore: BlobStore, Sendable {
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

    private func ensureBlobTable(_ conn: PostgresConnection) async throws {
        try await conn.executeSimple("""
            CREATE TABLE IF NOT EXISTS "_storagekit_blobs" (
              "key" TEXT PRIMARY KEY,
              "data" BYTEA NOT NULL
            )
            """, logger: Logger(label: "pg.blob"))
    }

    func put(key: BlobKey, bytes: Data) async throws {
        try await withConnection { conn in
            try await ensureBlobTable(conn)
            _ = try await conn.executeParameterized("""
                INSERT INTO "_storagekit_blobs" ("key", "data") VALUES ($1, $2)
                ON CONFLICT ("key") DO UPDATE SET "data" = EXCLUDED."data"
                """, bindings: [.text(key), .blob(bytes)], logger: Logger(label: "pg.blob.put"))
        }
    }

    func get(key: BlobKey) async throws -> Data? {
        try await withConnection { conn in
            try await ensureBlobTable(conn)
            let rows = try await conn.executeParameterized(
                "SELECT \"data\" FROM \"_storagekit_blobs\" WHERE \"key\" = $1",
                bindings: [.text(key)],
                logger: Logger(label: "pg.blob.get")
            )
            for try await row in rows {
                let access = row.makeRandomAccess()
                if let b: ByteBuffer = try? access["data"].decode(ByteBuffer.self, context: .default) {
                    return Data(buffer: b)
                }
            }
            return nil
        }
    }

    func delete(key: BlobKey) async throws {
        try await withConnection { conn in
            try await ensureBlobTable(conn)
            _ = try await conn.executeParameterized(
                "DELETE FROM \"_storagekit_blobs\" WHERE \"key\" = $1",
                bindings: [.text(key)],
                logger: Logger(label: "pg.blob.delete")
            )
        }
    }

    func exists(key: BlobKey) async throws -> Bool {
        return try await get(key: key) != nil
    }

    func size(key: BlobKey) async throws -> Int? {
        return try await get(key: key)?.count
    }

    func listKeys() async throws -> [BlobKey] {
        try await withConnection { conn in
            try await ensureBlobTable(conn)
            let rows = try await conn.executeParameterized(
                "SELECT \"key\" FROM \"_storagekit_blobs\"",
                bindings: [],
                logger: Logger(label: "pg.blob.listkeys")
            )
            var keys: [BlobKey] = []
            for try await row in rows {
                let access = row.makeRandomAccess()
                if let k: String = try? access["key"].decode(String.self, context: .default) {
                    keys.append(k)
                }
            }
            return keys
        }
    }
}

// MARK: - AuditLog

final class PostgreSQLAuditLog: AuditLog, Sendable {
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

    private func ensureAuditTable(_ conn: PostgresConnection) async throws {
        try await conn.executeSimple("""
            CREATE TABLE IF NOT EXISTS "_storagekit_audit" (
              "event_id" UUID NOT NULL,
              "hlc_packed" BIGINT NOT NULL,
              "estate_uuid" UUID NOT NULL,
              "row_id" UUID NOT NULL,
              "verb" TEXT NOT NULL,
              "before_adj" BIGINT,
              "before_op" BIGINT,
              "before_prov" BIGINT,
              "after_adj" BIGINT NOT NULL,
              "after_op" BIGINT NOT NULL,
              "after_prov" BIGINT NOT NULL,
              "before_udc" BIGINT,
              "before_qid" BIGINT,
              "after_udc" BIGINT NOT NULL,
              "after_qid" BIGINT NOT NULL,
              "actor" TEXT NOT NULL,
              "reason" TEXT,
              PRIMARY KEY ("event_id", "hlc_packed")
            )
            """, logger: Logger(label: "pg.audit"))
        try await conn.executeSimple(
            "CREATE INDEX IF NOT EXISTS \"idx_audit_row_id\" ON \"_storagekit_audit\" (\"row_id\")",
            logger: Logger(label: "pg.audit")
        )
        try await conn.executeSimple(
            "CREATE INDEX IF NOT EXISTS \"idx_audit_hlc\" ON \"_storagekit_audit\" (\"hlc_packed\")",
            logger: Logger(label: "pg.audit")
        )
    }

    func append(_ event: AuditEvent) async throws {
        try await withConnection { conn in
            try await ensureAuditTable(conn)
            let packed = Int64(bitPattern: event.hlc.packed)
            let bindings: [TypedValue] = [
                .uuid(event.eventID),
                .int(packed),
                .uuid(event.estateUuid),
                .uuid(event.rowId),
                .text(event.verb),
                event.beforeBitmaps.map { .int($0.adjective) } ?? .null,
                event.beforeBitmaps.map { .int($0.operational) } ?? .null,
                event.beforeBitmaps.map { .int($0.provenance) } ?? .null,
                .int(event.afterBitmaps.adjective),
                .int(event.afterBitmaps.operational),
                .int(event.afterBitmaps.provenance),
                event.beforeLatticeAnchor.map { .int(Int64(bitPattern: $0.udcCode)) } ?? .null,
                event.beforeLatticeAnchor.map { .int(Int64(bitPattern: $0.qidPointer)) } ?? .null,
                .int(Int64(bitPattern: event.afterLatticeAnchor.udcCode)),
                .int(Int64(bitPattern: event.afterLatticeAnchor.qidPointer)),
                .text(event.actor),
                // reason is nullable TEXT; NULL when the caller supplied no reason.
                event.reason.map { .text($0) } ?? .null
            ]
            _ = try await conn.executeParameterized("""
                INSERT INTO "_storagekit_audit"
                  ("event_id", "hlc_packed", "estate_uuid", "row_id", "verb",
                   "before_adj", "before_op", "before_prov",
                   "after_adj", "after_op", "after_prov",
                   "before_udc", "before_qid", "after_udc", "after_qid",
                   "actor", "reason")
                VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)
                ON CONFLICT ("event_id", "hlc_packed") DO NOTHING
                """, bindings: bindings, logger: Logger(label: "pg.audit.append"))
        }
    }

    func appendBatch(_ events: [AuditEvent]) async throws {
        for e in events {
            try await append(e)
        }
    }

    func iterate(after: HLC?, rowID: UUID?, limit: Int) async throws -> [AuditEvent] {
        var sql = "SELECT * FROM \"_storagekit_audit\""
        var conditions: [String] = []
        var bindings: [TypedValue] = []
        if let after {
            bindings.append(.int(Int64(bitPattern: after.packed)))
            conditions.append("\"hlc_packed\" > $\(bindings.count)")
        }
        if let rowID {
            bindings.append(.uuid(rowID))
            conditions.append("\"row_id\" = $\(bindings.count)")
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY \"hlc_packed\" ASC LIMIT \(limit)"

        let _sql = sql
        let _bindings = bindings
        return try await withConnection { conn in
            try await ensureAuditTable(conn)
            let pgRows = try await conn.executeParameterized(_sql, bindings: _bindings, logger: Logger(label: "pg.audit.iter"))
            var out: [AuditEvent] = []
            for try await row in pgRows {
                // decodeAuditEvent throws on any required-field decode failure;
                // error propagates to the caller rather than silently dropping
                // a corrupt audit record.
                out.append(try decodeAuditEvent(row))
            }
            return out
        }
    }

    func eventsForRow(_ rowID: UUID) async throws -> [AuditEvent] {
        try await iterate(after: nil, rowID: rowID, limit: 10_000)
    }

    func count() async throws -> Int {
        try await withConnection { conn in
            try await ensureAuditTable(conn)
            let pgRows = try await conn.executeParameterized(
                "SELECT COUNT(*) AS \"c\" FROM \"_storagekit_audit\"",
                bindings: [],
                logger: Logger(label: "pg.audit.count")
            )
            for try await row in pgRows {
                let access = row.makeRandomAccess()
                if let i: Int64 = try? access["c"].decode(Int64.self, context: .default) { return Int(i) }
            }
            return 0
        }
    }
}

/// Decode one PostgreSQL row into an AuditEvent, throwing on any parse failure.
///
/// Required columns (event_id, hlc_packed, estate_uuid, row_id, verb, actor,
/// after_adj/op/prov, after_udc/qid) are decoded with `try` so a corrupt or
/// missing field surfaces as a thrown error rather than silently dropping the
/// event. Optional bitmap and lattice anchor columns use `try?` — NULL is the
/// intended storage value for "no before-state", so a decode failure there is
/// treated as absent (correct behaviour for NULL; corrupt non-NULL BIGINT would
/// also be caught by the PostgreSQL wire decoder before reaching this function).
/// The `reason` column is nullable TEXT; try? on a NULL column returns nil,
/// which is the correct value for events recorded without a caller reason.
private func decodeAuditEvent(_ row: PostgresRow) throws -> AuditEvent {
    let access = row.makeRandomAccess()
    let eventID: UUID = try access["event_id"].decode(UUID.self, context: .default)
    let hlcPacked: Int64 = try access["hlc_packed"].decode(Int64.self, context: .default)
    let estateUuid: UUID = try access["estate_uuid"].decode(UUID.self, context: .default)
    let rowId: UUID = try access["row_id"].decode(UUID.self, context: .default)
    let verb: String = try access["verb"].decode(String.self, context: .default)
    let actor: String = try access["actor"].decode(String.self, context: .default)
    let afterAdj: Int64 = try access["after_adj"].decode(Int64.self, context: .default)
    let afterOp: Int64 = try access["after_op"].decode(Int64.self, context: .default)
    let afterProv: Int64 = try access["after_prov"].decode(Int64.self, context: .default)
    let afterUdc: Int64 = try access["after_udc"].decode(Int64.self, context: .default)
    let afterQid: Int64 = try access["after_qid"].decode(Int64.self, context: .default)

    // Optional bitmap fields: NULL is the valid before-state sentinel; try?
    // is correct here because PostgreSQL enforces BIGINT at the wire level —
    // a non-NULL value will parse cleanly or the wire decode above will fail.
    let beforeAdj: Int64? = try? access["before_adj"].decode(Int64.self, context: .default)
    let beforeOp: Int64? = try? access["before_op"].decode(Int64.self, context: .default)
    let beforeProv: Int64? = try? access["before_prov"].decode(Int64.self, context: .default)
    let beforeBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)?
    if let ba = beforeAdj, let bo = beforeOp, let bp = beforeProv {
        beforeBitmaps = (ba, bo, bp)
    } else {
        beforeBitmaps = nil
    }
    let beforeUdc: Int64? = try? access["before_udc"].decode(Int64.self, context: .default)
    let beforeQid: Int64? = try? access["before_qid"].decode(Int64.self, context: .default)
    let beforeAnchor: LatticeAnchor?
    if let u = beforeUdc, let q = beforeQid {
        beforeAnchor = LatticeAnchor(udcCode: UInt64(bitPattern: u), qidPointer: UInt64(bitPattern: q))
    } else {
        beforeAnchor = nil
    }
    // reason is nullable TEXT; nil when the event was recorded without a caller-supplied reason.
    let reason: String? = try? access["reason"].decode(String.self, context: .default)

    let packed = UInt64(bitPattern: hlcPacked)
    let physical = Int64(packed >> 16)
    let logical = Int32(truncatingIfNeeded: (packed >> 4) & 0xFFF)
    let node = Int32(truncatingIfNeeded: packed & 0xF)
    let hlc = HLC(physicalTime: physical, logicalCount: logical, nodeID: node)

    return AuditEvent(
        eventID: eventID,
        estateUuid: estateUuid,
        rowId: rowId,
        hlc: hlc,
        verb: verb,
        beforeBitmaps: beforeBitmaps,
        afterBitmaps: (afterAdj, afterOp, afterProv),
        beforeLatticeAnchor: beforeAnchor,
        afterLatticeAnchor: LatticeAnchor(udcCode: UInt64(bitPattern: afterUdc), qidPointer: UInt64(bitPattern: afterQid)),
        actor: actor,
        reason: reason
    )
}
