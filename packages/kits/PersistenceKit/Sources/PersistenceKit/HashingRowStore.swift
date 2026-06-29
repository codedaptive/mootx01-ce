// HashingRowStore.swift
//
// Decorator that intercepts RowStore writes (insert, update, upsert)
// and computes a ContentHash for rows in hashable tables. Emits a
// DirtyChainEvent carrying the three-identifier Merkle containment
// chain so downstream consumers (Merkle rollup, cache invalidation)
// can incrementally re-root without a full-tree scan.
//
// PersistenceKit does not depend on SubstrateLib or SubstrateKernel.
// The hash function is a callback (`ContentHashProvider`) injected at
// construction time — the consuming kit (e.g. LocusKit) imports
// SubstrateLib and supplies `MerkleHash.leaf` or an accelerated kernel
// dispatch. This keeps PersistenceKit kernel-agnostic: the accelerated
// SHA-256 path (CryptoKit on Apple, sha2 on Rust) lives in the callback
// supplier, not here (ADR-017 §16 / NT-P2 Part 3).
//
// Decorator chain: caller → HashingRowStore → CachingRowStore → backend.

import Foundation
import OSLog
import SubstrateTypes

private let hashLogger = Logger(subsystem: "com.mootx01.kit", category: "HashingRowStore")

/// Callback that computes a ContentHash for a row's values.
///
/// The supplier (typically LocusKit) imports SubstrateLib and calls
/// `MerkleHash.leaf` or an accelerated kernel variant. PersistenceKit
/// stores the result and emits a `DirtyChainEvent` — it never imports
/// a hash implementation directly.
///
/// - Parameters:
///   - table: The table name the row belongs to.
///   - rowKey: The primary key of the row being written.
///   - values: The row's column values at the point of write.
/// - Returns: The computed ContentHash for the row.
public typealias ContentHashProvider = @Sendable (
    _ table: String,
    _ rowKey: RowKey,
    _ values: [String: TypedValue]
) -> ContentHash

/// Callback that returns the Merkle containment parent chain for a row.
///
/// Returns `(parentNodeId, grandparentNodeId)` — the two ancestor IDs
/// needed for dirty-chain propagation. The consuming kit owns the
/// containment hierarchy; PersistenceKit just forwards the IDs in the
/// `DirtyChainEvent`. Returns nil when the row has no parent chain
/// (e.g. a root node or a table without Merkle rollup).
public typealias HashParentChainProvider = @Sendable (
    _ table: String,
    _ rowKey: RowKey
) -> (parentNodeId: UUID, grandparentNodeId: UUID)?

/// Configuration for the hash-on-write hook.
public struct HashOnWriteConfig: Sendable {
    /// The set of table names marked hashable in the schema.
    /// Populated from `SchemaDeclaration` at `open(schema:)` time.
    public let hashableTables: Set<String>
    /// Computes a ContentHash for a row's values.
    public let hashProvider: ContentHashProvider
    /// Returns the Merkle containment parent chain for a row.
    public let parentChainProvider: HashParentChainProvider

    public init(
        hashableTables: Set<String>,
        hashProvider: @escaping ContentHashProvider,
        parentChainProvider: @escaping HashParentChainProvider
    ) {
        self.hashableTables = hashableTables
        self.hashProvider = hashProvider
        self.parentChainProvider = parentChainProvider
    }
}

/// A `RowStore` decorator that intercepts writes to hashable tables,
/// computes a ContentHash via a caller-supplied callback, and emits
/// `DirtyChainEvent` notifications to registered observers.
///
/// Writes to non-hashable tables pass through unmodified.
/// Read operations (query, count) delegate directly to the backing store.
public final class HashingRowStore: RowStore, @unchecked Sendable {
    private let backing: any RowStore
    private let config: HashOnWriteConfig
    private let observerRegistry: ObserverRegistryRef?

    /// Reference to the observer registry for dirty-chain event delivery.
    /// Weakly typed to avoid circular module dependencies — the
    /// InMemory observer registry is the only live implementation.
    /// When nil, dirty-chain events are computed but not delivered
    /// (useful for backends without observer support, e.g. SQLite).
    public typealias ObserverRegistryRef = @Sendable (DirtyChainEvent) async -> Void

    /// Designated initialiser.
    ///
    /// - Parameters:
    ///   - backing: The `RowStore` to wrap (typically a `CachingRowStore`
    ///     or a raw backend).
    ///   - config: Hash-on-write configuration with hashable table set,
    ///     hash provider callback, and parent chain provider callback.
    ///   - dirtyChainSink: Optional async closure that delivers
    ///     `DirtyChainEvent` to observers. Pass the InMemory observer
    ///     registry's `notifyDirtyChain` method. Pass nil for backends
    ///     that don't support observation.
    public init(
        backing: any RowStore,
        config: HashOnWriteConfig,
        dirtyChainSink: ObserverRegistryRef? = nil
    ) {
        self.backing = backing
        self.config = config
        self.observerRegistry = dirtyChainSink
    }

