// InMemoryStorage.swift
//
// In-memory backend. Validates the protocol surface; used for
// tests and rapid iteration. No persistence between process runs.
// Always serializable isolation (full snapshot on transaction start).
// Swift 6 strict concurrency: state held in an actor.

import Foundation
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
import SubstrateTypes

public final class InMemoryStorage: Storage, Sendable {
    public let configuration: EstateConfiguration

    public let rowStore: any RowStore
    public let blobStore: any BlobStore
    public let vectorIndex: any VectorIndex
    public let auditLog: any AuditLog
    public let observer: any StorageObserver

    let stateActor: InMemoryStateActor
    let observerRegistry: ObserverRegistry

    public init(configuration: EstateConfiguration) {
        precondition({
            if case .inMemory = configuration.backend { return true }
            return false
        }(), "InMemoryStorage requires .inMemory backend configuration")

        self.configuration = configuration
        let registry = ObserverRegistry()
        self.observerRegistry = registry
        let actor = InMemoryStateActor(observerRegistry: registry)
        self.stateActor = actor
        let baseRowStore = InMemoryRowStore(stateActor: actor)
        // Wrap in the LRU hot-tier decorator when caching is enabled. The
        // disabled path (the default) is byte-identical to pre-wiring behavior —
        // callers receive an `any RowStore` either way so no call sites change.
        self.rowStore = configuration.cacheConfig.enabled
            ? CachingRowStore(backing: baseRowStore, config: configuration.cacheConfig)
            : baseRowStore
        self.blobStore = InMemoryBlobStore(stateActor: actor)
        self.vectorIndex = InMemoryVectorIndex(stateActor: actor)
        self.auditLog = InMemoryAuditLog(stateActor: actor)
        self.observer = InMemoryObserver(registry: registry)
    }

    public func open(schema: SchemaDeclaration) async throws {
        try await stateActor.openSchema(schema)
    }

    public func close() async {
        // No-op for in-memory.
    }

    public func currentSchemaVersion() async throws -> Int {
        await stateActor.schemaVersion()
    }

    public func currentSchemaVersion(for kitID: String) async throws -> Int {
        await stateActor.schemaVersion(for: kitID)
    }

    public func migrate(to schema: SchemaDeclaration) async throws {
        try await stateActor.applyMigrations(schema)
    }

    public func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        // Take snapshot. Run block against a transactional actor. On
        // success, replace the main state. On error, discard.
        let snapshot = await stateActor.snapshot()
        let txnActor = InMemoryStateActor(initial: snapshot)
        let txn = InMemoryTransaction(stateActor: txnActor)

        do {
            let result = try await block(txn)
            let finalState = await txnActor.snapshot()
            await stateActor.replace(with: finalState)
            return result
        } catch {
            // Record the rollback so StorageIntrospection can surface it.
            await stateActor.recordRollback()
            throw error
        }
    }
}

// MARK: - StorageIntrospection

extension InMemoryStorage: StorageIntrospection {
    /// Capture a point-in-time snapshot of InMemory backend health.
    ///
    /// logicalSizeBytes is an approximation: 256 bytes per row (rough dict-of-TypedValue
    /// overhead) plus the exact byte count of stored blobs. It is suitable as a relative
    /// health signal, not an allocator measurement.
    public func stats(now: Date) async -> StorageStats {
        let snap = await stateActor.introspectionSnapshot()
        return StorageStats(
            logicalSizeBytes: snap.approxBytes,
            transactionRollbackCount: snap.rollbackCount,
            rowCount: snap.rowCount,
            blobCount: snap.blobCount,
            vectorCount: snap.vectorCount,
            capturedAt: now
        )
    }
}

// MARK: - In-memory state actor

