// SQLiteStorage.swift
//
// SQLite backend. One connection per estate, serialized via actor.

import Foundation
import SQLCipher
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

public final class SQLiteStorage: Storage, Sendable {
    public let configuration: EstateConfiguration

    public let rowStore: any RowStore
    public let blobStore: any BlobStore
    public let auditLog: any AuditLog
    public let observer: any StorageObserver

    /// Dataset store for user-defined tabular data (MX-TAB-1).
    ///
    /// Stored as a `let` here (satisfies the `{ get throws }` protocol
    /// requirement with a non-throwing stored property — valid in Swift because
    /// a non-throwing getter is a sub-type of a throwing one). Initialised with
    /// `backend` so DDL and row operations run on the same actor-serialized
    /// connection as RowStore and BlobStore.
    public let datasetStore: any DatasetStore

    let backend: SQLiteBackend
    let observerRegistry: SQLiteObserverRegistry

    public init(configuration: EstateConfiguration) throws {
        guard case .sqlite(let url, let busyTimeout) = configuration.backend else {
            preconditionFailure("SQLiteStorage requires .sqlite backend configuration")
        }
        self.configuration = configuration
        // FullDatabase (Mode 3): the SQLCipher key (hex) is applied at open via
        // PRAGMA key. nil for plaintext / row-encryption — a normal SQLite file.
        let conn = try SQLiteConnection(
            url: url,
            busyTimeout: busyTimeout,
            keyHex: configuration.encryptionConfig.fullDatabaseKeyHex
        )
        let registry = SQLiteObserverRegistry()
        self.observerRegistry = registry
        let backend = SQLiteBackend(
            connection: conn,
            observerRegistry: registry,
            encryptionConfig: configuration.encryptionConfig
        )
        self.backend = backend
        let baseRowStore = SQLiteRowStore(backend: backend)
        // Wrap in the LRU hot-tier decorator when caching is enabled. The
        // disabled path (the default) is byte-identical to pre-wiring behavior —
        // callers receive an `any RowStore` either way so no call sites change.
        self.rowStore = configuration.cacheConfig.enabled
            ? CachingRowStore(backing: baseRowStore, config: configuration.cacheConfig)
            : baseRowStore
        self.blobStore = SQLiteBlobStore(backend: backend)
        self.auditLog = SQLiteAuditLog(backend: backend)
        self.observer = SQLiteObserver(registry: registry)
        // Dataset store — same backend actor, no additional connection overhead.
        self.datasetStore = SQLiteDatasetStore(backend: backend)
    }

    public func open(schema: SchemaDeclaration) async throws {
        try await backend.openSchema(schema)
    }

    public func close() async {
        await backend.close()
    }

    public func currentSchemaVersion() async throws -> Int {
        try await backend.currentSchemaVersion(kitID: nil)
    }

    public func currentSchemaVersion(for kitID: String) async throws -> Int {
        try await backend.currentSchemaVersion(kitID: kitID)
    }

    public func migrate(to schema: SchemaDeclaration) async throws {
        try await backend.applyMigrations(schema)
    }

    public func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        let result = try await backend.runTransaction(isolation: isolation) { txn in
            try await block(txn)
        }
        // Cache invalidation (#53): the transaction wrote through a raw
        // backend RowStore, bypassing the public CachingRowStore. Evict
        // all present-read entries so the next read hits the backing store.
        if let caching = rowStore as? CachingRowStore {
            await caching.invalidateAllPresent()
        }
        return result
    }
}

// MARK: - StorageIntrospection

extension SQLiteStorage: StorageIntrospection {
    /// Capture a point-in-time snapshot of SQLite backend health.
    ///
    /// Sources each field via read-only PRAGMAs against the live connection.
    /// The backend actor serializes the PRAGMA reads so results are consistent
    /// within a single call (no other operation can interleave on the actor).
    public func stats(now: Date) async throws -> StorageStats {
        try await backend.storageStats(now: now)
    }
}

// MARK: - Backend actor

