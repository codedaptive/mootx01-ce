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
        try await backend.runTransaction(isolation: isolation) { txn in
            try await block(txn)
        }
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
    /// Retained on openSchema so queryRows can resolve declared
    /// column types (bool, uuid, timestamp, bitmap, hlc, generated)
    /// and decode each column to its proper TypedValue case.
    private var schemaDeclaration: SchemaDeclaration?
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
        self.schemaDeclaration = schema
        // Internal tables first.
        try connection.exec(SQLiteSchema.migrationsTableSQL)
        try connection.exec(SQLiteSchema.auditTableSQL)
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
        // Retain the schema declaration so queryRows can resolve declared column
        // types (bool, uuid, timestamp, bitmap, hlc) when migrate(to:) is called
        // directly without a prior openSchema call. openSchema also sets this;
        // keeping both sites in sync ensures the hint is always present.
        if schemaDeclaration == nil {
            schemaDeclaration = schema
        }

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
        if inTransaction {
            throw StorageError.transactionConflict(detail: "nested transactions not supported")
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

    func insertRow(table: String, values: [String: TypedValue]) throws -> RowHandle {
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
        let values = try encryptedForWrite(values, config: encryptionConfig)
        // Structural content/keyID invariant (FUP-D): after the seam, a
        // content row on an encrypting estate must carry a keyID. A correct
        // encrypting insert has already become .blob + keyID here, so the
        // guard is a no-op for it; it fires only if the seam could not run.
        try assertContentKeyIDInvariant(values, table: table, config: encryptionConfig)
        let sortedKeys = values.keys.sorted()
        let cols = sortedKeys.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: sortedKeys.count).joined(separator: ", ")
        let sql = "INSERT INTO \"\(table)\" (\(cols)) VALUES (\(placeholders))"
        let stmt = try connection.prepare(sql)
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
        let key = extractRowKey(values: values)
        notifyObservers(TableChange(table: table, event: .insert, rowKey: key, values: values))
        return RowHandle(table: table, key: key)
    }

    // The at-rest encryption seam (ENC-01) lives on insertRow/queryRows
    // only. upsertRow is deliberately NOT wired: in the LocusKit schema it
    // is only ever called for non-content tables (manifest,
    // container_fingerprints, node_bundles), none of which carry a
    // "content" column. The content/keyID invariant is enforced
    // structurally (FUP-D): a content-bearing upsert on an encrypting
    // estate throws rather than silently writing plaintext content with a
    // null keyID (an unreadable row). A future content-upsert path must
    // extend the encryption seam symmetrically with insertRow before this
    // guard would let such a write through.
    func upsertRow(table: String, values: [String: TypedValue], conflictColumns: [String]) throws -> RowHandle {
        // SQL-identifier injection guard (CAND-047 / SECFIX-WS2-PK F9): validate
        // the table name, all value-map column names, and the conflict-column list
        // before interpolating into the INSERT … ON CONFLICT … DO UPDATE SQL.
        // Mirrors the Rust backend guard and the Postgres backend guard — shared
        // seam via module-level `validateSQLIdentifier`, no forked validator.
        try validateSQLIdentifier(table)
        for name in values.keys { try validateSQLIdentifier(name) }
        for name in conflictColumns { try validateSQLIdentifier(name) }
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
        let stmt = try connection.prepare(sql)
        defer { stmt.finalize() }
        for (i, key) in sortedKeys.enumerated() {
            try stmt.bind(values[key]!, at: Int32(i + 1))
        }
        _ = try stmt.step()
        let key = extractRowKey(values: values)
        notifyObservers(TableChange(table: table, event: .update, rowKey: key, values: values))
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
        // Structural content/keyID invariant (FUP-D): updateRows does not run
        // the encryption seam, so a content update on an encrypting estate
        // would write plaintext with a null keyID. Guard it like the other
        // write paths. All current callers update only bitmap/timestamp
        // columns, so this is a no-op for them.
        try assertContentKeyIDInvariant(values, table: table, config: encryptionConfig)
        // Pre-query row keys before mutating. The `values` dict carries only
        // the SET columns (not the primary key), so keys must be resolved via
        // a SELECT. The SQLiteBackend actor serializes all operations, so no
        // interleaving is possible between this SELECT and the UPDATE.
        let matchedKeys = try fetchMatchingRowKeys(table: table, predicate: predicate)
        let sortedKeys = values.keys.sorted()
        let setClause = sortedKeys.map { "\"\($0)\" = ?" }.joined(separator: ", ")
        let compiled = try SQLitePredicateCompiler.compile(predicate)
        let sql = "UPDATE \"\(table)\" SET \(setClause) WHERE \(compiled.sql)"
        let stmt = try connection.prepare(sql)
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
        for key in matchedKeys {
            notifyObservers(TableChange(table: table, event: .update, rowKey: key, values: nil))
        }
        return changes
    }

    func deleteRows(table: String, where predicate: StoragePredicate) throws -> Int {
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
        let stmt = try connection.prepare(sql)
        defer { stmt.finalize() }
        for (i, v) in compiled.bindings.enumerated() {
            try stmt.bind(v, at: Int32(i + 1))
        }
        _ = try stmt.step()
        let changes = Int(sqlite3_changes(connection.handle))
        for key in matchedKeys {
            notifyObservers(TableChange(table: table, event: .delete, rowKey: key, values: nil))
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
        let resolvedSchema = tableSchema
            ?? schemaDeclaration?.tables.first(where: { $0.name == table })
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
        let projection: String
        if let columns, !columns.isEmpty {
            for name in columns {
                try validateSQLIdentifier(name)
            }
            projection = columns.map { "\"\($0)\"" }.joined(separator: ", ")
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

        let stmt = try connection.prepare(sql)
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
            // At-rest decryption seam (mode 2/3): decrypt the content
            // column when the row carries a key identifier. No-op for mode 1.
            rows.append(StorageRow(values: try decryptedForRead(values, config: encryptionConfig)))
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
        let resolvedSchema = schemaDeclaration?.tables.first(where: { $0.name == table })
        // SQL-identifier injection guard (SECFIX-WS2-PK F10): validate the
        // projected column names here, just as queryRows does for its projection
        // path. queryRowsSkipCorrupt shares the same SELECT construction, so the
        // same injection surface exists. Reject before SQL is built.
        let projection: String
        if let columns, !columns.isEmpty {
            for name in columns {
                try validateSQLIdentifier(name)
            }
            projection = columns.map { "\"\($0)\"" }.joined(separator: ", ")
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

        let stmt = try connection.prepare(sql)
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
            // At-rest decryption seam: decrypt content column when the row
            // carries a key identifier. No-op for Plaintext mode.
            rows.append(StorageRow(values: try decryptedForRead(values, config: encryptionConfig)))
        }
        return (rows, skipped)
    }

    // At-rest per-row encryption seam (Mission ENC-01): the write/read seam
    // (`encryptedForWrite` / `decryptedForRead` / `assertContentKeyIDInvariant`)
    // lives in PersistenceKit core (RowCrypto.swift) so the SQLite and
    // PostgreSQL backends share one byte-compatible implementation. The call
    // sites above (insertRow / upsertRow / updateRows / queryRows) invoke it
    // with this backend's `encryptionConfig`.

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
        let stmt = try connection.prepare(sql)
        defer { stmt.finalize() }
        for (i, v) in bindings.enumerated() {
            try stmt.bind(v, at: Int32(i + 1))
        }
        guard try stmt.step() else { return 0 }
        return Int(stmt.columnInt64(0))
    }

    private func extractRowKey(values: [String: TypedValue]) -> RowKey {
        // Prefer "row_id" column if present and UUID-typed.
        if let v = values["row_id"] {
            if case .uuid(let u) = v { return u }
            if case .text(let s) = v, let u = UUID(uuidString: s) { return u }
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
        let pkCol = schemaDeclaration?
            .tables.first(where: { $0.name == table })?
            .primaryKey.first ?? "row_id"
        // compile is now `throws` — predicate column names are validated inside
        // the compiler (SECFIX-WS2-PK F7).
        let compiled = try SQLitePredicateCompiler.compile(predicate)
        let sql = "SELECT \"\(pkCol)\" FROM \"\(table)\" WHERE \(compiled.sql)"
        let stmt = try connection.prepare(sql)
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
               "actor", "reason")
            VALUES (?, ?, ?, ?, ?,
                    ?, ?, ?,
                    ?, ?, ?,
                    ?, ?, ?, ?,
                    ?, ?)
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
            conditions.append("\"hlc\" > ?")
            bindings.append(.int(Int64(bitPattern: after.packed)))
        }
        if let rowID {
            conditions.append("\"row_id\" = ?")
            bindings.append(.text(rowID.uuidString))
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY \"hlc\" ASC LIMIT \(limit)"

        let stmt = try connection.prepare(sql)
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
        let stmt = try connection.prepare("""
            SELECT * FROM "_storagekit_audit" WHERE "row_id" = ? ORDER BY "hlc" ASC
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
        // HLC is stored as Int64(bitPattern: hlc.packed); recover via HLC(packed:)
        // for a bit-identical round-trip.
        let hlc = HLC(packed: UInt64(bitPattern: stmt.columnInt64(1)))

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