actor InMemoryStateActor {
    var state: InMemoryState
    let observerRegistry: ObserverRegistry?

    init(initial: InMemoryState = InMemoryState(), observerRegistry: ObserverRegistry? = nil) {
        self.state = initial
        self.observerRegistry = observerRegistry
    }

    private func notify(_ change: TableChange) async {
        if let registry = observerRegistry {
            // Awaited, not fire-and-forget: changes are delivered to observers in
            // the exact order their mutations were applied. The prior
            // `Task { await registry.notify(change) }` spawned one unordered task
            // per change, so concurrent/sequential mutations could be observed
            // out of order (see PK-TEST-01 InMemoryObserverTests.insertNotification).
            await registry.notify(change)
        }
    }

    func snapshot() -> InMemoryState { state }
    func replace(with newState: InMemoryState) { state = newState }
    func schemaVersion() -> Int { state.schemaVersion }

    /// Per-kit schema version, keyed by kitID. Returns 0 if no migrations
    /// have been applied for this kit yet.
    func schemaVersion(for kitID: String) -> Int {
        state.kitSchemaVersions[kitID] ?? 0
    }

    func openSchema(_ schema: SchemaDeclaration) throws {
        // Gate on the per-kit version so a second kit opening on this storage
        // does not skip migration because another kit's migration advanced the
        // global schemaVersion counter above this kit's target version.
        let kitCurrent = state.kitSchemaVersions[schema.kitID] ?? 0
        if kitCurrent < schema.version {
            try applyMigrationsInner(schema)
        }
        state.schemaDeclaration = schema
    }

    func applyMigrations(_ schema: SchemaDeclaration) throws {
        try applyMigrationsInner(schema)
    }

    private func applyMigrationsInner(_ schema: SchemaDeclaration) throws {
        for table in schema.tables {
            if state.tables[table.name] == nil {
                state.tables[table.name] = InMemoryTable(declaration: table)
            }
        }
        // Per-kit version is the source of truth for the migration gate.
        // The global `schemaVersion` is updated in parallel so the no-arg
        // `currentSchemaVersion()` still returns a sensible value (the max
        // across all kits that have opened on this storage instance).
        let kitCurrent = state.kitSchemaVersions[schema.kitID] ?? 0
        let pending = schema.migrations
            .filter { $0.fromVersion >= kitCurrent && $0.toVersion <= schema.version }
            .sorted(by: { $0.fromVersion < $1.fromVersion })
        for migration in pending {
            for op in migration.operations {
                try applyOperation(op)
            }
            state.kitSchemaVersions[schema.kitID] = migration.toVersion
            state.schemaVersion = max(state.schemaVersion, migration.toVersion)
        }
        if (state.kitSchemaVersions[schema.kitID] ?? 0) < schema.version {
            state.kitSchemaVersions[schema.kitID] = schema.version
            state.schemaVersion = max(state.schemaVersion, schema.version)
        }
    }

    private func applyOperation(_ op: SchemaOperation) throws {
        switch op {
        case .createTable(let decl):
            state.tables[decl.name] = InMemoryTable(declaration: decl)
        case .dropTable(let name):
            state.tables.removeValue(forKey: name)
        case .addColumn(let table, let column):
            guard var t = state.tables[table] else {
                throw StorageError.invalidQuery(detail: "addColumn: table \(table) not found")
            }
            t.declaration = TableDeclaration(
                name: t.declaration.name,
                columns: t.declaration.columns + [column],
                primaryKey: t.declaration.primaryKey,
                uniqueConstraints: t.declaration.uniqueConstraints,
                generatedColumns: t.declaration.generatedColumns,
                appendOnly: t.declaration.appendOnly
            )
            state.tables[table] = t
        case .dropColumn(let table, let columnName):
            guard var t = state.tables[table] else {
                throw StorageError.invalidQuery(detail: "dropColumn: table \(table) not found")
            }
            t.declaration = TableDeclaration(
                name: t.declaration.name,
                columns: t.declaration.columns.filter { $0.name != columnName },
                primaryKey: t.declaration.primaryKey,
                uniqueConstraints: t.declaration.uniqueConstraints,
                generatedColumns: t.declaration.generatedColumns,
                appendOnly: t.declaration.appendOnly
            )
            for (k, v) in t.rows {
                var vv = v
                vv.removeValue(forKey: columnName)
                t.rows[k] = vv
            }
            state.tables[table] = t
        case .renameColumn, .addIndex, .dropIndex, .custom:
            break
        }
    }

    // MARK: - Row operations (called by InMemoryRowStore)

    func insertRow(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        guard var t = state.tables[table] else {
            throw StorageError.invalidQuery(detail: "insert: table \(table) not found")
        }
        let key = resolveOrAllocateKey(table: t, values: values)
        if t.rows[key] != nil {
            throw StorageError.duplicateKey(table: table, key: key.uuidString)
        }
        let stored = Self.materializeGenerated(t.declaration, values)
        t.rows[key] = stored
        state.tables[table] = t
        await notify(TableChange(table: table, event: .insert, rowKey: key, values: stored))
        return RowHandle(table: table, key: key)
    }

    func upsertRow(table: String, values: [String: TypedValue], conflictColumns: [String]) async throws -> RowHandle {
        guard var t = state.tables[table] else {
            throw StorageError.invalidQuery(detail: "upsert: table \(table) not found")
        }
        let existing = t.rows.first { (_, row) in
            conflictColumns.allSatisfy { col in
                if let lhs = row[col], let rhs = values[col] { return lhs == rhs }
                return false
            }
        }
        if let (existingKey, existingRow) = existing {
            var merged = existingRow
            for (k, v) in values { merged[k] = v }
            merged = Self.materializeGenerated(t.declaration, merged)
            t.rows[existingKey] = merged
            state.tables[table] = t
            await notify(TableChange(table: table, event: .update, rowKey: existingKey, values: merged))
            return RowHandle(table: table, key: existingKey)
        }
        let key = resolveOrAllocateKey(table: t, values: values)
        let stored = Self.materializeGenerated(t.declaration, values)
        t.rows[key] = stored
        state.tables[table] = t
        await notify(TableChange(table: table, event: .insert, rowKey: key, values: stored))
        return RowHandle(table: table, key: key)
    }

    func updateRows(table: String, values: [String: TypedValue], where predicate: StoragePredicate) async throws -> Int {
        guard var t = state.tables[table] else {
            throw StorageError.invalidQuery(detail: "update: table \(table) not found")
        }
        if t.declaration.appendOnly {
            throw StorageError.appendOnlyViolation(table: table)
        }
        var count = 0
        var notifications: [TableChange] = []
        for (k, row) in t.rows where PredicateEvaluator.evaluate(predicate, against: row) {
            var merged = row
            for (col, v) in values { merged[col] = v }
            merged = Self.materializeGenerated(t.declaration, merged)
            t.rows[k] = merged
            notifications.append(TableChange(table: table, event: .update, rowKey: k, values: merged))
            count += 1
        }
        state.tables[table] = t
        for n in notifications { await notify(n) }
        return count
    }

    func deleteRows(table: String, where predicate: StoragePredicate) async throws -> Int {
        guard var t = state.tables[table] else {
            throw StorageError.invalidQuery(detail: "delete: table \(table) not found")
        }
        if t.declaration.appendOnly {
            throw StorageError.appendOnlyViolation(table: table)
        }
        var count = 0
        var notifications: [TableChange] = []
        for (k, row) in t.rows where PredicateEvaluator.evaluate(predicate, against: row) {
            t.rows.removeValue(forKey: k)
            notifications.append(TableChange(table: table, event: .delete, rowKey: k, values: row))
            count += 1
        }
        state.tables[table] = t
        for n in notifications { await notify(n) }
        return count
    }

    func queryRows(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?
    ) throws -> [StorageRow] {
        guard let t = state.tables[table] else {
            throw StorageError.invalidQuery(detail: "query: table \(table) not found")
        }
        var results: [StorageRow] = []
        for (_, row) in t.rows {
            if predicate == nil || PredicateEvaluator.evaluate(predicate!, against: row) {
                results.append(StorageRow(values: row))
            }
        }
        if !orderBy.isEmpty {
            results.sort { lhs, rhs in
                for clause in orderBy {
                    let lv = lhs[clause.column.name] ?? .null
                    let rv = rhs[clause.column.name] ?? .null
                    if let c = TypedValueComparator.compare(lv, rv), c != 0 {
                        return clause.direction == .ascending ? c < 0 : c > 0
                    }
                }
                return false
            }
        }
        if let off = offset, off > 0 { results = Array(results.dropFirst(off)) }
        if let lim = limit { results = Array(results.prefix(lim)) }
        return results
    }

    func countRows(table: String, where predicate: StoragePredicate?) throws -> Int {
        guard let t = state.tables[table] else {
            throw StorageError.invalidQuery(detail: "count: table \(table) not found")
        }
        if let p = predicate {
            return t.rows.values.filter { PredicateEvaluator.evaluate(p, against: $0) }.count
        }
        return t.rows.count
    }

    private func resolveOrAllocateKey(table: InMemoryTable, values: [String: TypedValue]) -> RowKey {
        if table.declaration.primaryKey.count == 1 {
            let pkName = table.declaration.primaryKey[0]
            if let pkValue = values[pkName], case .uuid(let u) = pkValue { return u }
        }
        return UUID()
    }

    /// Materialize a table's generated columns into a row dict.
    /// Each generated column's expression is evaluated against the
    /// row's other values and the integer result is wrapped in the
    /// declared TypedValue case. This mirrors what SQLite and
    /// PostgreSQL compute in their STORED generated columns, so a
    /// query against any backend returns the same materialized
    /// value. Pure and static so it can run from insert, upsert,
    /// and update without touching actor state.
    static func materializeGenerated(
        _ declaration: TableDeclaration,
        _ row: [String: TypedValue]
    ) -> [String: TypedValue] {
        guard !declaration.generatedColumns.isEmpty else { return row }
        var out = row
        for gen in declaration.generatedColumns {
            let raw = gen.expression.evaluate(row)
            switch gen.type {
            case .bitmap: out[gen.name] = .bitmap(raw)
            case .bool:   out[gen.name] = .bool(raw != 0)
            default:      out[gen.name] = .int(raw)
            }
        }
        return out
    }

    // MARK: - Blob operations

    func putBlob(_ key: BlobKey, bytes: Data) { state.blobs[key] = bytes }
    func getBlob(_ key: BlobKey) -> Data? { state.blobs[key] }
    func deleteBlob(_ key: BlobKey) { state.blobs.removeValue(forKey: key) }
    func blobExists(_ key: BlobKey) -> Bool { state.blobs[key] != nil }
    func blobSize(_ key: BlobKey) -> Int? { state.blobs[key]?.count }

    // MARK: - Vector operations

    func putVector(_ key: RowKey, vector: [Float], metadata: [String: TypedValue]) {
        state.vectors[key] = InMemoryVectorEntry(vector: vector, metadata: metadata)
    }

    func deleteVector(_ key: RowKey) { state.vectors.removeValue(forKey: key) }

    func vectorCount() -> Int { state.vectors.count }

    func vectorSnapshot() -> [RowKey: InMemoryVectorEntry] { state.vectors }

    // MARK: - Audit operations

    func appendAudit(_ event: AuditEvent) {
        let record = AuditEventRecord(event: event)
        if !state.auditEvents.contains(where: { $0.key == record.key }) {
            state.auditEvents.append(record)
        }
    }

    func appendAuditBatch(_ events: [AuditEvent]) {
        for event in events {
            let record = AuditEventRecord(event: event)
            if !state.auditEvents.contains(where: { $0.key == record.key }) {
                state.auditEvents.append(record)
            }
        }
    }

    func iterateAudit(after: HLC?, rowID: UUID?, limit: Int) -> [AuditEvent] {
        var events = state.auditEvents.map { $0.event }
        if let after { events = events.filter { $0.hlc > after } }
        if let rowID { events = events.filter { $0.rowId == rowID } }
        events.sort { $0.hlc < $1.hlc }
        return Array(events.prefix(limit))
    }

    func auditEventsForRow(_ rowID: UUID) -> [AuditEvent] {
        state.auditEvents
            .map { $0.event }
            .filter { $0.rowId == rowID }
            .sorted { $0.hlc < $1.hlc }
    }

    func auditCount() -> Int { state.auditEvents.count }

    // MARK: - Introspection

    /// Capture an introspection snapshot from the current state.
    ///
    /// InMemory fields:
    /// - logicalSizeBytes: approximate in-memory footprint, estimated as the
    ///   sum of row count * 256 bytes (a conservative average per row for
    ///   dict-of-TypedValue storage overhead) plus blob bytes.
    ///   This is a rough signal, not a precise allocator measurement.
    /// - rowCount: sum of all row counts across all tables.
    /// - blobCount: number of blob entries.
    /// - vectorCount: number of vector entries.
    /// - transactionRollbackCount: incremented by InMemoryStorage.transaction()
    ///   on error. The actor tracks this as a monotone counter.
    func introspectionSnapshot() -> (rowCount: Int, blobCount: Int, vectorCount: Int, rollbackCount: Int64, approxBytes: Int64) {
        let rows = state.tables.values.map { $0.rows.count }.reduce(0, +)
        let blobs = state.blobs.count
        let vectors = state.vectors.count
        // Approximate size: row overhead (256 B avg) + actual blob bytes.
        let blobBytes = state.blobs.values.map { Int64($0.count) }.reduce(0, +)
        let approxBytes = Int64(rows) * 256 + blobBytes
        return (rows, blobs, vectors, rollbackStats, approxBytes)
    }

    // Monotone rollback counter. Incremented by InMemoryStorage.transaction()
    // when the user block throws. Used to surface the transactionRollbackCount
    // field in StorageStats for callers that want to track error rates.
    var rollbackStats: Int64 = 0

    func recordRollback() {
        rollbackStats += 1
    }
}

