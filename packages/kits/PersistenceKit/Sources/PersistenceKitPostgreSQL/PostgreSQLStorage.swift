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
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
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
    public let vectorIndex: any VectorIndex
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
        let pool = PostgreSQLPool(
            connectionString: cs,
            poolSize: ps,
            connectionTimeout: ct,
            idleTimeout: it
        )
        self.pool = pool
        let backend = PostgreSQLBackend(pool: pool)
        self.backend = backend
        self.rowStore = PostgreSQLRowStore(backend: backend)
        self.blobStore = PostgreSQLBlobStore(backend: backend)
        self.vectorIndex = PostgreSQLVectorIndex(backend: backend)
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

// MARK: - Backend actor

actor PostgreSQLBackend {
    let pool: PostgreSQLPool
    let logger = Logger(label: "storagekit.postgres.backend")
    var schemaDeclaration: SchemaDeclaration?

    init(pool: PostgreSQLPool) {
        self.pool = pool
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

        // Apply pending migrations.
        let current = try await readSchemaVersion(connection: conn)
        let pending = schema.migrations
            .filter { $0.fromVersion >= current && $0.toVersion <= schema.version }
            .sorted(by: { $0.fromVersion < $1.fromVersion })
        for m in pending {
            try await conn.executeSimple("BEGIN", logger: logger)
            do {
                for op in m.operations {
                    try await applyOperation(op, connection: conn)
                }
                try await writeSchemaVersion(m.toVersion, connection: conn)
                try await conn.executeSimple("COMMIT", logger: logger)
            } catch {
                try? await conn.executeSimple("ROLLBACK", logger: logger)
                throw StorageError.migrationFailed(version: m.toVersion, reason: "\(error)")
            }
        }
        if pending.isEmpty && current < schema.version {
            try await writeSchemaVersion(schema.version, connection: conn)
        }
    }

    func currentSchemaVersion() async throws -> Int {
        let conn = try await pool.acquire()
        defer { Task { await pool.release(conn) } }
        return try await readSchemaVersion(connection: conn)
    }

    func applyMigrations(_ schema: SchemaDeclaration) async throws {
        try await open(schema: schema)
    }

    private func readSchemaVersion(connection: PostgresConnection) async throws -> Int {
        let rows = try await connection.executeParameterized(
            "SELECT \"value\" FROM \"_storagekit_meta\" WHERE \"key\" = $1",
            bindings: [.text("schema_version")],
            logger: logger
        )
        for try await row in rows {
            let access = row.makeRandomAccess()
            if let cell = try? access["value"] {
                if let s: String = try? cell.decode(String.self, context: .default), let v = Int(s) {
                    return v
                }
            }
        }
        return 0
    }

    private func writeSchemaVersion(_ v: Int, connection: PostgresConnection) async throws {
        _ = try await connection.executeParameterized("""
            INSERT INTO "_storagekit_meta" ("key", "value") VALUES ($1, $2)
            ON CONFLICT ("key") DO UPDATE SET "value" = EXCLUDED."value"
            """, bindings: [.text("schema_version"), .text(String(v))], logger: logger)
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

    // Schema column lookup
    func columns(for table: String) -> [ColumnDeclaration] {
        schemaDeclaration?.tables.first(where: { $0.name == table })?.columns ?? []
    }

    func primaryKey(for table: String) -> [String] {
        schemaDeclaration?.tables.first(where: { $0.name == table })?.primaryKey ?? []
    }
}

// MARK: - Transaction

final class PostgreSQLTransaction: StorageTransaction, Sendable {
    let rowStore: any RowStore
    let blobStore: any BlobStore
    let vectorIndex: any VectorIndex
    let auditLog: any AuditLog

    init(connection: PostgresConnection, backend: PostgreSQLBackend) {
        let ctx = PostgreSQLTransactionContext(connection: connection, backend: backend)
        self.rowStore = PostgreSQLRowStore(backend: backend, txn: ctx)
        self.blobStore = PostgreSQLBlobStore(backend: backend, txn: ctx)
        self.vectorIndex = PostgreSQLVectorIndex(backend: backend, txn: ctx)
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