actor SQLiteBackend {
    let connection: SQLiteConnection
    private var inTransaction: Bool = false
    /// Blob change notifications buffered while a transaction is open.
    ///
    /// putBlob/deleteBlob append here instead of calling notifyBlobChange
    /// directly when `inTransaction == true`. On COMMIT they are flushed to
    /// observers; on ROLLBACK they are discarded. This ensures rolled-back blob
    /// writes never reach incremental replication sessions (SECFIX-WS2-PK F3).
    private var pendingBlobNotifications: [BlobChange] = []
    let observerRegistry: SQLiteObserverRegistry?
    /// All table declarations applied to this storage instance, keyed by table
    /// name so schemas owned by multiple kits can share one estate.
    ///
    /// SQLite stores UUIDs and timestamps with TEXT affinity. The declaration
    /// registry is therefore required at read time to recover their semantic
    /// `TypedValue` cases. A single retained `SchemaDeclaration` is insufficient:
    /// opening the application schema and later migrating ConvergenceKit's side
    /// schema would otherwise leave `_ck_outbox.id` decoded as `.text`.
    private struct RegisteredTableDeclaration {
        let kitID: String
        let table: TableDeclaration
    }
    private var tableDeclarations: [String: RegisteredTableDeclaration] = [:]
    /// At-rest encryption config for this estate (Mission ENC-01).
    /// `.plaintext` makes the crypto seam in insertRow/queryRows a no-op.
    let encryptionConfig: EstateEncryptionConfig

    init(
        connection: SQLiteConnection,
        observerRegistry: SQLiteObserverRegistry? = nil,
        encryptionConfig: EstateEncryptionConfig = .plaintext
    ) {
        self.connection = connection
        self.observerRegistry = observerRegistry
        self.encryptionConfig = encryptionConfig
    }

    private func notifyObservers(_ change: TableChange) {
        if let r = observerRegistry {
            Task { await r.notify(change) }
        }
    }

    /// Emit a blob change to all blob subscribers registered via observeBlobs().
    ///
    /// Called after every successful putBlob/deleteBlob so the incremental
    /// replication session can accumulate dirty blob keys without polling.
    /// Spawns a non-blocking Task to avoid holding the actor while the async
    /// registry notify runs — identical pattern to notifyObservers.
    private func notifyBlobChange(_ change: BlobChange) {
        if let r = observerRegistry {
            Task { await r.notifyBlob(change) }
        }
    }

    // MARK: - SQL identifier validation (SECFIX-WS2-PK F1)

    // Identifier validation is provided by the module-level free function
    // `validateSQLIdentifier` in SQLiteIdentifierValidator.swift. That single
    // seam is shared by SQLiteStorage (row operations, table names, ORDER BY
    // columns) and SQLitePredicateCompiler (predicate column names).
    // No per-type copy of the rule exists (SECFIX-WS2-PK F7/F9/F10).

    func close() {
        connection.close()
    }

    // MARK: - Schema and migrations

    func openSchema(_ schema: SchemaDeclaration) throws {
        try registerTableDeclarations(from: schema)
        // Internal tables first.
        try connection.exec(SQLiteSchema.migrationsTableSQL)
        try connection.exec(SQLiteSchema.auditTableSQL)
        // Upgrade migration (#102): estates created before the reason column
        // was added to the audit DDL need ALTER TABLE. CREATE TABLE IF NOT
        // EXISTS does not add columns to an existing table. SQLite ADD COLUMN
        // on an existing column returns "duplicate column name" — catch and
        // ignore so this is idempotent on both old and new estates.
        do {
            try connection.exec("""
                ALTER TABLE "_storagekit_audit" ADD COLUMN "reason" TEXT
            """)
        } catch {
            // "duplicate column name: reason" on new estates — expected.
        }
        // Upgrade migration (HLC_PACKED_ORDER_UNSOUND): estates created before
        // the full-precision HLC columns joined the audit DDL need ALTER TABLE
        // (same idempotent duplicate-column pattern as `reason` above), then a
        // backfill from the packed value so the chronological ORDER BY —
        // (physical_time, logical_count, node_id) — covers pre-migration rows.
        for column in ["\"physical_time\"", "\"logical_count\"", "\"node_id\""] {
            do {
                try connection.exec("""
                    ALTER TABLE "_storagekit_audit" ADD COLUMN \(column) INTEGER NOT NULL DEFAULT 0
                """)
            } catch {
                // "duplicate column name" on estates that already have it — expected.
            }
        }
        try connection.exec(SQLiteSchema.auditBackfillFullHLCSQL)
        for drop in SQLiteSchema.auditDropPackedIndexesSQL {
            try connection.exec(drop)
        }
        try connection.exec(SQLiteSchema.auditIndexSQL)
        try connection.exec(SQLiteSchema.auditHLCIndexSQL)
        try connection.exec(SQLiteSchema.blobTableSQL)

        // User-declared tables.
        for table in schema.tables {
            try connection.exec(SQLiteSchema.createTable(table))
            for trigger in SQLiteSchema.appendOnlyTriggers(table) {
                try connection.exec(trigger)
            }
        }
        for index in schema.indices {
            try connection.exec(SQLiteSchema.createIndex(index))
        }

        // Apply pending migrations.
        try applyMigrations(schema)
    }

    func applyMigrations(_ schema: SchemaDeclaration) throws {
        // Register every schema package before its tables are queried. Distinct
        // kits accumulate declarations; a later version from the same kit
        // replaces its prior full declaration so newly-added typed columns are
        // decoded correctly.
        try registerTableDeclarations(from: schema)

        // Ensure the migrations bookkeeping table and all user-declared tables
        // exist before running pending migration steps. This matches the Rust
        // apply_schema path (open and migrate both call apply_schema) and
        // InMemoryStorage.applyMigrationsInner (which creates tables as its first
        // step). The guard is necessary because migrate(to:) may be called on a
        // fresh SQLite file without a prior open(schema:) call — for example,
        // Corpus.init calls storage.migrate(to: BundleStore.schemaDeclaration)
        // directly. Without this step the chunks table does not exist and the
        // first allChunks() call fails with "no such table: chunks".
        //
        // CREATE TABLE IF NOT EXISTS and CREATE INDEX IF NOT EXISTS are both
        // idempotent: calling them on an already-initialised storage is a no-op,
        // so the existing callers that invoke migrate(to:) after open(schema:) are
        // unaffected.
        try connection.exec(SQLiteSchema.migrationsTableSQL)
        for table in schema.tables {
            try connection.exec(SQLiteSchema.createTable(table))
            for trigger in SQLiteSchema.appendOnlyTriggers(table) {
                try connection.exec(trigger)
            }
        }
        for index in schema.indices {
            try connection.exec(SQLiteSchema.createIndex(index))
        }

        let current = try currentSchemaVersion(kitID: schema.kitID)
        guard current < schema.version else { return }

        let pending = schema.migrations
            .filter { $0.fromVersion >= current && $0.toVersion <= schema.version }
            .sorted(by: { $0.fromVersion < $1.fromVersion })

        for migration in pending {
            try connection.exec("BEGIN IMMEDIATE")
            do {
                for op in migration.operations {
                    try applyOperation(op)
                }
                try recordSchemaVersion(kitID: schema.kitID, version: migration.toVersion)
                try connection.exec("COMMIT")
            } catch {
                try? connection.exec("ROLLBACK")
                throw StorageError.migrationFailed(
                    version: migration.toVersion,
                    reason: "\(error)"
                )
            }
        }

        // Record the schema version even if no migrations were defined.
        let final = try currentSchemaVersion(kitID: schema.kitID)
        if final < schema.version {
            try recordSchemaVersion(kitID: schema.kitID, version: schema.version)
        }
    }

    /// Add a schema package's tables to the read-time type registry.
    ///
    /// Different kits may intentionally share an identical declaration, but a
    /// differing layout under the same SQLite table name is ambiguous and must
    /// fail before DDL or data access. The same kit may replace its declaration
    /// during a forward schema migration because the incoming declaration is the
    /// authoritative full layout at the target version.
    private func registerTableDeclarations(from schema: SchemaDeclaration) throws {
        for table in schema.tables {
            if let existing = tableDeclarations[table.name] {
                if existing.kitID == schema.kitID {
                    tableDeclarations[table.name] = RegisteredTableDeclaration(
                        kitID: schema.kitID,
                        table: table
                    )
                } else if !tableLayoutsMatch(existing.table, table) {
                    throw StorageError.constraintViolation(
                        detail: "table \(table.name) has conflicting declarations from "
                            + "\(existing.kitID) and \(schema.kitID)"
                    )
                }
            } else {
                tableDeclarations[table.name] = RegisteredTableDeclaration(
                    kitID: schema.kitID,
                    table: table
                )
            }
        }
    }

    /// Compare the complete persisted layout used by SQLite DDL and decoding.
    private func tableLayoutsMatch(_ lhs: TableDeclaration, _ rhs: TableDeclaration) -> Bool {
        guard
            lhs.name == rhs.name,
            lhs.primaryKey == rhs.primaryKey,
            lhs.uniqueConstraints == rhs.uniqueConstraints,
            lhs.generatedColumns == rhs.generatedColumns,
            lhs.appendOnly == rhs.appendOnly,
            lhs.hashable == rhs.hashable,
            lhs.columns.count == rhs.columns.count
        else { return false }

        return zip(lhs.columns, rhs.columns).allSatisfy { left, right in
            left.name == right.name
                && left.type == right.type
                && left.nullable == right.nullable
                && left.defaultValue == right.defaultValue
                && left.role == right.role
        }
    }

    private func applyOperation(_ op: SchemaOperation) throws {
        switch op {
        case .createTable(let decl):
            try connection.exec(SQLiteSchema.createTable(decl))
            for trigger in SQLiteSchema.appendOnlyTriggers(decl) {
                try connection.exec(trigger)
            }
        case .dropTable(let name):
            try connection.exec("DROP TABLE IF EXISTS \"\(name)\"")
        case .addColumn(let table, let column):
            // Idempotent (mirrors CREATE TABLE IF NOT EXISTS): the fresh-DB path
            // creates every table at the latest schema before replaying migrations
            // from version 0, so an addColumn migration may target a column that
            // already exists. SQLite has no ADD COLUMN IF NOT EXISTS, so probe the
            // table's existing columns and skip when the column is already present.
            if try columnExists(table: table, column: column.name) { break }
            var sql = "ALTER TABLE \"\(table)\" ADD COLUMN \"\(column.name)\" \(SQLiteSchema.nativeType(column.type))"
            if !column.nullable { sql += " NOT NULL DEFAULT " + SQLiteSchema.literalSQL(column.defaultValue ?? .null) }
            try connection.exec(sql)
        case .dropColumn(let table, let columnName):
            try connection.exec("ALTER TABLE \"\(table)\" DROP COLUMN \"\(columnName)\"")
        case .renameColumn(let table, let from, let to):
            try connection.exec("ALTER TABLE \"\(table)\" RENAME COLUMN \"\(from)\" TO \"\(to)\"")
        case .addIndex(let decl):
            try connection.exec(SQLiteSchema.createIndex(decl))
        case .dropIndex(let name):
            try connection.exec("DROP INDEX IF EXISTS \"\(name)\"")
        case .custom(let sqliteSQL, _):
            if let sql = sqliteSQL { try connection.exec(sql) }
        }
    }

    /// True when `table` already has a column named `column`.
    /// Used to make `.addColumn` idempotent (SQLite lacks ADD COLUMN IF NOT
    /// EXISTS). PRAGMA table_info returns one row per column; column index 1 is
    /// the column name.
    private func columnExists(table: String, column: String) throws -> Bool {
        let stmt = try connection.prepare("PRAGMA table_info(\"\(table)\")")
        defer { stmt.finalize() }
        while try stmt.step() {
            if stmt.columnText(1) == column { return true }
        }
        return false
    }

    func currentSchemaVersion(kitID: String?) throws -> Int {
        let stmt: SQLiteStatement
        if let kitID {
            stmt = try connection.prepare("SELECT \"version\" FROM \"_storagekit_migrations\" WHERE \"kit_id\" = ?")
            try stmt.bind(.text(kitID), at: 1)
        } else {
            stmt = try connection.prepare("SELECT MAX(\"version\") FROM \"_storagekit_migrations\"")
        }
        defer { stmt.finalize() }
        if try stmt.step() {
            return Int(stmt.columnInt64(0))
        }
        return 0
    }

    private func recordSchemaVersion(kitID: String, version: Int) throws {
        let stmt = try connection.prepare("""
            INSERT INTO "_storagekit_migrations" ("kit_id", "version", "applied_at")
            VALUES (?, ?, ?)
            ON CONFLICT("kit_id") DO UPDATE SET "version" = excluded.version, "applied_at" = excluded.applied_at
            """)
        defer { stmt.finalize() }
        try stmt.bind(.text(kitID), at: 1)
        try stmt.bind(.int(Int64(version)), at: 2)
        try stmt.bind(.text(ISO8601.string(from: Date())), at: 3)
        _ = try stmt.step()
    }

    // MARK: - Transaction

    func runTransaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: (any StorageTransaction) async throws -> T
    ) async throws -> T {
        // Concurrent transactions WAIT for the open one to finish rather than
        // failing. The actor suspends inside `block` (it is async), so a second
        // caller can interleave at that suspension and land here with
        // `inTransaction == true` — that is ordinary contention between
        // background workers (reindex's Merkle rollup vs. a dream cycle vs. a
        // live capture), not a programming error, and throwing surfaced as
        // "reindex: background backfill failed: transactionConflict" on a busy
        // daemon. The wait is bounded so a TRUE nested transaction (a block
        // reentering runTransaction on its own backend, which would deadlock)
        // still fails loudly instead of hanging. beginTransactionDirect keeps
        // its immediate throw: it is synchronous and cannot await.
        var waitedNanos: UInt64 = 0
        let waitLimitNanos: UInt64 = 60_000_000_000  // 60 s
        while inTransaction {
            if waitedNanos >= waitLimitNanos {
                throw StorageError.transactionConflict(
                    detail: "transaction still open after 60 s wait — nested transactions not supported")
            }
            try await Task.sleep(nanoseconds: 25_000_000)  // 25 ms, then re-check
            waitedNanos += 25_000_000
        }
        let begin: String
        switch isolation {
        case .readCommitted, .repeatableRead, .serializable:
            begin = "BEGIN IMMEDIATE"  // WAL mode treats all of these as effectively serializable
        }
        try connection.exec(begin)
        inTransaction = true
        let txn = SQLiteTransaction(backend: self)
        do {
            let result = try await block(txn)
            try connection.exec("COMMIT")
            inTransaction = false
            // Flush blob notifications now that the transaction has committed to disk.
            // These were buffered during the transaction so a ROLLBACK would discard
            // them (SECFIX-WS2-PK F3): rolled-back blob writes must not reach
            // replication sessions.
            let pending = pendingBlobNotifications
            pendingBlobNotifications.removeAll()
            for change in pending { notifyBlobChange(change) }
            return result
        } catch {
            try? connection.exec("ROLLBACK")
            inTransaction = false
            // Discard blob notifications for the rolled-back transaction.
            pendingBlobNotifications.removeAll()
            throw error
        }
    }

    // MARK: - Explicit transaction boundary (GLK_BATCH1)

    /// Open a serializable write transaction on the underlying SQLite connection.
    ///
    /// Uses `BEGIN IMMEDIATE` so that the write lock is acquired upfront,
    /// preventing "cannot start a transaction within a transaction" failures
    /// under WAL mode. Callers must pair every `beginTransactionDirect` with
    /// exactly one `commitTransactionDirect` or `rollbackTransactionDirect`.
    func beginTransactionDirect() throws {
        if inTransaction {
            throw StorageError.transactionConflict(detail: "nested transactions not supported")
        }
        try connection.exec("BEGIN IMMEDIATE")
        inTransaction = true
    }

    /// Commit the transaction opened by `beginTransactionDirect`.
    ///
    /// Flushes any blob change notifications buffered during the transaction
    /// to observers now that the writes are durably committed (SECFIX-WS2-PK F3).
    func commitTransactionDirect() throws {
        try connection.exec("COMMIT")
        inTransaction = false
        let pending = pendingBlobNotifications
        pendingBlobNotifications.removeAll()
        for change in pending { notifyBlobChange(change) }
    }

    /// Roll back the transaction opened by `beginTransactionDirect`,
    /// discarding all changes since `BEGIN IMMEDIATE`.
    ///
    /// Discards buffered blob notifications — the rolled-back writes must not
    /// reach replication sessions (SECFIX-WS2-PK F3).
    func rollbackTransactionDirect() throws {
        try? connection.exec("ROLLBACK")
        inTransaction = false
        pendingBlobNotifications.removeAll()
    }

    // MARK: - Row operations

    func insertRow(table: String, values: [String: TypedValue], origin: ChangeOrigin = .local) throws -> RowHandle {
        // SQL-identifier injection guard (CAND-047 / SECFIX-WS2-PK F9): validate
        // the table name before it is interpolated into the INSERT statement, and
        // validate all column names from the caller-supplied `values` map before
        // they reach the INSERT column list. A name containing `"` or `;` can
        // escape double-quote delimiters and alter the query. The shared module-level
        // `validateSQLIdentifier` (SQLiteIdentifierValidator.swift) rejects any
        // name outside `[A-Za-z_][A-Za-z0-9_]*` — one seam, no forked validator.
        try validateSQLIdentifier(table)
        for name in values.keys { try validateSQLIdentifier(name) }
        // At-rest encryption seam (mode 2/3): encrypt the content column
        // and stamp the key identifier before binding. No-op for mode 1.
        let values = try encryptedForWrite(values, table: table, config: encryptionConfig)
        // Structural content/keyID invariant (FUP-D): after the seam, a
        // content row on an encrypting estate must carry a keyID. A correct
        // encrypting insert has already become .blob + keyID here, so the
        // guard is a no-op for it; it fires only if the seam could not run.
        try assertContentKeyIDInvariant(values, table: table, config: encryptionConfig)
        let sortedKeys = values.keys.sorted()
        let cols = sortedKeys.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: sortedKeys.count).joined(separator: ", ")
        let sql = "INSERT INTO \"\(table)\" (\(cols)) VALUES (\(placeholders))"
        // prepareCached: SQL for a given (table, shape) is identical across a
        // bulk loop — parse once, replay from the connection's statement cache
        // (best-practices §5; the per-row re-parse was a measured 50k-import
        // hot spot). finalize() on a cached statement resets it for reuse.
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        for (i, key) in sortedKeys.enumerated() {
            try stmt.bind(values[key]!, at: Int32(i + 1))
        }
        do {
            _ = try stmt.step()
        } catch {
            if connection.lastErrorMessage.contains("UNIQUE") {
                throw StorageError.duplicateKey(table: table, key: "(unique constraint)")
            }
            throw error
        }
        let key = extractRowKey(table: table, values: values)
        // changedColumns for insert = all columns in the written row.
        notifyObservers(TableChange(
            table: table, event: .insert, rowKey: key, values: values, origin: origin,
            changedColumns: Set(values.keys)
        ))
        return RowHandle(table: table, key: key)
    }

    // The at-rest encryption seam (ENC-01) runs on every write verb —
    // insertRow, upsertRow and updateRows — so no verb can place plaintext in
    // a protected column on an encrypting estate. upsertRow was the last one
    // wired: the earlier design assumed upsert only ever reached non-content
    // tables (manifest, container_fingerprints, node_bundles), but snapshot
    // replication upserts drawer rows it has just read back as plaintext, so
    // upsert is a content write path in practice. Sealing here rather than in
    // the replication layer keeps the destination's key inside the store that
    // owns it.
    func upsertRow(table: String, values: [String: TypedValue], conflictColumns: [String], origin: ChangeOrigin = .local) throws -> RowHandle {
        // SQL-identifier injection guard (CAND-047 / SECFIX-WS2-PK F9): validate
        // the table name, all value-map column names, and the conflict-column list
        // before interpolating into the INSERT … ON CONFLICT … DO UPDATE SQL.
        // Mirrors the Rust backend guard and the Postgres backend guard — shared
        // seam via module-level `validateSQLIdentifier`, no forked validator.
        try validateSQLIdentifier(table)
        for name in values.keys { try validateSQLIdentifier(name) }
        for name in conflictColumns { try validateSQLIdentifier(name) }
        // At-rest encryption seam (mode 2/3): seal this table's protected
        // columns and stamp the key identifier before binding, matching
        // insertRow and updateRows. No-op for mode 1 and for tables with no
        // protected columns. Sealing cannot disturb the ON CONFLICT match:
        // the only protected table is "drawers" and its conflict column is
        // the primary key "id", which is never protected.
        let values = try encryptedForWrite(values, table: table, config: encryptionConfig)
        // Structural safety net beneath the seam: after sealing, protected
        // text can only remain if the seam could not run.
        try assertContentKeyIDInvariant(values, table: table, config: encryptionConfig)
        let sortedKeys = values.keys.sorted()
        let cols = sortedKeys.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: sortedKeys.count).joined(separator: ", ")
        let conflictCols = conflictColumns.map { "\"\($0)\"" }.joined(separator: ", ")
        let updateCols = sortedKeys
            .filter { !conflictColumns.contains($0) }
            .map { "\"\($0)\" = excluded.\"\($0)\"" }
            .joined(separator: ", ")
        var sql = "INSERT INTO \"\(table)\" (\(cols)) VALUES (\(placeholders))"
        if !conflictColumns.isEmpty {
            sql += " ON CONFLICT(\(conflictCols))"
            sql += updateCols.isEmpty ? " DO NOTHING" : " DO UPDATE SET \(updateCols)"
        }
        // prepareCached: SQL for a given (table, shape) is identical across a
        // bulk loop — parse once, replay from the connection's statement cache
        // (best-practices §5; the per-row re-parse was a measured 50k-import
        // hot spot). finalize() on a cached statement resets it for reuse.
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        for (i, key) in sortedKeys.enumerated() {
            try stmt.bind(values[key]!, at: Int32(i + 1))
        }
        // Pre-read existing row before the upsert for changedColumns diff (CVK-WB4).
        // One O(1) SELECT on the conflict-column index before the INSERT ON CONFLICT.
        // The SQLite actor serializes writes so there is no interleaving between
        // this read and the upsert below. If the row exists, compute the column diff;
        // if not, treat as insert (all columns are new).
        //
        // On an encrypting estate this diff OVER-REPORTS protected columns, by
        // design. fetchRowByConflictColumns is a raw SELECT that does not run
        // decryptedForRead, so it returns stored ciphertext, and the seam above
        // re-seals under a fresh AES-GCM nonce every call. Identical plaintext
        // therefore compares unequal and the column is reported changed. That
        // is conservative in the safe direction: changedColumns drives
        // ConvergenceKit's field-level LWW column stamping, where an extra
        // stamp is redundant work and a missing one would lose an update.
        // Decrypting the pre-read to compare plaintext would add a decrypt per
        // row on the replication hot path to save that redundancy — not worth
        // it. This is a known trade, not an oversight.
        let existingRowForDiff = try? fetchRowByConflictColumns(
            table: table, values: values, conflictColumns: conflictColumns)
        _ = try stmt.step()
        let key = extractRowKey(table: table, values: values)
        let changedCols: Set<String>
        if let existing = existingRowForDiff {
            // Upsert-as-update: stamp only columns that differ from the stored row.
            changedCols = Set(values.keys.filter { existing[$0] != values[$0] })
        } else {
            // Upsert-as-insert: all written columns are "new".
            changedCols = Set(values.keys)
        }
        notifyObservers(TableChange(
            table: table, event: .update, rowKey: key, values: values, origin: origin,
            changedColumns: changedCols
        ))
        return RowHandle(table: table, key: key)
    }

    func updateRows(table: String, values: [String: TypedValue], where predicate: StoragePredicate) throws -> Int {
        // SQL-identifier injection guard (CAND-047 / SECFIX-WS2-PK F9): validate
        // the table name and all column names from the caller-supplied `values`
        // map before they reach the UPDATE SET clause. Mirrors the Rust backend
        // guard and the Postgres backend guard — shared seam via module-level
        // `validateSQLIdentifier`, no forked validator.
        try validateSQLIdentifier(table)
        for name in values.keys { try validateSQLIdentifier(name) }
        // At-rest encryption seam (mode 2): UPDATE is a protected-text write
        // path since the distilled-representation columns landed (a
        // distillation write is an UPDATE carrying "distilled" text, and a
        // subjecting write one carrying "subject" —
        // SPEC_DISTILLATION_STORAGE §2/§7.2). The seam seals any non-empty
        // text in a column protected for this table and stamps keyID; it is a
        // no-op for the bitmap/timestamp updates that were this path's only
        // traffic before, and for the expunge scrub (empty text is exempt so
        // erasure stays a plaintext-empty marker).
        let values = try encryptedForWrite(values, table: table, config: encryptionConfig)
        // Structural content/keyID invariant (FUP-D): after the seam, a
        // protected-text update on an encrypting estate must carry a keyID.
        try assertContentKeyIDInvariant(values, table: table, config: encryptionConfig)
        // Pre-read full rows before mutating (CVK-WB4 changedColumns diff).
        // `fetchMatchingRowValues` does a SELECT * so we have the pre-update
        // column values to diff against the incoming SET values. The SQLiteBackend
        // actor serializes all writes, so no interleaving is possible between
        // this SELECT and the UPDATE below. Cost: one extra round-trip for the
        // full-row pre-read per `updateRows` call; acceptable because updateRows
        // is low-frequency and the precision enables fieldLevelLWW column stamping
        // and mixed-column storm-kill (Scorandum Q1) in ConvergenceKit.
        let oldRows = (try? fetchMatchingRowValues(table: table, predicate: predicate)) ?? [:]
        let sortedKeys = values.keys.sorted()
        let setClause = sortedKeys.map { "\"\($0)\" = ?" }.joined(separator: ", ")
        let compiled = try SQLitePredicateCompiler.compile(predicate)
        let sql = "UPDATE \"\(table)\" SET \(setClause) WHERE \(compiled.sql)"
        // prepareCached: SQL for a given (table, shape) is identical across a
        // bulk loop — parse once, replay from the connection's statement cache
        // (best-practices §5; the per-row re-parse was a measured 50k-import
        // hot spot). finalize() on a cached statement resets it for reuse.
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        var idx: Int32 = 1
        for key in sortedKeys {
            try stmt.bind(values[key]!, at: idx); idx += 1
        }
        for v in compiled.bindings {
            try stmt.bind(v, at: idx); idx += 1
        }
        _ = try stmt.step()
        let changes = Int(sqlite3_changes(connection.handle))
        for key in oldRows.keys {
            let oldRow = oldRows[key]
            let changedCols: Set<String> = Set(values.keys.filter { oldRow?[$0] != values[$0] })
            notifyObservers(TableChange(
                table: table, event: .update, rowKey: key, values: nil,
                changedColumns: changedCols
            ))
        }
        return changes
    }

    func deleteRows(table: String, where predicate: StoragePredicate, origin: ChangeOrigin = .local) throws -> Int {
        // SQL-identifier injection guard (SECFIX-WS2-PK F9): validate the table
        // name before interpolation. Predicate column names are validated by
        // SQLitePredicateCompiler.compile (SECFIX-WS2-PK F7).
        try validateSQLIdentifier(table)
        // Pre-query row keys before deletion so notifications carry them.
        // The SQLiteBackend actor serializes all operations, so no interleaving
        // is possible between this SELECT and the DELETE.
        let matchedKeys = try fetchMatchingRowKeys(table: table, predicate: predicate)
        let compiled = try SQLitePredicateCompiler.compile(predicate)
        let sql = "DELETE FROM \"\(table)\" WHERE \(compiled.sql)"
        // prepareCached: SQL for a given (table, shape) is identical across a
        // bulk loop — parse once, replay from the connection's statement cache
        // (best-practices §5; the per-row re-parse was a measured 50k-import
        // hot spot). finalize() on a cached statement resets it for reuse.
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        for (i, v) in compiled.bindings.enumerated() {
            try stmt.bind(v, at: Int32(i + 1))
        }
        _ = try stmt.step()
        let changes = Int(sqlite3_changes(connection.handle))
        for key in matchedKeys {
            // changedColumns for delete = nil. Column-level information is not
            // meaningful on a tombstone; consumers use the rowKey only.
            notifyObservers(TableChange(
                table: table, event: .delete, rowKey: key, values: nil, origin: origin,
                changedColumns: nil
            ))
        }
        return changes
    }

    func queryRows(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        tableSchema: TableDeclaration?,
        columns: [String]?
    ) throws -> [StorageRow] {
        // SQL-identifier injection guard (SECFIX-WS2-PK F9): validate the table
        // name before it is interpolated into the SELECT statement. Mirrors the
        // guard already applied in insertRow/upsertRow/updateRows/deleteRows.
        try validateSQLIdentifier(table)
        // Resolve declared types from the retained schema so typed
        // columns decode to their proper TypedValue case. An explicit
        // tableSchema argument overrides the retained lookup.
        let resolvedSchema = tableSchema ?? tableDeclarations[table]?.table
        // Column projection (no-blob read): a non-nil `columns` list emits an
        // explicit SELECT of exactly those columns, so an unnamed column (e.g.
        // "content") is never read out of SQLite. A nil projection is the
        // historical full `SELECT *`. Identifiers are validated and quoted; an
        // empty list degrades to `*` rather than producing invalid SQL.
        //
        // Validation gate (SECFIX-WS2-PK F1): caller-supplied column names are
        // embedded into the SQL SELECT list. Double-quoting is not sufficient
        // protection if a name contains `"` — the quote can escape the
        // double-quote delimiter and alter the query. Reject any name that is
        // not a safe SQL identifier: [A-Za-z_][A-Za-z0-9_]*.
        //
        // Key-identifier augmentation: `decryptedForRead` cannot open a
        // sealed value without the row's keyID, and a caller's projection
        // has no reason to know that. When the projection reads a protected
        // column on an encrypting estate but omits keyID, SELECT it anyway
        // and strip it from the row below — the caller's projection contract
        // is unchanged, and the seam gets what it needs. Without this a
        // projected read returns ciphertext bytes silently, because .blob is
        // a legal TypedValue that a decoder reads as an absent string.
        let injectedKeyID = rowCryptoProjectionNeedsKeyID(
            table: table, columns: columns, config: encryptionConfig)
        let projection: String
        if let columns, !columns.isEmpty {
            for name in columns {
                try validateSQLIdentifier(name)
            }
            let selected = injectedKeyID ? columns + [rowCryptoKeyIDColumn] : columns
            projection = selected.map { "\"\($0)\"" }.joined(separator: ", ")
        } else {
            projection = "*"
        }
        var sql = "SELECT \(projection) FROM \"\(table)\""
        var bindings: [TypedValue] = []
        if let predicate {
            // compile is now `throws` — predicate column names are validated
            // inside the compiler (SECFIX-WS2-PK F7).
            let compiled = try SQLitePredicateCompiler.compile(predicate)
            sql += " WHERE \(compiled.sql)"
            bindings = compiled.bindings
        }
        if !orderBy.isEmpty {
            // SQL-identifier injection guard (SECFIX-WS2-PK F7): validate every
            // ORDER BY column name before it is interpolated into the SQL string.
            // Mirrors the column-name guard applied in the predicate compiler.
            let parts = try orderBy.map { clause -> String in
                try validateSQLIdentifier(clause.column.name)
                let dir = clause.direction == .ascending ? "ASC" : "DESC"
                return "\"\(clause.column.name)\" \(dir)"
            }
            sql += " ORDER BY " + parts.joined(separator: ", ")
        }
        if let limit { sql += " LIMIT \(limit)" }
        if let offset, offset > 0 { sql += " OFFSET \(offset)" }

        // prepareCached: SQL for a given (table, shape) is identical across a
        // bulk loop — parse once, replay from the connection's statement cache
        // (best-practices §5; the per-row re-parse was a measured 50k-import
        // hot spot). finalize() on a cached statement resets it for reuse.
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        for (i, v) in bindings.enumerated() {
            try stmt.bind(v, at: Int32(i + 1))
        }

        var rows: [StorageRow] = []
        let colCount = stmt.columnCount()
        while try stmt.step() {
            var values: [String: TypedValue] = [:]
            for i in 0..<colCount {
                let name = stmt.columnName(i)
                // readColumn throws StorageError.corruptStoredValue when a
                // TEXT value for a .uuid or .timestamp column cannot be parsed.
                // The error propagates out of queryRows so the caller knows the
                // row is unreadable rather than receiving a silently wrong value.
                values[name] = try readColumn(stmt: stmt, index: i, schema: resolvedSchema, columnName: name, table: table)
            }
            // At-rest decryption seam (mode 2/3): decrypt this table's
            // protected columns when the row carries a key identifier.
            // No-op for mode 1 and for tables with no protected columns.
            var decoded = try decryptedForRead(values, table: table, config: encryptionConfig)
            // Drop the keyID this query added on the caller's behalf, so a
            // projected read returns exactly the columns that were asked for.
            if injectedKeyID { decoded[rowCryptoKeyIDColumn] = nil }
            rows.append(StorageRow(values: decoded))
        }
        return rows
    }

    /// SQLite-cursor-level skip-corrupt scan.
    ///
    /// Iterates the result set row by row; when `readColumn` returns a
    /// `.corruptStoredValue` error (e.g. a `+58432-...` poison timestamp that
    /// `ISO8601DateFormatter` cannot parse back), the row is logged via OSLog
    /// and skipped. Any other error (engine failure, locking) is re-thrown.
    ///
    /// Point lookups use strict `queryRows` — a corrupt value in a point-lookup
    /// row is an unambiguous data-integrity failure and the caller must know.
    /// Corpus scans (all drawers, wing scans) use this method so one bad row
    /// does not brick the entire estate.
    func queryRowsSkipCorrupt(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) throws -> (rows: [StorageRow], skipped: Int) {
        // SQL-identifier injection guard (SECFIX-WS2-PK F9): validate the table
        // name before it is interpolated. Mirrors queryRows and all write paths.
        try validateSQLIdentifier(table)
        let resolvedSchema = tableDeclarations[table]?.table
        // SQL-identifier injection guard (SECFIX-WS2-PK F10): validate the
        // projected column names here, just as queryRows does for its projection
        // path. queryRowsSkipCorrupt shares the same SELECT construction, so the
        // same injection surface exists. Reject before SQL is built.
        //
        // Key-identifier augmentation: `decryptedForRead` cannot open a
        // sealed value without the row's keyID, and a caller's projection
        // has no reason to know that. When the projection reads a protected
        // column on an encrypting estate but omits keyID, SELECT it anyway
        // and strip it from the row below — the caller's projection contract
        // is unchanged, and the seam gets what it needs. Without this a
        // projected read returns ciphertext bytes silently, because .blob is
        // a legal TypedValue that a decoder reads as an absent string.
        let injectedKeyID = rowCryptoProjectionNeedsKeyID(
            table: table, columns: columns, config: encryptionConfig)
        let projection: String
        if let columns, !columns.isEmpty {
            for name in columns {
                try validateSQLIdentifier(name)
            }
            let selected = injectedKeyID ? columns + [rowCryptoKeyIDColumn] : columns
            projection = selected.map { "\"\($0)\"" }.joined(separator: ", ")
        } else {
            projection = "*"
        }
        var sql = "SELECT \(projection) FROM \"\(table)\""
        var bindings: [TypedValue] = []
        if let predicate {
            // compile is now `throws` — predicate column names are validated
            // inside the compiler (SECFIX-WS2-PK F7).
            let compiled = try SQLitePredicateCompiler.compile(predicate)
            sql += " WHERE \(compiled.sql)"
            bindings = compiled.bindings
        }
        if !orderBy.isEmpty {
            // SQL-identifier injection guard (SECFIX-WS2-PK F7): validate ORDER
            // BY column names before interpolation. Mirrors queryRows.
            let parts = try orderBy.map { clause -> String in
                try validateSQLIdentifier(clause.column.name)
                let dir = clause.direction == .ascending ? "ASC" : "DESC"
                return "\"\(clause.column.name)\" \(dir)"
            }
            sql += " ORDER BY " + parts.joined(separator: ", ")
        }
        if let limit { sql += " LIMIT \(limit)" }
        if let offset, offset > 0 { sql += " OFFSET \(offset)" }

        // prepareCached: SQL for a given (table, shape) is identical across a
        // bulk loop — parse once, replay from the connection's statement cache
        // (best-practices §5; the per-row re-parse was a measured 50k-import
        // hot spot). finalize() on a cached statement resets it for reuse.
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        for (i, v) in bindings.enumerated() {
            try stmt.bind(v, at: Int32(i + 1))
        }

        var rows: [StorageRow] = []
        let colCount = stmt.columnCount()
        var skipped = 0

        while try stmt.step() {
            var values: [String: TypedValue] = [:]
            var rowIsCorrupt = false
            for i in 0..<colCount {
                let name = stmt.columnName(i)
                do {
                    values[name] = try readColumn(
                        stmt: stmt, index: i,
                        schema: resolvedSchema, columnName: name, table: table)
                } catch StorageError.corruptStoredValue(let t, let c, let s) {
                    // Log and mark row as corrupt; break out of the column loop
                    // and continue to the next row.
                    sqliteConnectionLog.warning(
                        "[queryRowsSkipCorrupt] Skipping corrupt row in table '\(t, privacy: .public)' (column='\(c, privacy: .public)' storedText='\(s, privacy: .public)'). Row skipped until repaired."
                    )
                    skipped += 1
                    rowIsCorrupt = true
                    break
                } catch {
                    throw error // systemic failure — re-throw
                }
            }
            if rowIsCorrupt { continue }
            // At-rest decryption seam: decrypt this table's protected columns
            // when the row carries a key identifier. No-op for Plaintext mode
            // and for tables with no protected columns.
            var decoded = try decryptedForRead(values, table: table, config: encryptionConfig)
            // Drop the keyID this query added on the caller's behalf, so a
            // projected read returns exactly the columns that were asked for.
            if injectedKeyID { decoded[rowCryptoKeyIDColumn] = nil }
            rows.append(StorageRow(values: decoded))
        }
        return (rows, skipped)
    }

    // At-rest per-row encryption seam (Mission ENC-01): the write/read seam
    // (`encryptedForWrite` / `decryptedForRead` / `assertContentKeyIDInvariant`)
    // lives in PersistenceKit core (RowCrypto.swift) so the SQLite and
    // PostgreSQL backends share one byte-compatible implementation. The call
    // sites above (insertRow / upsertRow / updateRows / queryRows /
    // queryRowsSkipCorrupt) invoke it with this backend's `encryptionConfig`
    // and the table they are operating on — the seam selects protected
    // columns per table, so the table name is a required argument, not a
    // label for the error message.

    // MARK: - Introspection

    /// Read DB-layer health statistics via read-only SQLite PRAGMAs plus
    /// WAL-file stat inspection.
    ///
    /// PRAGMA choices and rationale:
    ///
    /// - `page_size`: The database page size in bytes. Set at creation time;
    ///   constant for the lifetime of the file. Required to compute logical size
    ///   and to derive WAL frame count from the WAL file size.
    ///
    /// - `page_count`: Total number of pages in the database file (including
    ///   the freelist). Multiply by page_size for the raw on-disk size.
    ///
    /// - `freelist_count`: Number of unused (freelist) pages. A high ratio
    ///   vs. page_count suggests the database should be VACUUMed to reclaim
    ///   file space.
    ///
    /// WAL frame count via file size: `PRAGMA wal_checkpoint` acquires an
    /// exclusive CHECKPOINTER lock and can return SQLITE_LOCKED if a concurrent
    /// read or write is in progress on the same connection — even from inside
    /// the actor. The safe alternative is to read the WAL file size directly
    /// from the filesystem and derive the frame count.
    ///
    /// WAL frame size = page_size + 24 bytes (header per frame):
    ///   - 24 bytes per-frame header (salt, checksum, page number, DB size).
    /// The WAL file header is 32 bytes (excluded from frame calculation).
    /// formula: frameCount = (walFileSize - 32) / (pageSize + 24)  iff walFileSize > 32.
    ///
    /// Lock contention: `PRAGMA schema_version` is a read-only meta-query
    /// that touches no user data. If it fails with "locked", a process outside
    /// this actor holds an exclusive lock on the database file. The actor
    /// serializes all in-process access so contention is always external.
    func storageStats(now: Date) throws -> StorageStats {
        // page_size: constant for the DB file; returned as a single INTEGER row.
        let pageSizeStmt = try connection.prepare("PRAGMA page_size")
        defer { pageSizeStmt.finalize() }
        let pageSize = try pageSizeStmt.step() ? Int(pageSizeStmt.columnInt64(0)) : 0

        // page_count: total allocated pages (includes freelist pages).
        let pageCountStmt = try connection.prepare("PRAGMA page_count")
        defer { pageCountStmt.finalize() }
        let pageCount = try pageCountStmt.step() ? Int(pageCountStmt.columnInt64(0)) : 0

        // freelist_count: pages on the freelist (not yet reclaimed by VACUUM).
        let freelistStmt = try connection.prepare("PRAGMA freelist_count")
        defer { freelistStmt.finalize() }
        let freelistCount = try freelistStmt.step() ? Int(freelistStmt.columnInt64(0)) : 0

        // Logical size = page_count * page_size.
        let logicalSize = Int64(pageCount) * Int64(pageSize)

        // WAL frame count: derived from the WAL file size to avoid calling
        // PRAGMA wal_checkpoint, which acquires a checkpointer lock and can
        // fail SQLITE_LOCKED even from within the actor.
        // WAL file = url.path + "-wal". Frame count = (fileSize - 32) / (pageSize + 24)
        // when fileSize > 32 (i.e. the WAL file exists and has at least one frame).
        // Returns 0 when the WAL file does not exist or is empty (no uncommitted frames).
        let walFrameCount: Int? = {
            guard pageSize > 0 else { return nil }
            let walPath = connection.url.path + "-wal"
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: walPath),
                  let fileSize = attrs[.size] as? Int,
                  fileSize > 32 else {
                return 0
            }
            // WAL header = 32 bytes; each frame = pageSize + 24 bytes.
            return (fileSize - 32) / (pageSize + 24)
        }()

        // Lock contention: a read-only PRAGMA that touches no user data.
        // SQLITE_LOCKED means a cross-process exclusive lock; the actor
        // serializes all same-process access.
        var lockContention = false
        do {
            let probeStmt = try connection.prepare("PRAGMA schema_version")
            defer { probeStmt.finalize() }
            _ = try probeStmt.step()
        } catch let err as StorageError {
            if case .backendError(let msg) = err, msg.contains("locked") {
                lockContention = true
            }
        }

        return StorageStats(
            logicalSizeBytes: logicalSize,
            pageSize: pageSize > 0 ? pageSize : nil,
            pageCount: pageCount > 0 ? pageCount : nil,
            freelistPageCount: freelistCount,
            walFrameCount: walFrameCount,
            lockContention: lockContention,
            capturedAt: now
        )
    }

    func countRows(table: String, where predicate: StoragePredicate?) throws -> Int {
        // SQL-identifier injection guard (SECFIX-WS2-PK F9): validate the table
        // name before it is interpolated into the COUNT query.
        try validateSQLIdentifier(table)
        var sql = "SELECT COUNT(*) FROM \"\(table)\""
        var bindings: [TypedValue] = []
        if let predicate {
            // compile is now `throws` — predicate column names are validated
            // inside the compiler (SECFIX-WS2-PK F7).
            let compiled = try SQLitePredicateCompiler.compile(predicate)
            sql += " WHERE \(compiled.sql)"
            bindings = compiled.bindings
        }
        // prepareCached: SQL for a given (table, shape) is identical across a
        // bulk loop — parse once, replay from the connection's statement cache
        // (best-practices §5; the per-row re-parse was a measured 50k-import
        // hot spot). finalize() on a cached statement resets it for reuse.
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        for (i, v) in bindings.enumerated() {
            try stmt.bind(v, at: Int32(i + 1))
        }
        guard try stmt.step() else { return 0 }
        return Int(stmt.columnInt64(0))
    }

    /// Derive the outbound `RowKey` for a just-written row from its column
    /// values, using the schema-declared primary key for `table` — the same
    /// resolution `fetchMatchingRowKeys`/`fetchMatchingRowValues` already use
    /// (`tableDeclarations[table]?.table.primaryKey.first ?? "row_id"`). Before this
    /// fix the lookup was hardcoded to a literal `"row_id"` column and fell
    /// back to a freshly-minted random `UUID()` for any table whose PK is
    /// named something else (e.g. `"id"`). That random fallback silently
    /// forked row identity on the outbound sync path: the row inserted with
    /// key K was announced to observers/replication under a random key K',
    /// so the send-side identity never matched the row actually persisted.
    /// The `pkCol = tableDeclarations[table]?.table.primaryKey.first ?? "row_id"`
    /// resolution above is UNCHANGED by gap 5: it still applies to the
    /// `.uuid` fast path and the UUID-parseable-`.text` case regardless of
    /// composite-PK shape, exactly as before.
    ///
    /// Gap 5 adds exactly one new branch: a `.text` PK value that does NOT
    /// parse as a UUID string, on a genuinely SINGLE-COLUMN PK (composite/
    /// multi-column PKs are out of scope — Kong's guard — and fall through
    /// to the random-mint default, unchanged). `RowKeyDerivation.
    /// deterministicRowKey(from:)` derives a stable UUID from SHA-256 of the
    /// string, closing the gap where a genuinely non-UUID-shaped `.text` PK
    /// value (LocusKit's documented, not-yet-exercised deterministic-id
    /// capability) still forked row identity between federation spokes even
    /// on this SQLite backend. See RowKeyDerivation.swift for the full
    /// rationale.
    private func extractRowKey(table: String, values: [String: TypedValue]) -> RowKey {
        let pkColumns = tableDeclarations[table]?.table.primaryKey ?? []
        let pkCol = pkColumns.first ?? "row_id"
        if let v = values[pkCol] {
            if case .uuid(let u) = v { return u }
            if case .text(let s) = v {
                if let u = UUID(uuidString: s) { return u }
                if pkColumns.count == 1 {
                    return RowKeyDerivation.deterministicRowKey(from: s)
                }
            }
        }
        return UUID()
    }

    /// Collect the row keys for rows currently matching `predicate`.
    /// Called before a mutating operation (update or delete) so that
    /// observer notifications can carry the actual key for each affected
    /// row. The `values` dict passed to updateRows contains only the SET
    /// columns, not the primary key, making this pre-query necessary.
    /// The primary-key column name is read from the retained schema; "row_id"
    /// is the fallback for tables whose schema has no single-UUID PK.
    private func fetchMatchingRowKeys(table: String, predicate: StoragePredicate) throws -> [RowKey] {
        let pkCol = tableDeclarations[table]?.table.primaryKey.first ?? "row_id"
        // compile is now `throws` — predicate column names are validated inside
        // the compiler (SECFIX-WS2-PK F7).
        let compiled = try SQLitePredicateCompiler.compile(predicate)
        let sql = "SELECT \"\(pkCol)\" FROM \"\(table)\" WHERE \(compiled.sql)"
        // prepareCached: SQL for a given (table, shape) is identical across a
        // bulk loop — parse once, replay from the connection's statement cache
        // (best-practices §5; the per-row re-parse was a measured 50k-import
        // hot spot). finalize() on a cached statement resets it for reuse.
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        for (i, v) in compiled.bindings.enumerated() {
            try stmt.bind(v, at: Int32(i + 1))
        }
        var keys: [RowKey] = []
        while try stmt.step() {
            // UUIDs are stored as uppercase TEXT (the value codec invariant).
            let s = stmt.columnText(0) ?? ""
            if let uuid = UUID(uuidString: s) {
                keys.append(uuid)
            }
        }
        return keys
    }

    /// Fetch the full column values for every row matching `predicate`.
    ///
    /// Returns a dict of `RowKey → [String: TypedValue]`. The key is the
    /// primary-key UUID column (same resolution as `fetchMatchingRowKeys`).
    ///
    /// Used by `updateRows` to compute `changedColumns` (the diff between the
    /// pre-update row and the SET values — CVK-WB4). Cost: one `SELECT *`
    /// before the `UPDATE`. Acceptable because `updateRows` is already O(n) on
    /// the matched rows, and the pre-read avoids a conservative "stamp all SET
    /// columns" that would defeat fieldLevelLWW precision. The pre-read is on
    /// the hot actor so there is no interleaving between SELECT and UPDATE.
    private func fetchMatchingRowValues(
        table: String,
        predicate: StoragePredicate
    ) throws -> [RowKey: [String: TypedValue]] {
        let schema = tableDeclarations[table]?.table
        let compiled = try SQLitePredicateCompiler.compile(predicate)
        let sql = "SELECT * FROM \"\(table)\" WHERE \(compiled.sql)"
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        for (i, v) in compiled.bindings.enumerated() {
            try stmt.bind(v, at: Int32(i + 1))
        }
        let pkCol = schema?.primaryKey.first ?? "row_id"
        let colCount = stmt.columnCount()
        var result: [RowKey: [String: TypedValue]] = [:]
        while try stmt.step() {
            var row: [String: TypedValue] = [:]
            var rowKey: RowKey? = nil
            for i in 0..<colCount {
                let name = stmt.columnName(i)
                let val = try readColumn(stmt: stmt, index: i, schema: schema, columnName: name, table: table)
                row[name] = val
                if name == pkCol, case .uuid(let u) = val { rowKey = u }
            }
            if let k = rowKey { result[k] = row }
        }
        return result
    }

    /// Fetch a single existing row matching all `conflictColumns` from `values`.
    ///
    /// Used by `upsertRow` to compute `changedColumns` (diff between the pre-
    /// upsert row and the incoming values — CVK-WB4). Cost: one SELECT on a
    /// unique/conflict-column index before the INSERT ON CONFLICT. The SQLite
    /// actor serializes writes so there is no interleaving between this read
    /// and the subsequent upsert. When `conflictColumns` is empty or no
    /// matching values are available, returns `nil` (treat upsert as insert).
    private func fetchRowByConflictColumns(
        table: String,
        values: [String: TypedValue],
        conflictColumns: [String]
    ) throws -> [String: TypedValue]? {
        guard !conflictColumns.isEmpty else { return nil }
        let schema = tableDeclarations[table]?.table
        // Build WHERE clause from conflict columns that have a value in `values`.
        let pairs = conflictColumns.compactMap { col -> (String, TypedValue)? in
            guard let v = values[col] else { return nil }
            return (col, v)
        }
        guard !pairs.isEmpty else { return nil }
        let whereSQL = pairs.map { "\"\($0.0)\" = ?" }.joined(separator: " AND ")
        let sql = "SELECT * FROM \"\(table)\" WHERE \(whereSQL) LIMIT 1"
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        for (i, pair) in pairs.enumerated() {
            try stmt.bind(pair.1, at: Int32(i + 1))
        }
        guard try stmt.step() else { return nil }
        var row: [String: TypedValue] = [:]
        let colCount = stmt.columnCount()
        for i in 0..<colCount {
            let name = stmt.columnName(i)
            row[name] = try readColumn(stmt: stmt, index: i, schema: schema, columnName: name, table: table)
        }
        return row
    }

    /// Read one column from the current statement row into a TypedValue.
    ///
    /// **Type-tolerant vs. parse-failure distinction:**
    /// - Type-tolerant decode (valid value in the wrong column affinity) stays:
    ///   e.g. an INTEGER stored for a .uuid column is passed through as
    ///   `.text` so the caller sees the raw value rather than an opaque error.
    ///   This handles legitimate SQLite affinity coercions for VALID data.
    /// - Parse-failure on a VALID TEXT column becomes a thrown
    ///   `.corruptStoredValue` error: if the stored string cannot be parsed as
    ///   the declared type (UUID or ISO-8601 timestamp), the data is corrupt
    ///   and we must not silently substitute a random UUID or epoch-0 date.
    private func readColumn(
        stmt: SQLiteStatement,
        index: Int32,
        schema: TableDeclaration?,
        columnName: String,
        table: String
    ) throws -> TypedValue {
        let sqliteType = stmt.columnType(index)
        if sqliteType == SQLITE_NULL { return .null }

        // Use schema hint to disambiguate INTEGER columns.
        // Resolve the declared type from regular columns first,
        // then generated columns, so a generated .bitmap/.bool
        // column reads back with its declared TypedValue case.
        let kitType = schema?.columns.first(where: { $0.name == columnName })?.type
            ?? schema?.generatedColumns.first(where: { $0.name == columnName })?.type

        switch sqliteType {
        case SQLITE_INTEGER:
            let i = stmt.columnInt64(index)
            switch kitType {
            case .bitmap: return .bitmap(i)
            case .bool: return .bool(i != 0)
            case .hlc: return .hlc(unpackHLC(UInt64(bitPattern: i)))
            default: return .int(i)
            }
        case SQLITE_FLOAT:
            return .float(stmt.columnDouble(index))
        case SQLITE_TEXT:
            let s = stmt.columnText(index) ?? ""
            switch kitType {
            case .uuid:
                // A stored UUID string that cannot be parsed is corrupt data —
                // substituting UUID() would create a silent data identity lie.
                // Throw so the caller knows the row is unreadable.
                guard let uuid = UUID(uuidString: s) else {
                    throw StorageError.corruptStoredValue(
                        table: table,
                        column: columnName,
                        storedText: s
                    )
                }
                return .uuid(uuid)
            case .timestamp:
                // A stored timestamp string that cannot be parsed is corrupt data —
                // substituting epoch-0 would silently mis-date every downstream
                // consumer. Throw so the caller knows the row is unreadable.
                guard let date = ISO8601.date(from: s) else {
                    throw StorageError.corruptStoredValue(
                        table: table,
                        column: columnName,
                        storedText: s
                    )
                }
                return .timestamp(date)
            default: return .text(s)
            }
        case SQLITE_BLOB:
            let d = stmt.columnBlob(index) ?? Data()
            switch kitType {
            case .fingerprint where d.count == 32: return .fingerprint(unpackFingerprint(d))
            case .json: return .json(d)
            default: return .blob(d)
            }
        default:
            return .null
        }
    }

    private func unpackHLC(_ packed: UInt64) -> HLC {
        // Canonical inverse of HLC.packed. Layout: node<<56 | logical<<40 | physical.
        // HLC.packed stores the three fields in that order; HLC(packed:) recovers
        // them exactly, giving bit-identical round-trips through SQLite INTEGER.
        return HLC(packed: packed)
    }

    private func unpackFingerprint(_ d: Data) -> Fingerprint256 {
        precondition(d.count == 32)
        var blocks: [UInt64] = []
        for i in 0..<4 {
            var be: UInt64 = 0
            d.withUnsafeBytes { buf in
                let p = buf.baseAddress!.advanced(by: i * 8).assumingMemoryBound(to: UInt64.self)
                be = p.pointee
            }
            blocks.append(UInt64(bigEndian: be))
        }
        return Fingerprint256(block0: blocks[0], block1: blocks[1], block2: blocks[2], block3: blocks[3])
    }

    // MARK: - Blob operations

    func putBlob(_ key: BlobKey, bytes: Data) throws {
        let stmt = try connection.prepare("""
            INSERT INTO "_storagekit_blobs" ("key", "bytes") VALUES (?, ?)
            ON CONFLICT("key") DO UPDATE SET "bytes" = excluded.bytes
            """)
        defer { stmt.finalize() }
        try stmt.bind(.text(key), at: 1)
        try stmt.bind(.blob(bytes), at: 2)
        _ = try stmt.step()
        // Buffer the notification when inside a transaction (SECFIX-WS2-PK F3).
        // The SQLite row is written but not yet committed; emitting now would let
        // replication sessions see a row that may be rolled back. The notification
        // is flushed on COMMIT or discarded on ROLLBACK.
        let change = BlobChange(key: key, event: .put, bytes: bytes)
        if inTransaction {
            pendingBlobNotifications.append(change)
        } else {
            notifyBlobChange(change)
        }
    }

    func getBlob(_ key: BlobKey) throws -> Data? {
        let stmt = try connection.prepare("SELECT \"bytes\" FROM \"_storagekit_blobs\" WHERE \"key\" = ?")
        defer { stmt.finalize() }
        try stmt.bind(.text(key), at: 1)
        guard try stmt.step() else { return nil }
        return stmt.columnBlob(0)
    }

    func deleteBlob(_ key: BlobKey) throws {
        let stmt = try connection.prepare("DELETE FROM \"_storagekit_blobs\" WHERE \"key\" = ?")
        defer { stmt.finalize() }
        try stmt.bind(.text(key), at: 1)
        _ = try stmt.step()
        // Buffer the notification when inside a transaction (SECFIX-WS2-PK F3).
        // Mirrors the put path: flush on COMMIT, discard on ROLLBACK.
        let change = BlobChange(key: key, event: .delete, bytes: nil)
        if inTransaction {
            pendingBlobNotifications.append(change)
        } else {
            notifyBlobChange(change)
        }
    }

    func blobExists(_ key: BlobKey) throws -> Bool {
        let stmt = try connection.prepare("SELECT 1 FROM \"_storagekit_blobs\" WHERE \"key\" = ?")
        defer { stmt.finalize() }
        try stmt.bind(.text(key), at: 1)
        return try stmt.step()
    }

    func blobSize(_ key: BlobKey) throws -> Int? {
        let stmt = try connection.prepare("SELECT length(\"bytes\") FROM \"_storagekit_blobs\" WHERE \"key\" = ?")
        defer { stmt.finalize() }
        try stmt.bind(.text(key), at: 1)
        guard try stmt.step() else { return nil }
        return Int(stmt.columnInt64(0))
    }

    func listBlobKeys() throws -> [BlobKey] {
        let stmt = try connection.prepare("SELECT \"key\" FROM \"_storagekit_blobs\"")
        defer { stmt.finalize() }
        var keys: [BlobKey] = []
        while try stmt.step() {
            if let key = stmt.columnText(0) {
                keys.append(key)
            }
        }
        return keys
    }

    // MARK: - Audit operations

    func appendAuditEvent(_ event: AuditEvent) throws {
        let stmt = try connection.prepare("""
            INSERT INTO "_storagekit_audit"
              ("event_id", "hlc", "estate_uuid", "row_id", "verb",
               "before_adj", "before_op", "before_pv",
               "after_adj", "after_op", "after_pv",
               "before_udc", "before_qid", "after_udc", "after_qid",
               "actor", "reason",
               "physical_time", "logical_count", "node_id")
            VALUES (?, ?, ?, ?, ?,
                    ?, ?, ?,
                    ?, ?, ?,
                    ?, ?, ?, ?,
                    ?, ?,
                    ?, ?, ?)
            ON CONFLICT("event_id", "hlc") DO NOTHING
            """)
        defer { stmt.finalize() }
        try stmt.bind(.text(event.eventID.uuidString), at: 1)
        try stmt.bind(.int(Int64(bitPattern: event.hlc.packed)), at: 2)
        try stmt.bind(.text(event.estateUuid.uuidString), at: 3)
        try stmt.bind(.text(event.rowId.uuidString), at: 4)
        try stmt.bind(.text(event.verb), at: 5)
        if let bb = event.beforeBitmaps {
            try stmt.bind(.int(bb.adjective), at: 6)
            try stmt.bind(.int(bb.operational), at: 7)
            try stmt.bind(.int(bb.provenance), at: 8)
        } else {
            try stmt.bind(.null, at: 6)
            try stmt.bind(.null, at: 7)
            try stmt.bind(.null, at: 8)
        }
        try stmt.bind(.int(event.afterBitmaps.adjective), at: 9)
        try stmt.bind(.int(event.afterBitmaps.operational), at: 10)
        try stmt.bind(.int(event.afterBitmaps.provenance), at: 11)
        if let bla = event.beforeLatticeAnchor {
            try stmt.bind(.int(Int64(bitPattern: bla.udcCode)), at: 12)
            try stmt.bind(.int(Int64(bitPattern: bla.qidPointer)), at: 13)
        } else {
            try stmt.bind(.null, at: 12)
            try stmt.bind(.null, at: 13)
        }
        try stmt.bind(.int(Int64(bitPattern: event.afterLatticeAnchor.udcCode)), at: 14)
        try stmt.bind(.int(Int64(bitPattern: event.afterLatticeAnchor.qidPointer)), at: 15)
        try stmt.bind(.text(event.actor), at: 16)
        // reason is nullable TEXT; NULL when the caller supplied no reason.
        if let reason = event.reason {
            try stmt.bind(.text(reason), at: 17)
        } else {
            try stmt.bind(.null, at: 17)
        }
        // Full-precision HLC columns. The packed `hlc` column (bound at 2) stays
        // the ordering key and PK component, but it truncates physicalTime to 40
        // bits (HLC.packed masks & 0xFF_FFFF_FFFF) — lossy for any post-2004 ms.
        // These three columns store the HLC losslessly, mirroring the Rust port,
        // so decodeAuditRow reconstructs the exact HLC instead of the truncated
        // packed form (which silently dropped bit 40 on incremental hydration).
        try stmt.bind(.int(event.hlc.physicalTime), at: 18)
        try stmt.bind(.int(Int64(event.hlc.logicalCount)), at: 19)
        try stmt.bind(.int(Int64(event.hlc.nodeID)), at: 20)
        _ = try stmt.step()
    }

    func appendAuditBatch(_ events: [AuditEvent]) throws {
        for event in events {
            try appendAuditEvent(event)
        }
    }

    func iterateAudit(after: HLC?, rowID: UUID?, limit: Int) throws -> [AuditEvent] {
        var sql = "SELECT * FROM \"_storagekit_audit\""
        var conditions: [String] = []
        var bindings: [TypedValue] = []
        if let after {
            // Cursor and ORDER BY key on the full-precision HLC columns, NOT
            // the packed `hlc` column: HLC order is (physicalTime, logical,
            // node) but the packed integer's field order is (node, logical,
            // physical), so packed-integer comparison mis-orders any
            // same-millisecond burst (logical > 0) against a later write
            // (HLC_PACKED_ORDER_UNSOUND finding). The packed column stays as
            // the PK dedup component only. Row-value comparison keeps the
            // cursor exclusive across ties.
            conditions.append(
                "(\"physical_time\", \"logical_count\", \"node_id\") > (?, ?, ?)")
            bindings.append(.int(after.physicalTime))
            bindings.append(.int(Int64(after.logicalCount)))
            bindings.append(.int(Int64(after.nodeID)))
        }
        if let rowID {
            conditions.append("\"row_id\" = ?")
            bindings.append(.text(rowID.uuidString))
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY \"physical_time\" ASC, \"logical_count\" ASC, \"node_id\" ASC LIMIT \(limit)"

        // prepareCached: SQL for a given (table, shape) is identical across a
        // bulk loop — parse once, replay from the connection's statement cache
        // (best-practices §5; the per-row re-parse was a measured 50k-import
        // hot spot). finalize() on a cached statement resets it for reuse.
        let stmt = try connection.prepareCached(sql)
        defer { stmt.finalize() }
        for (i, v) in bindings.enumerated() {
            try stmt.bind(v, at: Int32(i + 1))
        }

        var events: [AuditEvent] = []
        while try stmt.step() {
            // decodeAuditRow throws StorageError.corruptStoredValue when a UUID
            // column cannot be parsed. The error propagates so callers know a
            // specific audit row is unreadable rather than receiving a fabricated
            // event with a randomly-generated ID.
            events.append(try decodeAuditRow(stmt))
        }
        return events
    }

    func auditEventsForRow(_ rowID: UUID) throws -> [AuditEvent] {
        // Chronological (full-precision HLC) order — see iterateAudit for why
        // the packed `hlc` column must not be the ordering key.
        let stmt = try connection.prepare("""
            SELECT * FROM "_storagekit_audit" WHERE "row_id" = ?
            ORDER BY "physical_time" ASC, "logical_count" ASC, "node_id" ASC
            """)
        defer { stmt.finalize() }
        try stmt.bind(.text(rowID.uuidString), at: 1)
        var events: [AuditEvent] = []
        while try stmt.step() {
            events.append(try decodeAuditRow(stmt))
        }
        return events
    }

    func auditCount() throws -> Int {
        let stmt = try connection.prepare("SELECT COUNT(*) FROM \"_storagekit_audit\"")
        defer { stmt.finalize() }
        guard try stmt.step() else { return 0 }
        return Int(stmt.columnInt64(0))
    }

    /// Decode one audit row from the statement into an AuditEvent.
    ///
    /// UUID columns (event_id, estate_uuid, row_id) are stored as uppercase
    /// TEXT. An unparseable string means the row is corrupt; throw
    /// `.corruptStoredValue` rather than substituting a random UUID which
    /// would produce a valid-looking but fabricated audit record.
    private func decodeAuditRow(_ stmt: SQLiteStatement) throws -> AuditEvent {
        let table = "_storagekit_audit"

        let eventIDStr = stmt.columnText(0) ?? ""
        guard let eventID = UUID(uuidString: eventIDStr) else {
            throw StorageError.corruptStoredValue(table: table, column: "event_id", storedText: eventIDStr)
        }
        // Reconstruct the HLC from the full-precision columns (physical_time,
        // logical_count, node_id at indices 17/18/19), NOT the packed `hlc`
        // column at index 1: HLC.packed truncates physicalTime to 40 bits, which
        // silently drops bit 40 for any post-2004 ms and makes a cold-rebuild
        // lastHLC disagree with the snapshot path (skipping newer tail events on
        // incremental hydration). The packed column remains the ordering key.
        // Mirrors the Rust port, which also stores the three columns full.
        let hlc = HLC(
            physicalTime: stmt.columnInt64(17),
            logicalCount: Int32(truncatingIfNeeded: stmt.columnInt64(18)),
            nodeID: Int32(truncatingIfNeeded: stmt.columnInt64(19))
        )

        let estateUUIDStr = stmt.columnText(2) ?? ""
        guard let estateUUID = UUID(uuidString: estateUUIDStr) else {
            throw StorageError.corruptStoredValue(table: table, column: "estate_uuid", storedText: estateUUIDStr)
        }

        let rowIdStr = stmt.columnText(3) ?? ""
        guard let rowId = UUID(uuidString: rowIdStr) else {
            throw StorageError.corruptStoredValue(table: table, column: "row_id", storedText: rowIdStr)
        }

        let verb = stmt.columnText(4) ?? ""

        let beforeBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)?
        if stmt.columnType(5) == SQLITE_NULL {
            beforeBitmaps = nil
        } else {
            beforeBitmaps = (stmt.columnInt64(5), stmt.columnInt64(6), stmt.columnInt64(7))
        }
        let afterBitmaps = (stmt.columnInt64(8), stmt.columnInt64(9), stmt.columnInt64(10))

        let beforeLattice: LatticeAnchor?
        if stmt.columnType(11) == SQLITE_NULL {
            beforeLattice = nil
        } else {
            beforeLattice = LatticeAnchor(
                udcCode: UInt64(bitPattern: stmt.columnInt64(11)),
                qidPointer: UInt64(bitPattern: stmt.columnInt64(12))
            )
        }
        let afterLattice = LatticeAnchor(
            udcCode: UInt64(bitPattern: stmt.columnInt64(13)),
            qidPointer: UInt64(bitPattern: stmt.columnInt64(14))
        )
        let actor = stmt.columnText(15) ?? ""
        // reason is nullable TEXT at column 16; nil when the event was recorded
        // without a caller-supplied reason (the common case).
        let reason: String? = stmt.columnType(16) == SQLITE_NULL ? nil : stmt.columnText(16)

        return AuditEvent(
            eventID: eventID,
            estateUuid: estateUUID,
            rowId: rowId,
            hlc: hlc,
            verb: verb,
            beforeBitmaps: beforeBitmaps,
            afterBitmaps: afterBitmaps,
            beforeLatticeAnchor: beforeLattice,
            afterLatticeAnchor: afterLattice,
            actor: actor,
            reason: reason
        )
    }
}