// MARK: - In-memory state value types

struct InMemoryState: Sendable {
    /// Global maximum schema version across all kits (for no-arg `currentSchemaVersion()`).
    var schemaVersion: Int = 0
    /// Per-kit schema versions (for `currentSchemaVersion(for:)`).
    var kitSchemaVersions: [String: Int] = [:]
    var schemaDeclaration: SchemaDeclaration? = nil
    var tables: [String: InMemoryTable] = [:]
    var blobs: [BlobKey: Data] = [:]
    var vectors: [RowKey: InMemoryVectorEntry] = [:]
    var auditEvents: [AuditEventRecord] = []
}

struct InMemoryTable: Sendable {
    var declaration: TableDeclaration
    var rows: [RowKey: [String: TypedValue]] = [:]
}

struct InMemoryVectorEntry: Sendable {
    let vector: [Float]
    let metadata: [String: TypedValue]
}

struct AuditEventRecord: Sendable {
    let event: AuditEvent
    var key: String { "\(event.eventID.uuidString):\(event.hlc.packed)" }
}

// MARK: - Transaction

final class InMemoryTransaction: StorageTransaction, Sendable {
    let rowStore: any RowStore
    let blobStore: any BlobStore
    let vectorIndex: any VectorIndex
    let auditLog: any AuditLog

    init(stateActor: InMemoryStateActor) {
        self.rowStore = InMemoryRowStore(stateActor: stateActor)
        self.blobStore = InMemoryBlobStore(stateActor: stateActor)
        self.vectorIndex = InMemoryVectorIndex(stateActor: stateActor)
        self.auditLog = InMemoryAuditLog(stateActor: stateActor)
    }
}

// HLC packed accessor.
extension HLC {
    var packed: UInt64 {
        let p = UInt64(bitPattern: Int64(physicalTime)) & 0xFFFF_FFFF_FFFF
        let l = UInt64(UInt32(bitPattern: logicalCount) & 0xFFF)
        let n = UInt64(UInt32(bitPattern: nodeID) & 0xF)
        return (p << 16) | (l << 4) | n
    }
}
