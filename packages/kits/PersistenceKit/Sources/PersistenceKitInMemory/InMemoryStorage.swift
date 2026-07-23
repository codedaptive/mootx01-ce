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
// docs/engineering/HARNESS_REFERENCE.md. If you
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
    public let auditLog: any AuditLog
    public let observer: any StorageObserver

    /// Dataset store for user-defined tabular data (MX-TAB-1).
    ///
    /// Stored as a `let` — satisfies the `{ get throws }` protocol requirement
    /// with a non-throwing stored property (valid in Swift: non-throwing is a
    /// sub-type of throwing). Shares `stateActor` so dataset tables and row-
    /// store tables live in the same in-memory state snapshot — rolling back a
    /// transaction reverts both.
    public let datasetStore: any DatasetStore

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
        self.auditLog = InMemoryAuditLog(stateActor: actor)
        self.observer = InMemoryObserver(registry: registry)
        // Dataset store — same stateActor, so dataset tables participate in
        // transaction snapshots and rollbacks alongside row-store tables.
        self.datasetStore = InMemoryDatasetStore(stateActor: actor)
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
        // The block mutates the LIVE state actor directly, with a rollback
        // snapshot taken for the error path only. This matches the Rust port
        // (inmemory.rs `transaction`), which runs the block against the live
        // `Mutex<State>` and restores the snapshot only on error.
        //
        // WHY NOT run against a detached copy and replace-on-commit: a detached
        // copy + blind `replace(with: finalState)` on success silently DROPS any
        // non-transactional write (a bare `insert`) that commits to the live
        // actor between the snapshot and the replace — the replace overwrites the
        // whole state with the stale-snapshot-derived copy. That lost-update is
        // exactly how a rapid burst of QueueKit `send()` inserts (bare, per spec
        // §10) raced the encode drain's serializable claim transaction and lost
        // queued encode jobs (~5-10% under a 120-capture burst), leaving those
        // drawers un-ingested and BM25/vector-dark. Mutating live state preserves
        // concurrent inserts because both paths target the one actor.
        //
        // Notification isolation (SECFIX-WS2-PK F2): begin buffering BEFORE
        // taking the snapshot so that any notifications emitted by the block are
        // buffered and only flushed to observers after the block completes
        // successfully. On rollback, `rollback(to:)` discards the buffer.
        await stateActor.beginNotificationBuffering()
        let snapshot = await stateActor.snapshot()
        let txn = InMemoryTransaction(stateActor: stateActor)

        do {
            let result = try await block(txn)
            // Commit: flush buffered notifications to observers now that all
            // writes have been applied to the live state.
            await stateActor.commitNotifications()
            return result
        } catch {
            // Restore the pre-transaction snapshot and record the rollback so
            // StorageIntrospection can surface it. rollback(to:) also discards
            // the buffered notifications for this transaction.
            await stateActor.rollback(to: snapshot)
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
            capturedAt: now
        )
    }
}

// MARK: - In-memory state actor