    // MARK: - Write interception
    //
    // Hash computation is synchronous with the write: the hash is computed
    // BEFORE the row is committed, then merged into the values dict as a
    // `content_hash` column. The backing store receives the augmented values
    // in a single write — no window between row commit and hash storage.

    public func insert(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        let augmented = augmentWithHash(table: table, values: values)
        let handle = try await backing.insert(table: table, values: augmented.values)
        if let hashResult = augmented.hashResult {
            await emitDirtyChain(table: table, rowKey: handle.key, hashResult: hashResult)
        }
        return handle
    }

    @discardableResult
    public func upsert(
        table: String,
        values: [String: TypedValue],
        conflictColumns: [String]
    ) async throws -> RowHandle {
        // For hashable tables, detect whether this upsert will hit an existing
        // row (update path) or insert a new row. If it's an update, hash the
        // full committed row (current columns merged with incoming values) rather
        // than just the incoming values dict, which omits unchanged columns
        // (SECFIX-WS2-PK F6).
        //
        // The conflict column is typically "id" (UUID primary key). We build a
        // point-lookup predicate from the first conflict column value to find
        // the existing row; if found, merge and hash from the merged state.
        if config.hashableTables.contains(table),
           let firstConflictCol = conflictColumns.first,
           let conflictValue = values[firstConflictCol],
           case .uuid(let rowKey) = conflictValue {
            let eqPred = StoragePredicate.eq(Column(table: table, name: firstConflictCol), conflictValue)
            let existing = try await backing.query(
                table: table, where: eqPred, orderBy: [], limit: 1, offset: nil)
            if let currentRow = existing.first {
                // Upsert resolves to an update: merge incoming values over current row.
                var merged = currentRow.values
                for (k, v) in values { merged[k] = v }
                let augmented = augmentWithHashForKnownKey(table: table, rowKey: rowKey, mergedValues: merged)
                let handle = try await backing.upsert(
                    table: table, values: augmented.values, conflictColumns: conflictColumns)
                if let hashResult = augmented.hashResult {
                    await emitDirtyChain(table: table, rowKey: handle.key, hashResult: hashResult)
                }
                return handle
            }
        }
        // Insert path (no existing row) or non-hashable table: incoming values
        // IS the full row, so the existing augment logic is correct.
        let augmented = augmentWithHash(table: table, values: values)
        let handle = try await backing.upsert(
            table: table, values: augmented.values, conflictColumns: conflictColumns)
        if let hashResult = augmented.hashResult {
            await emitDirtyChain(table: table, rowKey: handle.key, hashResult: hashResult)
        }
        return handle
    }

    @discardableResult
    public func update(
        table: String,
        values: [String: TypedValue],
        where predicate: StoragePredicate
    ) async throws -> Int {
        // For hashable tables with a single-row UUID predicate, hash the full
        // committed row (current columns merged with the SET values) rather than
        // just the partial SET-column dict (SECFIX-WS2-PK F6). Without pre-reading,
        // the hash omits all unchanged columns, producing a hash for a partial
        // row that diverges from the actual committed row state.
        //
        // Batch updates (no single-row UUID predicate) still use the existing
        // augment path: the consuming kit is responsible for re-hashing affected
        // rows (consistent with CachingRowStore's batch-invalidation model).
        if config.hashableTables.contains(table),
           let rowKey = extractSingleRowKey(from: predicate) {
            let existing = try await backing.query(
                table: table, where: predicate, orderBy: [], limit: 1, offset: nil)
            if let currentRow = existing.first {
                var merged = currentRow.values
                for (k, v) in values { merged[k] = v }
                let augmented = augmentWithHashForKnownKey(table: table, rowKey: rowKey, mergedValues: merged)
                let count = try await backing.update(
                    table: table, values: augmented.values, where: predicate)
                if count > 0, let hashResult = augmented.hashResult {
                    await emitDirtyChain(table: table, rowKey: rowKey, hashResult: hashResult)
                }
                return count
            }
        }
        // Non-hashable table or batch update (no single UUID key).
        let augmented = augmentWithHash(table: table, values: values)
        let count = try await backing.update(
            table: table, values: augmented.values, where: predicate)
        // For single-row updates via UUID predicate, extract key and emit.
        // Batch updates skip the dirty-chain event — the consuming kit is
        // responsible for re-hashing affected rows (consistent with
        // CachingRowStore's invalidation model for batch updates).
        if count > 0, let hashResult = augmented.hashResult,
           let rowKey = extractSingleRowKey(from: predicate) {
            await emitDirtyChain(table: table, rowKey: rowKey, hashResult: hashResult)
        }
        return count
    }

    // MARK: - Read pass-through

    public func delete(table: String, where predicate: StoragePredicate) async throws -> Int {
        try await backing.delete(table: table, where: predicate)
    }

