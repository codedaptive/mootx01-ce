// PostgreSQLStorage.swift
//
// PostgreSQL backend per DECISION_STORAGEKIT_DESIGN.

import Foundation
import SubstrateTypes
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
@preconcurrency import PostgresNIO
import Logging

public final class PostgreSQLStorage: Storage, Sendable {
    public let configuration: EstateConfiguration
    let pool: PostgreSQLPool
    let backend: PostgreSQLBackend
    public let rowStore: any RowStore
    public let blobStore: any BlobStore
    public let auditLog: any AuditLog
    public let observer: any StorageObserver = NoOpObserver()

    public init(configuration: EstateConfiguration) {
        precondition({
            if case .postgresql = configuration.backend { return true }
            return false
        }(), "PostgreSQLStorage requires .postgresql backend configuration")
        self.configuration = configuration

        guard case let .postgresql(cs, ps, ct, it) = configuration.backend else {
            fatalError("unreachable")
        }
        // Estate isolation: each estate lives in its own schema (the PG
        // analogue of SQLite's one-file-per-estate). Every pooled connection
        // pins its search_path to it, so a shared database holds many estates
        // without table collisions. `public` stays on the path so shared
        // extensions resolve.
        let searchPath = "pk_" + configuration.estateID.uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
        let pool = PostgreSQLPool(
            connectionString: cs,
            poolSize: ps,
            connectionTimeout: ct,
            idleTimeout: it,
            searchPath: searchPath
        )
        self.pool = pool
        let backend = PostgreSQLBackend(pool: pool, encryptionConfig: configuration.encryptionConfig)
        self.backend = backend
        let baseRowStore = PostgreSQLRowStore(backend: backend)
        // Wrap in the LRU hot-tier decorator when caching is enabled. The
        // disabled path (the default) is byte-identical to pre-wiring behavior —
        // callers receive an `any RowStore` either way so no call sites change.
        self.rowStore = configuration.cacheConfig.enabled
            ? CachingRowStore(backing: baseRowStore, config: configuration.cacheConfig)
            : baseRowStore
        self.blobStore = PostgreSQLBlobStore(backend: backend)
        self.auditLog = PostgreSQLAuditLog(backend: backend)
    }

    public func open(schema: SchemaDeclaration) async throws {
        try await backend.open(schema: schema)
    }

    public func close() async {
        await pool.close()
    }

    public func currentSchemaVersion() async throws -> Int {
        try await backend.currentSchemaVersion()
    }

    public func currentSchemaVersion(for kitID: String) async throws -> Int {
        try await backend.currentSchemaVersion(for: kitID)
    }

    public func migrate(to schema: SchemaDeclaration) async throws {
        try await backend.applyMigrations(schema)
    }

    public func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        try await backend.transaction(isolation: isolation, block: block)
    }
}

// MARK: - StorageIntrospection

extension PostgreSQLStorage: StorageIntrospection {
    /// Capture a point-in-time snapshot of PostgreSQL backend health.
    ///
    /// Sources each field from the PostgreSQL statistics collector:
    /// - logicalSizeBytes: pg_database_size(current_database()) — bytes
    ///   used by the database on disk.
    /// - cacheHitRatio: blks_hit / (blks_hit + blks_read) from
    ///   pg_stat_database — the fraction of block reads served from
    ///   shared_buffers vs. the OS or disk.
    /// - transactionCommitCount / transactionRollbackCount / deadlockCount:
    ///   xact_commit, xact_rollback, deadlocks from pg_stat_database.
    /// - lockContention: any row in pg_locks with granted=false joined to
    ///   the current database indicates a waiting lock.
    public func stats(now: Date) async throws -> StorageStats {
        try await backend.storageStats(now: now)
    }
}

// MARK: - Backend actor