// MARK: - StorageMaintenance (shared-content 1.1 P5)

extension SQLiteStorage: StorageMaintenance {
    public func estimatedReclaimableBytes() async throws -> Int64 {
        try await backend.maintenanceEstimatedReclaimableBytes()
    }

    public func performMaintenance(
        progress: (@Sendable (StorageMaintenanceProgress) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) async throws -> StorageMaintenanceReport {
        try await backend.performMaintenance(progress: progress, shouldCancel: shouldCancel)
    }
}

extension SQLiteBackend {

    /// Freelist pages × page size, plus the WAL file's current size — the
    /// filesystem bytes a checkpoint + VACUUM pass would release. Read-only
    /// (two PRAGMAs + one file stat); safe for status polling.
    func maintenanceEstimatedReclaimableBytes() throws -> Int64 {
        let pageSize = try pragmaInt64("page_size")
        let freelist = try pragmaInt64("freelist_count")
        return freelist * pageSize + walFileBytes()
    }

    /// WAL checkpoint (TRUNCATE) + VACUUM with the four-phase contract
    /// declared on `StorageMaintenance`: quiescence check, disk-capacity
    /// preflight, per-phase progress, phase-boundary cancellation, and
    /// post-operation introspection.
    ///
    /// Runs entirely inside the backend actor: no row/blob operation can
    /// interleave, so the quiescence check (`inTransaction`) is authoritative
    /// for this process. Cross-process writers are excluded by the existing
    /// one-connection-per-estate exclusivity posture; a cross-process lock
    /// surfaces as a backend failure from VACUUM itself, never as corruption.
    func performMaintenance(
        progress: (@Sendable (StorageMaintenanceProgress) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) throws -> StorageMaintenanceReport {
        let started = Date()
        let totalPhases = StorageMaintenancePhase.allCases.count
        var completed = 0
        func enter(_ phase: StorageMaintenancePhase) throws {
            if shouldCancel?() == true {
                throw StorageMaintenanceError.cancelled(atPhase: phase)
            }
            progress?(StorageMaintenanceProgress(
                phase: phase, completedPhases: completed, totalPhases: totalPhases))
        }

        // Phase 1 — preflight: quiescence, baselines, disk capacity.
        try enter(.preflight)
        guard !inTransaction else {
            throw StorageMaintenanceError.notQuiescent(
                reason: "a transaction is open on the estate connection")
        }
        let pageSize = try pragmaInt64("page_size")
        let pageCountBefore = try pragmaInt64("page_count")
        let freelistBefore = try pragmaInt64("freelist_count")
        let fileBefore = dbFileBytes()
        let walBefore = walFileBytes()
        // VACUUM rewrites the live pages into a temporary database before
        // swapping it in, so the volume needs at least the live-content size
        // free. The check is best-effort: when the volume capacity cannot be
        // read (nil), VACUUM proceeds and its own failure is still surfaced.
        let requiredBytes = (pageCountBefore - freelistBefore) * pageSize
        if let available = volumeAvailableBytes(), available < requiredBytes {
            throw StorageMaintenanceError.insufficientDiskCapacity(
                requiredBytes: requiredBytes, availableBytes: available)
        }
        completed = 1

        // Phase 2 — WAL checkpoint. TRUNCATE flushes every frame into the
        // main database file and truncates the WAL to zero bytes, so the
        // subsequent VACUUM operates on the complete committed state and the
        // WAL's disk footprint is released along with the freelist pages.
        try enter(.walCheckpoint)
        do {
            let stmt = try connection.prepare("PRAGMA wal_checkpoint(TRUNCATE)")
            defer { stmt.finalize() }
            _ = try stmt.step()
        } catch {
            throw StorageMaintenanceError.backendFailure(
                reason: "wal_checkpoint failed: \(error)")
        }
        completed = 2

        // Phase 3 — VACUUM INTO + atomic file swap. `VACUUM INTO 'path'` passes
        // a real file path to SQLite's internal ATTACH, bypassing the empty-string
        // sentinel that sqlite3RunVacuum uses for its temp file (sqlite3.c line
        // 166984). SQLCipher's SQLITE_HAS_CODEC pager hook fails on that sentinel
        // with SQLITE_CANTOPEN on encrypted estates; a real path succeeds because
        // sqlite3BtreeOpen handles it without the empty-path codec shortcut.
        // After VACUUM INTO completes, the connection is closed to release the
        // file lock, the compacted copy is atomically swapped in, and the
        // connection is reopened so Phase 4 PRAGMAs operate on the new file.
        try enter(.vacuum)
        let tempURL = connection.url
            .deletingLastPathComponent()
            .appendingPathComponent(".vacuum-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try connection.exec("VACUUM INTO '\(tempURL.path)'")
        } catch {
            throw StorageMaintenanceError.backendFailure(
                reason: "VACUUM failed: \(error)")
        }
        connection.close()
        do {
            try FileManager.default.replaceItem(
                at: connection.url,
                withItemAt: tempURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly,
                resultingItemURL: nil)
        } catch {
            throw StorageMaintenanceError.backendFailure(
                reason: "VACUUM file swap failed: \(error)")
        }
        try connection.reopen()
        completed = 3

        // Phase 4 — post-operation introspection. VACUUM itself commits
        // through the WAL in WAL mode, so a second TRUNCATE checkpoint runs
        // first — without it the rewritten pages would sit in a fresh WAL
        // file and the filesystem would not see the reclaim.
        try enter(.introspection)
        do {
            let stmt = try connection.prepare("PRAGMA wal_checkpoint(TRUNCATE)")
            defer { stmt.finalize() }
            _ = try stmt.step()
        } catch {
            throw StorageMaintenanceError.backendFailure(
                reason: "post-VACUUM wal_checkpoint failed: \(error)")
        }
        let pageCountAfter = try pragmaInt64("page_count")
        let freelistAfter = try pragmaInt64("freelist_count")
        let fileAfter = dbFileBytes()
        let walAfter = walFileBytes()
        let reclaimed = max(0, (fileBefore + walBefore) - (fileAfter + walAfter))
        return StorageMaintenanceReport(
            backend: "sqlite", performed: true, note: nil,
            pageSizeBytes: pageSize,
            pageCountBefore: pageCountBefore, pageCountAfter: pageCountAfter,
            freelistPagesBefore: freelistBefore, freelistPagesAfter: freelistAfter,
            fileSizeBytesBefore: fileBefore, fileSizeBytesAfter: fileAfter,
            walBytesBefore: walBefore, walBytesAfter: walAfter,
            reclaimedBytes: reclaimed,
            durationSeconds: Date().timeIntervalSince(started))
    }

    // MARK: maintenance helpers

    private func pragmaInt64(_ name: String) throws -> Int64 {
        let stmt = try connection.prepare("PRAGMA \(name)")
        defer { stmt.finalize() }
        return try stmt.step() ? stmt.columnInt64(0) : 0
    }

    private func dbFileBytes() -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: connection.url.path)[.size] as? Int64)
            .flatMap { $0 } ?? 0
    }

    private func walFileBytes() -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: connection.url.path + "-wal")[.size] as? Int64)
            .flatMap { $0 } ?? 0
    }

    private func volumeAvailableBytes() -> Int64? {
        let dir = connection.url.deletingLastPathComponent()
        guard let values = try? dir.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return capacity
    }
}