actor InMemoryStateActor {
    var state: InMemoryState
    let observerRegistry: ObserverRegistry?

    // MARK: - Notification buffering (SECFIX-WS2-PK F2)
    //
    // During a transaction, row and blob notifications are buffered here rather
    // than delivered immediately. On commit they are flushed to observers in
    // order; on rollback they are discarded with the state snapshot. This
    // ensures observers never see phantom notifications for writes that were
    // rolled back (e.g. a failing InMemoryStorage.transaction block).

    /// True while a transaction's block is executing; writes buffer notifications.
    private var isBufferingNotifications: Bool = false
    /// Row change notifications accumulated during the current transaction.
    private var pendingRowNotifications: [TableChange] = []
    /// Blob change notifications accumulated during the current transaction.
    private var pendingBlobNotifications: [BlobChange] = []

    init(initial: InMemoryState = InMemoryState(), observerRegistry: ObserverRegistry? = nil) {
        self.state = initial
        self.observerRegistry = observerRegistry
    }

    /// Begin buffering notifications for the duration of a transaction.
    /// Called by `InMemoryStorage.transaction` before executing the block.
    func beginNotificationBuffering() {
        isBufferingNotifications = true
        pendingRowNotifications.removeAll()
        pendingBlobNotifications.removeAll()
    }

    /// Flush all buffered notifications to observers after a successful commit.
    /// Called by `InMemoryStorage.transaction` after the block returns without
    /// throwing.
    func commitNotifications() async {
        let rowNotifs = pendingRowNotifications
        let blobNotifs = pendingBlobNotifications
        isBufferingNotifications = false
        pendingRowNotifications.removeAll()
        pendingBlobNotifications.removeAll()
        guard let registry = observerRegistry else { return }
        for change in rowNotifs { await registry.notify(change) }
        for change in blobNotifs { await registry.notifyBlob(change) }
    }

    private func notify(_ change: TableChange) async {
        if isBufferingNotifications {
            pendingRowNotifications.append(change)
            return
        }
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
            // Idempotent (mirrors CREATE TABLE IF NOT EXISTS): the fresh-DB path
            // creates the table at the latest schema before replaying migrations
            // from version 0, so the column may already be present. Skip in that
            // case to avoid a duplicate column entry in the declaration.
            if t.declaration.columns.contains(where: { $0.name == column.name }) { break }
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

    func insertRow(
        table: String,
        values: [String: TypedValue],
        origin: ChangeOrigin = .local
    ) async throws -> RowHandle {
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
        // changedColumns for insert = all stored column names (every column in the
        // row is "new"). Passed through to ConvergenceKit for precision LWW stamping.
        await notify(TableChange(
            table: table, event: .insert, rowKey: key, values: stored, origin: origin,
            changedColumns: Set(stored.keys)
        ))
        return RowHandle(table: table, key: key)
    }

    func upsertRow(
        table: String,
        values: [String: TypedValue],
        conflictColumns: [String],
        origin: ChangeOrigin = .local
    ) async throws -> RowHandle {
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
            // changedColumns for upsert-as-update = columns whose value differs
            // between the pre-upsert row and the merged result.
            let changed = Set(merged.keys.filter { existingRow[$0] != merged[$0] })
            await notify(TableChange(
                table: table, event: .update, rowKey: existingKey, values: merged,
                origin: origin, changedColumns: changed
            ))
            return RowHandle(table: table, key: existingKey)
        }
        let key = resolveOrAllocateKey(table: t, values: values)
        let stored = Self.materializeGenerated(t.declaration, values)
        t.rows[key] = stored
        state.tables[table] = t
        // changedColumns for upsert-as-insert = all stored column names (new row).
        await notify(TableChange(
            table: table, event: .insert, rowKey: key, values: stored, origin: origin,
            changedColumns: Set(stored.keys)
        ))
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
            // changedColumns for update = columns whose value differs between the
            // pre-update row and the merged result. The pre-update `row` is
            // available here before the merge, so no extra read is needed.
            let changed = Set(merged.keys.filter { row[$0] != merged[$0] })
            notifications.append(TableChange(
                table: table, event: .update, rowKey: k, values: merged,
                changedColumns: changed
            ))
            count += 1
        }
        state.tables[table] = t
        for n in notifications { await notify(n) }
        return count
    }

    func deleteRows(
        table: String,
        where predicate: StoragePredicate,
        origin: ChangeOrigin = .local
    ) async throws -> Int {
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
            // changedColumns for delete = nil. Column-level information is not
            // meaningful on a tombstone; consumers use the rowKey only.
            notifications.append(TableChange(
                table: table, event: .delete, rowKey: k, values: row, origin: origin,
                changedColumns: nil
            ))
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
        offset: Int?,
        columns: [String]?
    ) throws -> [StorageRow] {
        guard let t = state.tables[table] else {
            throw StorageError.invalidQuery(detail: "query: table \(table) not found")
        }
        // Column projection (no-blob read): when `columns` is non-nil, keep
        // only those keys in each returned row so an unnamed column (e.g.
        // "content") is absent — mirroring the SQLite projected SELECT. nil
        // projects nothing away (the full row). Predicate evaluation and
        // ordering still see the full in-memory row; only the RETURNED row is
        // narrowed, after the predicate/sort, so a projected query can still
        // filter or order on an unprojected column.
        let projected: Set<String>? = columns.map(Set.init)
        // Match the full rows first so the predicate, ordering, and pagination
        // all see every column (SQLite's ORDER BY can reference a non-selected
        // column); projection is applied last, to the rows actually returned.
        var matched: [[String: TypedValue]] = []
        for (_, row) in t.rows {
            if predicate == nil || PredicateEvaluator.evaluate(predicate!, against: row) {
                matched.append(row)
            }
        }
        if !orderBy.isEmpty {
            matched.sort { lhs, rhs in
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
        if let off = offset, off > 0 { matched = Array(matched.dropFirst(off)) }
        if let lim = limit { matched = Array(matched.prefix(lim)) }
        return matched.map { row in
            guard let projected else { return StorageRow(values: row) }
            return StorageRow(values: row.filter { projected.contains($0.key) })
        }
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

    /// Resolve the internal `RowKey` for a row about to be written.
    ///
    /// Single-column PK only (composite/multi-column PKs fall through to the
    /// random-mint default below — unchanged, out of gap-5's scope). For a
    /// `.uuid`-typed PK, the value itself IS the key (unchanged fast path).
    /// For a `.text`-typed PK, gap 5: derive the key DETERMINISTICALLY from
    /// the PK's content via `RowKeyDerivation.deterministicRowKey(from:)`
    /// instead of minting a fresh random `UUID()`. Before this fix, two
    /// storage instances (e.g. two federation spokes) writing the same
    /// logical row (same `.text` PK value) resolved two unrelated random
    /// `RowKey`s, so ConvergenceKit's HLC-ordering gates — keyed by
    /// `RowKey` — compared against mismatched side-table entries and
    /// ordering silently degraded to pull-order instead of HLC-order. See
    /// `RowKeyDerivation.swift` for the full rationale and the sibling
    /// relationship to `Estate.deterministicUUID(from:)`.
    private func resolveOrAllocateKey(table: InMemoryTable, values: [String: TypedValue]) -> RowKey {
        if table.declaration.primaryKey.count == 1 {
            let pkName = table.declaration.primaryKey[0]
            if let pkValue = values[pkName] {
                if case .uuid(let u) = pkValue { return u }
                if case .text(let s) = pkValue { return RowKeyDerivation.deterministicRowKey(from: s) }
            }
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

    func putBlob(_ key: BlobKey, bytes: Data) async {
        state.blobs[key] = bytes
        // Buffer the notification when inside a transaction (SECFIX-WS2-PK F2).
        // Notify blob subscribers so the incremental replication session can
        // track which keys became dirty since the last sync run. Buffering
        // ensures rolled-back puts are never delivered to observers.
        let change = BlobChange(key: key, event: .put, bytes: bytes)
        if isBufferingNotifications {
            pendingBlobNotifications.append(change)
        } else if let registry = observerRegistry {
            await registry.notifyBlob(change)
        }
    }

    func getBlob(_ key: BlobKey) -> Data? { state.blobs[key] }

    func deleteBlob(_ key: BlobKey) async {
        state.blobs.removeValue(forKey: key)
        // Buffer the notification when inside a transaction (SECFIX-WS2-PK F2).
        // Mirrors the put path.
        let change = BlobChange(key: key, event: .delete, bytes: nil)
        if isBufferingNotifications {
            pendingBlobNotifications.append(change)
        } else if let registry = observerRegistry {
            await registry.notifyBlob(change)
        }
    }

    func blobExists(_ key: BlobKey) -> Bool { state.blobs[key] != nil }
    func blobSize(_ key: BlobKey) -> Int? { state.blobs[key]?.count }
    func listBlobKeys() -> [BlobKey] { Array(state.blobs.keys) }

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
    /// - transactionRollbackCount: incremented by InMemoryStorage.transaction()
    ///   on error. The actor tracks this as a monotone counter.
    func introspectionSnapshot() -> (rowCount: Int, blobCount: Int, rollbackCount: Int64, approxBytes: Int64) {
        let rows = state.tables.values.map { $0.rows.count }.reduce(0, +)
        let blobs = state.blobs.count
        // Approximate size: row overhead (256 B avg) + actual blob bytes.
        let blobBytes = state.blobs.values.map { Int64($0.count) }.reduce(0, +)
        let approxBytes = Int64(rows) * 256 + blobBytes
        return (rows, blobs, rollbackStats, approxBytes)
    }

    // Monotone rollback counter. Incremented by `rollback(to:)` when a
    // transaction's user block throws. Used to surface the
    // transactionRollbackCount field in StorageStats for callers that want to
    // track error rates.
    var rollbackStats: Int64 = 0

    /// Restore the pre-transaction snapshot and record the rollback.
    ///
    /// Called by `InMemoryStorage.transaction(isolation:_:)` on the error path:
    /// the block mutated the live state in place, so a throw must revert the
    /// whole state to its pre-transaction snapshot. Restoring the whole snapshot
    /// (rather than only the block's mutations) matches the Rust port's
    /// single-threaded transaction semantics.
    ///
    /// Also discards all buffered notifications from the rolled-back transaction
    /// (SECFIX-WS2-PK F2): observers must never see phantom changes for writes
    /// that were rolled back.
    func rollback(to snapshot: InMemoryState) {
        state = snapshot
        rollbackStats += 1
        // Discard buffered notifications — the writes they describe were rolled back.
        isBufferingNotifications = false
        pendingRowNotifications.removeAll()
        pendingBlobNotifications.removeAll()
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
    var auditEvents: [AuditEventRecord] = []
}

struct InMemoryTable: Sendable {
    var declaration: TableDeclaration
    var rows: [RowKey: [String: TypedValue]] = [:]
}

struct AuditEventRecord: Sendable {
    let event: AuditEvent
    var key: String { "\(event.eventID.uuidString):\(event.hlc.packed)" }
}

// MARK: - Transaction

final class InMemoryTransaction: StorageTransaction, Sendable {
    let rowStore: any RowStore
    let blobStore: any BlobStore
    let auditLog: any AuditLog

    init(stateActor: InMemoryStateActor) {
        self.rowStore = InMemoryRowStore(stateActor: stateActor)
        self.blobStore = InMemoryBlobStore(stateActor: stateActor)
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

// MARK: - StorageMaintenance (shared-content 1.1 P5)

extension InMemoryStorage: StorageMaintenance {
    /// The in-memory backend has no page model and no on-disk footprint:
    /// nothing is ever reclaimable.
    public func estimatedReclaimableBytes() async throws -> Int64 { 0 }

    /// Explicit no-op (per the StorageMaintenance backend table). The report
    /// says `performed: false` so callers can distinguish "ran and freed
    /// nothing" from "nothing to run".
    public func performMaintenance(
        progress: (@Sendable (StorageMaintenanceProgress) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) async throws -> StorageMaintenanceReport {
        .noOp(backend: "inmemory",
              note: "in-memory backend holds no pages; nothing to reclaim")
    }
}