actor PostgreSQLBackend {
    let pool: PostgreSQLPool
    let logger = Logger(label: "storagekit.postgres.backend")
    var schemaDeclaration: SchemaDeclaration?
    /// At-rest encryption config for this estate. `nonisolated` so the row
    /// stores can read it synchronously when applying the per-row content seam
    /// (it is immutable and `Sendable`). Mode 2 (RowEncryption) is the only
    /// mode the seam acts on; FullDatabase has no PostgreSQL analogue (the
    /// server owns the schema), and plaintext is a no-op.
    nonisolated let encryptionConfig: EstateEncryptionConfig

    init(pool: PostgreSQLPool, encryptionConfig: EstateEncryptionConfig) {
        self.pool = pool
        self.encryptionConfig = encryptionConfig
    }

    func open(schema: SchemaDeclaration) async throws {
        self.schemaDeclaration = schema
        let conn = try await pool.acquire()
        defer { Task { await pool.release(conn) } }

        // Bootstrap meta table.
        try await conn.executeSimple("""
            CREATE TABLE IF NOT EXISTS "_storagekit_meta" (
              "key" TEXT PRIMARY KEY,
              "value" TEXT NOT NULL
            )
            """, logger: logger)

        // Shared append-only trigger function (idempotent). Created
        // once; every append-only table attaches a trigger to it.
        try await conn.executeSimple(PostgreSQLSchemaEmitter.appendOnlyFunctionSQL, logger: logger)

        // Create the application's tables and indices.
        for table in schema.tables {
            try await conn.executeSimple(PostgreSQLSchemaEmitter.createTableSQL(table), logger: logger)
            for stmt in PostgreSQLSchemaEmitter.appendOnlyTriggerStatements(table) {
                try await conn.executeSimple(stmt, logger: logger)
            }
        }
        for idx in schema.indices {
            try await conn.executeSimple(PostgreSQLSchemaEmitter.createIndexSQL(idx), logger: logger)
        }

        // Apply pending migrations scoped to this kit's version.
        // Both the per-kit key ("schema_version:<kitID>") and the global key
        // ("schema_version") are kept current so the no-arg currentSchemaVersion()
        // returns a meaningful value. The global key holds the maximum version
        // written by any kit that has opened on this storage instance.
        let current = try await readSchemaVersion(kitID: schema.kitID, connection: conn)
        let pending = schema.migrations
            .filter { $0.fromVersion >= current && $0.toVersion <= schema.version }
            .sorted(by: { $0.fromVersion < $1.fromVersion })
        for m in pending {
            try await conn.executeSimple("BEGIN", logger: logger)
            do {
                for op in m.operations {
                    try await applyOperation(op, connection: conn)
                }
                try await writeSchemaVersion(m.toVersion, kitID: schema.kitID, connection: conn)
                // Update global key to the running maximum across all kits.
                let globalCurrent = try await readSchemaVersion(connection: conn)
                if m.toVersion > globalCurrent {
                    try await writeSchemaVersion(m.toVersion, key: "schema_version", connection: conn)
                }
                try await conn.executeSimple("COMMIT", logger: logger)
            } catch {
                try? await conn.executeSimple("ROLLBACK", logger: logger)
                throw StorageError.migrationFailed(version: m.toVersion, reason: "\(error)")
            }
        }
        if pending.isEmpty && current < schema.version {
            try await writeSchemaVersion(schema.version, kitID: schema.kitID, connection: conn)
            let globalCurrent = try await readSchemaVersion(connection: conn)
            if schema.version > globalCurrent {
                try await writeSchemaVersion(schema.version, key: "schema_version", connection: conn)
            }
        }
    }

    func currentSchemaVersion() async throws -> Int {
        let conn = try await pool.acquire()
        defer { Task { await pool.release(conn) } }
        return try await readSchemaVersion(connection: conn)
    }

    /// Per-kit schema version. Postgres stores per-kit versions as rows in
    /// `_storagekit_meta` using the composite key `"schema_version:<kitID>"`.
    /// The global `"schema_version"` key is preserved for the no-arg overload.
    /// This mirrors the SQLite backend which uses a `_storagekit_migrations`
    /// table with a `kit_id` column; Postgres uses the existing meta table to
    /// avoid a new table and a schema change.
    func currentSchemaVersion(for kitID: String) async throws -> Int {
        let conn = try await pool.acquire()
        defer { Task { await pool.release(conn) } }
        return try await readSchemaVersion(kitID: kitID, connection: conn)
    }

    func applyMigrations(_ schema: SchemaDeclaration) async throws {
        try await open(schema: schema)
    }

    // MARK: - Introspection

    /// Query PostgreSQL statistics views for backend health.
    ///
    /// SQL rationale per query:
    ///
    /// `pg_database_size`: returns the total on-disk size of the current
    /// database in bytes. Includes all tables, indexes, TOAST, and WAL.
    ///
    /// `pg_stat_database`: one row per database; `blks_hit` and `blks_read`
    /// are cumulative counters. The cache-hit ratio blks_hit/(blks_hit+blks_read)
    /// measures how often PostgreSQL satisfied reads from shared_buffers vs.
    /// requiring disk I/O. A ratio < 0.99 on a read-heavy workload is a
    /// signal to increase shared_buffers.
    ///
    /// `xact_commit` / `xact_rollback` / `deadlocks`: lifetime counters
    /// since the last statistics reset (pg_stat_reset()). Monotonically
    /// increasing; callers diff successive snapshots for rates.
    ///
    /// Lock contention: `pg_locks` joined to `pg_database` where
    /// `granted = false` AND `database = current database OID`. A non-zero
    /// count means at least one backend is waiting to acquire a lock on a
    /// relation in this database right now.
    func storageStats(now: Date) async throws -> StorageStats {
        let conn = try await pool.acquire()
        defer { Task { await pool.release(conn) } }

        // --- Logical size ---
        var logicalSize: Int64 = 0
        let sizeRows = try await conn.executeParameterized(
            "SELECT pg_database_size(current_database())",
            bindings: [],
            logger: logger
        )
        for try await row in sizeRows {
            let acc = row.makeRandomAccess()
            if let v = try? acc[0].decode(Int64.self, context: .default) {
                logicalSize = v
            }
        }

        // --- Buffer cache hit ratio + transaction and deadlock counters ---
        var cacheHitRatio: Double? = nil
        var commitCount: Int64? = nil
        var rollbackCount: Int64? = nil
        var deadlockCount: Int64? = nil

        let statRows = try await conn.executeParameterized(
            """
            SELECT blks_hit, blks_read, xact_commit, xact_rollback, deadlocks
            FROM pg_stat_database
            WHERE datname = current_database()
            """,
            bindings: [],
            logger: logger
        )
        for try await row in statRows {
            let acc = row.makeRandomAccess()
            let blksHit   = (try? acc["blks_hit"].decode(Int64.self, context: .default)) ?? 0
            let blksRead  = (try? acc["blks_read"].decode(Int64.self, context: .default)) ?? 0
            let total = blksHit + blksRead
            if total > 0 {
                cacheHitRatio = Double(blksHit) / Double(total)
            }
            commitCount   = (try? acc["xact_commit"].decode(Int64.self, context: .default))
            rollbackCount = (try? acc["xact_rollback"].decode(Int64.self, context: .default))
            deadlockCount = (try? acc["deadlocks"].decode(Int64.self, context: .default))
        }

        // --- Lock contention ---
        // A non-zero count means at least one backend is waiting on a lock
        // in the current database right now.
        var lockContention = false
        let lockRows = try await conn.executeParameterized(
            """
            SELECT COUNT(*) AS waiting
            FROM pg_locks l
            JOIN pg_database d ON d.oid = l.database
            WHERE l.granted = false
              AND d.datname = current_database()
            """,
            bindings: [],
            logger: logger
        )
        for try await row in lockRows {
            let acc = row.makeRandomAccess()
            if let v = try? acc["waiting"].decode(Int64.self, context: .default) {
                lockContention = v > 0
            }
        }

        return StorageStats(
            logicalSizeBytes: logicalSize,
            cacheHitRatio: cacheHitRatio,
            transactionCommitCount: commitCount,
            transactionRollbackCount: rollbackCount,
            deadlockCount: deadlockCount,
            lockContention: lockContention,
            capturedAt: now
        )
    }

    /// Read the global (no-arg) schema version from the `schema_version` meta key.
    private func readSchemaVersion(connection: PostgresConnection) async throws -> Int {
        try await readSchemaVersion(key: "schema_version", connection: connection)
    }

    /// Read the per-kit schema version. The key is `schema_version:<kitID>` — a
    /// composite form that avoids a new table while keeping per-kit isolation in
    /// the existing `_storagekit_meta` key-value table.
    private func readSchemaVersion(kitID: String, connection: PostgresConnection) async throws -> Int {
        try await readSchemaVersion(key: "schema_version:\(kitID)", connection: connection)
    }

    private func readSchemaVersion(key: String, connection: PostgresConnection) async throws -> Int {
        let rows = try await connection.executeParameterized(
            "SELECT \"value\" FROM \"_storagekit_meta\" WHERE \"key\" = $1",
            bindings: [.text(key)],
            logger: logger
        )
        for try await row in rows {
            let access = row.makeRandomAccess()
            if let s: String = try? access["value"].decode(String.self, context: .default), let v = Int(s) {
                return v
            }
        }
        return 0
    }

    /// Write the per-kit schema version under key `schema_version:<kitID>`.
    private func writeSchemaVersion(_ v: Int, kitID: String, connection: PostgresConnection) async throws {
        try await writeSchemaVersion(v, key: "schema_version:\(kitID)", connection: connection)
    }

    private func writeSchemaVersion(_ v: Int, key: String, connection: PostgresConnection) async throws {
        _ = try await connection.executeParameterized("""
            INSERT INTO "_storagekit_meta" ("key", "value") VALUES ($1, $2)
            ON CONFLICT ("key") DO UPDATE SET "value" = EXCLUDED."value"
            """, bindings: [.text(key), .text(String(v))], logger: logger)
    }

    private func applyOperation(_ op: SchemaOperation, connection: PostgresConnection) async throws {
        switch op {
        case .createTable(let decl):
            try await connection.executeSimple(PostgreSQLSchemaEmitter.appendOnlyFunctionSQL, logger: logger)
            try await connection.executeSimple(PostgreSQLSchemaEmitter.createTableSQL(decl), logger: logger)
            for stmt in PostgreSQLSchemaEmitter.appendOnlyTriggerStatements(decl) {
                try await connection.executeSimple(stmt, logger: logger)
            }
        case .dropTable(let name):
            try await connection.executeSimple(PostgreSQLSchemaEmitter.dropTableSQL(name), logger: logger)
        case .addColumn(let t, let c):
            try await connection.executeSimple(PostgreSQLSchemaEmitter.addColumnSQL(table: t, column: c), logger: logger)
        case .dropColumn(let t, let name):
            try await connection.executeSimple(PostgreSQLSchemaEmitter.dropColumnSQL(table: t, columnName: name), logger: logger)
        case .renameColumn(let t, let from, let to):
            try await connection.executeSimple(PostgreSQLSchemaEmitter.renameColumnSQL(table: t, from: from, to: to), logger: logger)
        case .addIndex(let idx):
            try await connection.executeSimple(PostgreSQLSchemaEmitter.createIndexSQL(idx), logger: logger)
        case .dropIndex(let name):
            try await connection.executeSimple(PostgreSQLSchemaEmitter.dropIndexSQL(name), logger: logger)
        case .custom(_, let pg):
            if let pg { try await connection.executeSimple(pg, logger: logger) }
        }
    }

    func transaction<T: Sendable>(
        isolation: IsolationLevel,
        block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        let conn = try await pool.acquire()
        let level: String
        switch isolation {
        case .readCommitted: level = "READ COMMITTED"
        case .repeatableRead: level = "REPEATABLE READ"
        case .serializable: level = "SERIALIZABLE"
        }
        try await conn.executeSimple("BEGIN TRANSACTION ISOLATION LEVEL \(level)", logger: logger)
        let txn = PostgreSQLTransaction(connection: conn, backend: self)
        do {
            let result = try await block(txn)
            try await conn.executeSimple("COMMIT", logger: logger)
            await pool.release(conn)
            return result
        } catch {
            try? await conn.executeSimple("ROLLBACK", logger: logger)
            await pool.release(conn)
            throw error
        }
    }

    // Schema column lookup. Generated columns are included so query
    // SELECT lists and row decoding surface them like any other column.
    func columns(for table: String) -> [ColumnDeclaration] {
        guard let t = schemaDeclaration?.tables.first(where: { $0.name == table }) else { return [] }
        return t.columns + t.generatedColumns.map {
            ColumnDeclaration(name: $0.name, type: $0.type, nullable: true)
        }
    }

    func primaryKey(for table: String) -> [String] {
        schemaDeclaration?.tables.first(where: { $0.name == table })?.primaryKey ?? []
    }
}

// MARK: - Transaction

final class PostgreSQLTransaction: StorageTransaction, Sendable {
    let rowStore: any RowStore
    let blobStore: any BlobStore
    let auditLog: any AuditLog

    init(connection: PostgresConnection, backend: PostgreSQLBackend) {
        let ctx = PostgreSQLTransactionContext(connection: connection, backend: backend)
        self.rowStore = PostgreSQLRowStore(backend: backend, txn: ctx)
        self.blobStore = PostgreSQLBlobStore(backend: backend, txn: ctx)
        self.auditLog = PostgreSQLAuditLog(backend: backend, txn: ctx)
    }
}

final class PostgreSQLTransactionContext: Sendable {
    let connection: PostgresConnection
    let backend: PostgreSQLBackend

    init(connection: PostgresConnection, backend: PostgreSQLBackend) {
        self.connection = connection
        self.backend = backend
    }
}
