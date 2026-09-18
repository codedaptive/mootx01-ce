// PostgreSQLStorage.swift
//
// PostgreSQL backend per the PersistenceKit storage surface.

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

    public func renameSchemaKit(from oldKitID: String, to newKitID: String) async throws -> SchemaKitRenameOutcome {
        try await backend.renameSchemaKit(from: oldKitID, to: newKitID)
    }

    public func migrate(to schema: SchemaDeclaration) async throws {
        try await backend.applyMigrations(schema)
    }

    public func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        let result = try await backend.transaction(isolation: isolation, block: block)
        // Cache invalidation (#53): the transaction wrote through a raw
        // backend RowStore, bypassing the public CachingRowStore. Evict
        // all present-read entries so the next read hits the backing store.
        if let caching = rowStore as? CachingRowStore {
            await caching.invalidateAllPresent()
        }
        return result
    }

    public func captureInventorySnapshot(limits: InventorySnapshotLimits) async throws -> InventorySnapshot {
        try await backend.captureInventorySnapshot(limits: limits)
    }
}

// MARK: - DatasetStore surface (MX-TAB-2)

extension PostgreSQLStorage {
    /// Returns a `PostgreSQLDatasetStore` backed by this storage's `backend`.
    ///
    /// Overrides the default `featureGated` throw from the `Storage` protocol
    /// extension — PostgreSQL has a conformance. The store is lightweight (no
    /// connection acquired here; connections are checked out per operation from
    /// the shared pool). Creating the store is therefore synchronous and cheap.
    public var datasetStore: any DatasetStore {
        get throws {
            PostgreSQLDatasetStore(backend: backend)
        }
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
    // Snapshot-test observation seam. It changes only after PostgreSQL has
    // yielded a full row to the strict decoder.
    private(set) var inventorySnapshotFullRowMaterializations: Int = 0
    /// Cached DatasetSchema per dataset table name (MX-TAB-2).
    ///
    /// Keyed by `datasetTableName(id)` (e.g. `ds_<hex>`). Populated by
    /// `createDatasetTable` and consumed by `queryDatasetRows` and
    /// `datasetColumnStats` to decode row values with the correct column types.
    /// Actor isolation serializes reads and writes without additional locking.
    var datasetSchemas: [String: DatasetSchema] = [:]
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

    /// Move the per-kit version key `schema_version:<oldKitID>` to
    /// `schema_version:<newKitID>` (SPEC I-7a). The presence checks and the
    /// UPDATE run in one transaction on one connection, so the conflict check
    /// and the rewrite are atomic. The global `schema_version` key is a
    /// maximum across kits and does not change.
    func renameSchemaKit(from oldKitID: String, to newKitID: String) async throws -> SchemaKitRenameOutcome {
        let conn = try await pool.acquire()
        defer { Task { await pool.release(conn) } }
        try await conn.executeSimple("BEGIN", logger: logger)
        do {
            let outcome: SchemaKitRenameOutcome
            if let oldVersion = try await ledgerVersion(kitID: oldKitID, connection: conn) {
                if let newVersion = try await ledgerVersion(kitID: newKitID, connection: conn) {
                    outcome = .conflict(oldVersion: oldVersion, newVersion: newVersion)
                } else {
                    _ = try await conn.executeParameterized(
                        "UPDATE \"_storagekit_meta\" SET \"key\" = $1 WHERE \"key\" = $2",
                        bindings: [.text("schema_version:\(newKitID)"), .text("schema_version:\(oldKitID)")],
                        logger: logger
                    )
                    outcome = .renamed(version: oldVersion)
                }
            } else {
                outcome = .noRow
            }
            try await conn.executeSimple("COMMIT", logger: logger)
            return outcome
        } catch {
            try? await conn.executeSimple("ROLLBACK", logger: logger)
            throw error
        }
    }

    /// The per-kit version for `kitID`, or nil when no `schema_version:<kitID>`
    /// key exists. Distinct from `readSchemaVersion(kitID:connection:)`, which
    /// folds "no key" into 0; the rename must tell the two apart.
    private func ledgerVersion(kitID: String, connection: PostgresConnection) async throws -> Int? {
        let rows = try await connection.executeParameterized(
            "SELECT \"value\" FROM \"_storagekit_meta\" WHERE \"key\" = $1",
            bindings: [.text("schema_version:\(kitID)")],
            logger: logger
        )
        for try await row in rows {
            let access = row.makeRandomAccess()
            if let s: String = try? access["value"].decode(String.self, context: .default), let v = Int(s) {
                return v
            }
        }
        return nil
    }

    // MARK: - Introspection

    /// Query PostgreSQL statistics views for backend health.
    ///
    /// SQL rationale per query:
    ///
    /// `pg_database_size`: returns the total on-disk size of the current
    /// database in bytes. Includes all tables, indexes, and TOAST.
    /// Does NOT include WAL (WAL lives in pg_wal/, outside the database directory).
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

    /// Uses one checked-out connection and a REPEATABLE READ transaction so
    /// drawers and nodes share one PostgreSQL visibility snapshot.
    func captureInventorySnapshot(limits: InventorySnapshotLimits) async throws -> InventorySnapshot {
        let connection = try await pool.acquire()
        do {
            try await connection.executeSimple(
                "BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ",
                logger: logger
            )
            var serializedBytes = 0
            let drawers = try await boundedInventoryRows(
                table: InventorySnapshot.drawersTable,
                limits: limits,
                serializedBytes: &serializedBytes,
                connection: connection
            )
            let nodes = try await boundedInventoryRows(
                table: InventorySnapshot.nodesTable,
                limits: limits,
                serializedBytes: &serializedBytes,
                connection: connection
            )
            try await connection.executeSimple("COMMIT", logger: logger)
            await pool.release(connection)
            return InventorySnapshot(drawers: drawers, nodes: nodes)
        } catch {
            try? await connection.executeSimple("ROLLBACK", logger: logger)
            await pool.release(connection)
            throw error
        }
    }

    private func boundedInventoryRows(
        table: String,
        limits: InventorySnapshotLimits,
        serializedBytes: inout Int,
        connection: PostgresConnection
    ) async throws -> [StorageRow] {
        try validatePSQLIdentifier(table)
        let columns = columns(for: table)
        guard !columns.isEmpty else {
            throw StorageError.invalidQuery(detail: "inventory snapshot: schema for \(table) not registered")
        }
        for column in columns { try validatePSQLIdentifier(column.name) }
        try await preflightInventoryRows(
            table: table,
            columns: columns,
            limits: limits,
            serializedBytes: serializedBytes,
            connection: connection
        )
        let select = columns.map { "\"\($0.name)\"" }.joined(separator: ", ")
        let rows = try await connection.executeParameterized(
            "SELECT \(select) FROM \"\(table)\" LIMIT \(limits.maxRowsPerTable + 1)",
            bindings: [],
            logger: logger
        )

        var captured: [StorageRow] = []
        for try await postgresRow in rows {
            guard captured.count < limits.maxRowsPerTable else {
                throw InventorySnapshotError.rowLimitExceeded(
                    table: table,
                    limit: limits.maxRowsPerTable
                )
            }
            inventorySnapshotFullRowMaterializations += 1
            let decoded = try decryptedForRead(
                try strictSnapshotRow(postgresRow, columns: columns),
                table: table,
                config: encryptionConfig
            )
            let row = StorageRow(values: decoded)
            let rowBytes = InventorySnapshot.serializedByteCount(of: row)
            guard rowBytes <= limits.maxSerializedBytes - serializedBytes else {
                throw InventorySnapshotError.byteLimitExceeded(limit: limits.maxSerializedBytes)
            }
            serializedBytes += rowBytes
            captured.append(row)
        }
        return captured
    }

    private func preflightInventoryRows(
        table: String,
        columns: [ColumnDeclaration],
        limits: InventorySnapshotLimits,
        serializedBytes: Int,
        connection: PostgresConnection
    ) async throws {
        let countRows = try await connection.executeParameterized(
            "SELECT COUNT(*) AS \"inventory_count\" FROM \"\(table)\"",
            bindings: [], logger: logger
        )
        var count: Int64 = 0
        for try await countRow in countRows {
            count = try countRow.makeRandomAccess()["inventory_count"].decode(Int64.self, context: .default)
            break
        }
        guard count <= Int64(limits.maxRowsPerTable) else {
            throw InventorySnapshotError.rowLimitExceeded(table: table, limit: limits.maxRowsPerTable)
        }

        let expressions = columns.map { column -> String in
            let keyBytes = column.name.utf8.count + 1
            let quoted = "\"\(column.name)\""
            let exactValueBytes: String
            switch column.type {
            case .text:
                let bytes = "OCTET_LENGTH(\(quoted)::text)::numeric"
                exactValueBytes = "(3::numeric + LENGTH(\(bytes)::text)::numeric + \(bytes))"
            case .blob:
                let bytes = "OCTET_LENGTH(\(quoted))::numeric"
                exactValueBytes = "(3::numeric + LENGTH(\(bytes)::text)::numeric + 2::numeric * \(bytes))"
            case .json:
                // JSONB::text is PostgreSQL's valid UTF-8 decoded payload.
                let bytes = "OCTET_LENGTH(\(quoted)::text)::numeric"
                exactValueBytes = "(3::numeric + LENGTH(\(bytes)::text)::numeric + \(bytes))"
            case .uuid:
                exactValueBytes = "38::numeric"
            case .float:
                exactValueBytes = "18::numeric"
            case .bool:
                exactValueBytes = "3::numeric"
            case .int, .bitmap:
                exactValueBytes = "(2::numeric + LENGTH(\(quoted)::text)::numeric)"
            case .hlc:
                let unsigned = "CASE WHEN \(quoted) < 0 THEN 18446744073709551616::numeric + \(quoted)::numeric ELSE \(quoted)::numeric END"
                exactValueBytes = "(2::numeric + LENGTH((\(unsigned))::text)::numeric)"
            case .timestamp:
                let milliseconds = "ROUND(EXTRACT(EPOCH FROM \(quoted)) * 1000)::bigint"
                exactValueBytes = "(2::numeric + LENGTH(\(milliseconds)::text)::numeric)"
            case .fingerprint:
                let bytes = "OCTET_LENGTH(\(quoted))::numeric"
                // Valid fingerprints are fixed 32-byte values and encode to
                // 66 canonical bytes. A malformed BYTEA remains subject to
                // strict decode, but its raw body must first be bounded so a
                // corrupt oversized value cannot reach the row materializer.
                exactValueBytes = "CASE WHEN \(bytes) = 32::numeric THEN 66::numeric ELSE (3::numeric + LENGTH(\(bytes)::text)::numeric + 2::numeric * \(bytes)) END"
            }
            return "CASE WHEN \(quoted) IS NULL THEN \(keyBytes + 1)::numeric ELSE \(keyBytes)::numeric + \(exactValueBytes) END"
        }
        guard !expressions.isEmpty else { return }
        let separators = max(columns.count - 1, 0)
        let remainingBytes = limits.maxSerializedBytes - serializedBytes
        let rows = try await connection.executeParameterized(
            "SELECT COALESCE(SUM((\(expressions.joined(separator: " + ")) + \(separators)::numeric)), 0::numeric) > \(remainingBytes)::numeric AS \"inventory_exceeds_bytes\" FROM \"\(table)\"",
            bindings: [], logger: logger
        )
        var exceedsByteLimit = false
        for try await row in rows {
            exceedsByteLimit = try row.makeRandomAccess()["inventory_exceeds_bytes"].decode(Bool.self, context: .default)
            break
        }
        guard !exceedsByteLimit else {
            throw InventorySnapshotError.byteLimitExceeded(limit: limits.maxSerializedBytes)
        }
    }

    /// Snapshot decoding is intentionally stricter than ordinary v1 reads:
    /// SQL NULL remains `.null`, but a present value that cannot decode as its
    /// declared type fails the complete inventory capture.
    private func strictSnapshotRow(_ row: PostgresRow, columns: [ColumnDeclaration]) throws -> [String: TypedValue] {
        let access = row.makeRandomAccess()
        var values: [String: TypedValue] = [:]
        for column in columns {
            values[column.name] = try strictSnapshotValue(access[column.name], column: column)
        }
        return values
    }

    private func strictSnapshotValue(
        _ cell: PostgresRandomAccessRow.Element,
        column: ColumnDeclaration
    ) throws -> TypedValue {
        func mismatch(_ error: Error) -> StorageError {
            StorageError.typeMismatch(column: column.name, expected: column.type, actual: String(describing: error))
        }
        do {
            switch column.type {
            case .uuid:
                guard let value: UUID = try cell.decode(UUID?.self, context: .default) else { return .null }
                return .uuid(value)
            case .bitmap:
                guard let value: Int64 = try cell.decode(Int64?.self, context: .default) else { return .null }
                return .bitmap(value)
            case .int:
                guard let value: Int64 = try cell.decode(Int64?.self, context: .default) else { return .null }
                return .int(value)
            case .text:
                guard let value: String = try cell.decode(String?.self, context: .default) else { return .null }
                return .text(value)
            case .timestamp:
                guard let value: Date = try cell.decode(Date?.self, context: .default) else { return .null }
                return .timestamp(value)
            case .float:
                guard let value: Double = try cell.decode(Double?.self, context: .default) else { return .null }
                return .float(value)
            case .bool:
                guard let value: Bool = try cell.decode(Bool?.self, context: .default) else { return .null }
                return .bool(value)
            case .blob:
                guard let value: ByteBuffer = try cell.decode(ByteBuffer?.self, context: .default) else { return .null }
                return .blob(Data(buffer: value))
            case .json:
                guard let value: String = try cell.decode(String?.self, context: .default) else { return .null }
                return .json(Data(value.utf8))
            case .hlc:
                guard let value: Int64 = try cell.decode(Int64?.self, context: .default) else { return .null }
                return .hlc(HLC(packed: UInt64(bitPattern: value)))
            case .fingerprint:
                guard let value: ByteBuffer = try cell.decode(ByteBuffer?.self, context: .default) else { return .null }
                let data = Data(buffer: value)
                guard data.count == 32 else {
                    throw StorageError.typeMismatch(column: column.name, expected: column.type, actual: "BYTEA length \(data.count)")
                }
                return .fingerprint(Self.snapshotFingerprint(data))
            }
        } catch let error as StorageError {
            throw error
        } catch {
            throw mismatch(error)
        }
    }

    private static func snapshotFingerprint(_ data: Data) -> Fingerprint256 {
        func word(_ offset: Int) -> UInt64 {
            data[offset..<(offset + 8)].withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        }
        return Fingerprint256(block0: word(0), block1: word(8), block2: word(16), block3: word(24))
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

// MARK: - StorageMaintenance (shared-content 1.1 P5)

extension PostgreSQLStorage: StorageMaintenance {
    /// PostgreSQL page reclamation is server-managed (autovacuum); the
    /// client cannot meaningfully estimate reclaimable bytes without
    /// superuser-level pgstattuple access, so the estimate is 0.
    public func estimatedReclaimableBytes() async throws -> Int64 { 0 }

    /// Explicit no-op (per the StorageMaintenance backend table): dead-tuple
    /// reclamation and WAL recycling are the server's responsibility
    /// (autovacuum / checkpointer). Client-driven VACUUM FULL takes an
    /// ACCESS EXCLUSIVE lock and is an operator decision, not a substrate
    /// maintenance primitive.
    public func performMaintenance(
        progress: (@Sendable (StorageMaintenanceProgress) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) async throws -> StorageMaintenanceReport {
        .noOp(backend: "postgresql",
              note: "physical reclamation is server-managed (autovacuum); no client-side maintenance is performed")
    }
}
