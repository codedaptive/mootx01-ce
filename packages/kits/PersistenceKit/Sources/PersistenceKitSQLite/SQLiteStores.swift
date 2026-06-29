// SQLiteStores.swift
//
// Wrappers around SQLiteBackend implementing the four PersistenceKit
// store protocols.

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

final class SQLiteRowStore: RowStore, Sendable {
    let backend: SQLiteBackend
    init(backend: SQLiteBackend) { self.backend = backend }

    func insert(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        try await backend.insertRow(table: table, values: values)
    }
    func upsert(table: String, values: [String: TypedValue], conflictColumns: [String]) async throws -> RowHandle {
        try await backend.upsertRow(table: table, values: values, conflictColumns: conflictColumns)
    }
    func update(table: String, values: [String: TypedValue], where predicate: StoragePredicate) async throws -> Int {
        try await backend.updateRows(table: table, values: values, where: predicate)
    }
    func delete(table: String, where predicate: StoragePredicate) async throws -> Int {
        try await backend.deleteRows(table: table, where: predicate)
    }
    func query(table: String, where predicate: StoragePredicate?, orderBy: [OrderClause], limit: Int?, offset: Int?) async throws -> [StorageRow] {
        try await backend.queryRows(table: table, where: predicate, orderBy: orderBy, limit: limit, offset: offset, tableSchema: nil, columns: nil)
    }
    // No-blob projection: thread the requested column list to the backend so
    // the generated SELECT names only those columns. Omitting "content" means
    // the blob is never read from SQLite — the dense-first candidate-pool load.
    func query(table: String, where predicate: StoragePredicate?, orderBy: [OrderClause], limit: Int?, offset: Int?, columns: [String]?) async throws -> [StorageRow] {
        try await backend.queryRows(table: table, where: predicate, orderBy: orderBy, limit: limit, offset: offset, tableSchema: nil, columns: columns)
    }
    func count(table: String, where predicate: StoragePredicate?) async throws -> Int {
        try await backend.countRows(table: table, where: predicate)
    }

    // MARK: - Transaction boundary (GLK_BATCH1)

    /// Open a write transaction on the SQLite backend.
    ///
    /// Delegates to `SQLiteBackend.beginTransactionDirect()`, which issues
    /// `BEGIN IMMEDIATE` and sets `inTransaction`. Errors if a transaction is
    /// already open (nested transactions are not supported).
    func beginTransaction() async throws {
        try await backend.beginTransactionDirect()
    }

    /// Commit the current transaction.
    func commitTransaction() async throws {
        try await backend.commitTransactionDirect()
    }

    /// Roll back the current transaction, discarding all uncommitted writes.
    func rollbackTransaction() async throws {
        try await backend.rollbackTransactionDirect()
    }

    /// SQLite cursor-level skip-corrupt: overrides the `RowStore` default so
    /// individual corrupt rows (e.g. a `+58432-...` poison timestamp) are
    /// skipped and logged rather than aborting the entire corpus scan.
    func querySkipCorrupt(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> (rows: [StorageRow], skipped: Int) {
        try await backend.queryRowsSkipCorrupt(
            table: table, where: predicate,
            orderBy: orderBy, limit: limit, offset: offset,
            columns: columns)
    }
}

final class SQLiteBlobStore: BlobStore, Sendable {
    let backend: SQLiteBackend
    init(backend: SQLiteBackend) { self.backend = backend }

    func put(key: BlobKey, bytes: Data) async throws { try await backend.putBlob(key, bytes: bytes) }
    func get(key: BlobKey) async throws -> Data? { try await backend.getBlob(key) }
    func delete(key: BlobKey) async throws { try await backend.deleteBlob(key) }
    func exists(key: BlobKey) async throws -> Bool { try await backend.blobExists(key) }
    func size(key: BlobKey) async throws -> Int? { try await backend.blobSize(key) }
    func listKeys() async throws -> [BlobKey] { try await backend.listBlobKeys() }
}

final class SQLiteAuditLog: AuditLog, Sendable {
    let backend: SQLiteBackend
    init(backend: SQLiteBackend) { self.backend = backend }

    func append(_ event: AuditEvent) async throws { try await backend.appendAuditEvent(event) }
    func appendBatch(_ events: [AuditEvent]) async throws { try await backend.appendAuditBatch(events) }
    func iterate(after: HLC?, rowID: UUID?, limit: Int) async throws -> [AuditEvent] {
        try await backend.iterateAudit(after: after, rowID: rowID, limit: limit)
    }
    func eventsForRow(_ rowID: UUID) async throws -> [AuditEvent] {
        try await backend.auditEventsForRow(rowID)
    }
    func count() async throws -> Int {
        try await backend.auditCount()
    }
}

final class SQLiteTransaction: StorageTransaction, Sendable {
    let rowStore: any RowStore
    let blobStore: any BlobStore
    let auditLog: any AuditLog

    init(backend: SQLiteBackend) {
        self.rowStore = SQLiteRowStore(backend: backend)
        self.blobStore = SQLiteBlobStore(backend: backend)
        self.auditLog = SQLiteAuditLog(backend: backend)
    }
}