    public func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?
    ) async throws -> [StorageRow] {
        try await backing.query(
            table: table, where: predicate,
            orderBy: orderBy, limit: limit, offset: offset)
    }

    public func count(table: String, where predicate: StoragePredicate?) async throws -> Int {
        try await backing.count(table: table, where: predicate)
    }

    public func querySkipCorrupt(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> (rows: [StorageRow], skipped: Int) {
        try await backing.querySkipCorrupt(
            table: table, where: predicate,
            orderBy: orderBy, limit: limit, offset: offset,
            columns: columns)
    }

    public func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> [StorageRow] {
        try await backing.query(
            table: table, where: predicate,
            orderBy: orderBy, limit: limit, offset: offset,
            columns: columns)
    }

    // MARK: - Internal

    /// Pre-write result: augmented values and optional hash for event emission.
    private struct AugmentResult {
        let values: [String: TypedValue]
        let hashResult: HashResult?
    }

    /// Hash computation result carried from augment to emit.
    private struct HashResult {
        let contentHash: ContentHash
        let parentChain: (parentNodeId: UUID, grandparentNodeId: UUID)
    }

    /// Computes a content hash for a hashable table row where the row key is
    /// already known (from a predicate or conflict-column lookup). Used by
    /// `update` and `upsert` on the update path, where `mergedValues` is the
    /// full committed row state after applying SET / incoming values.
    ///
    /// Unlike `augmentWithHash`, this variant does not extract the row key from
    /// the values dict — the caller supplies it directly, allowing correct hash
    /// computation even when the incoming values dict omits the "id" column
    /// (e.g. a partial SET dict in an UPDATE statement).
    private func augmentWithHashForKnownKey(
        table: String,
        rowKey: RowKey,
        mergedValues: [String: TypedValue]
    ) -> AugmentResult {
        guard config.hashableTables.contains(table) else {
            return AugmentResult(values: mergedValues, hashResult: nil)
        }
        // Strip the existing `content_hash` from the input before computing the
        // new hash. The INSERT path (`augmentWithHash`) calls hashProvider with
        // values that do NOT yet include `content_hash` (it is added afterwards).
        // Stripping here ensures the hash function always receives the same
        // column set — the row's data columns — regardless of whether this is an
        // insert or an update/upsert. Without this strip, the UPDATE path would
        // hash the old `content_hash` column value along with the data columns,
        // producing a result that diverges from what the INSERT path would
        // compute for identical data (SECFIX-WS2-PK F6 consistency).
        var hashInput = mergedValues
        hashInput.removeValue(forKey: "content_hash")
        let contentHash = config.hashProvider(table, rowKey, hashInput)
        var augmented = mergedValues
        augmented["content_hash"] = .blob(Data(contentHash.bytes))
        guard let chain = config.parentChainProvider(table, rowKey) else {
            hashLogger.debug("Hash-on-write: no parent chain for \(table)/\(rowKey)")
            return AugmentResult(values: augmented, hashResult: nil)
        }
        return AugmentResult(
            values: augmented,
            hashResult: HashResult(contentHash: contentHash, parentChain: chain)
        )
    }

    /// Computes the content hash for hashable tables and merges the
    /// `content_hash` column into the values dict. Non-hashable tables
    /// return the original values unchanged.
    private func augmentWithHash(
        table: String,
        values: [String: TypedValue]
    ) -> AugmentResult {
        guard config.hashableTables.contains(table) else {
            return AugmentResult(values: values, hashResult: nil)
        }

        // Extract the row key from the values dict — the "id" column
        // by convention, which is always a UUID primary key.
        let rowKey: RowKey
        if let idValue = values["id"], case .uuid(let uuid) = idValue {
            rowKey = uuid
        } else {
            hashLogger.warning("Hash-on-write: hashable table \(table) row missing UUID 'id' column")
            return AugmentResult(values: values, hashResult: nil)
        }

        let contentHash = config.hashProvider(table, rowKey, values)

        // Merge the content_hash column into the row values.
        var augmented = values
        augmented["content_hash"] = .blob(Data(contentHash.bytes))

        guard let chain = config.parentChainProvider(table, rowKey) else {
            hashLogger.debug("Hash-on-write: no parent chain for \(table)/\(rowKey)")
            return AugmentResult(
                values: augmented,
                hashResult: nil
            )
        }

        return AugmentResult(
            values: augmented,
            hashResult: HashResult(contentHash: contentHash, parentChain: chain)
        )
    }

    /// Emits a dirty-chain event to registered observers.
    private func emitDirtyChain(
        table: String,
        rowKey: RowKey,
        hashResult: HashResult
    ) async {
        let event = DirtyChainEvent(
            changedRowId: rowKey,
            parentNodeId: hashResult.parentChain.parentNodeId,
            grandparentNodeId: hashResult.parentChain.grandparentNodeId,
            contentHash: hashResult.contentHash,
            table: table
        )
        await observerRegistry?(event)
    }

    /// Extracts a single UUID row key from an equality predicate.
    /// Returns nil for compound/range predicates (batch updates skip
    /// the hash-on-write hook).
    private func extractSingleRowKey(from predicate: StoragePredicate) -> RowKey? {
        if case .eq(_, let value) = predicate,
           case .uuid(let uuid) = value {
            return uuid
        }
        return nil
    }
}
