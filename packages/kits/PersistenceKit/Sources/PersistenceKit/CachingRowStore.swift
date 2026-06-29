// CachingRowStore.swift
//
// Cache decorator for any `RowStore`. Wraps a backing store and serves
// frequently-accessed rows from an in-memory hot tier.
//
// Cache key: (table, UUID key, AsOfCoordinate). A present read and an
// as-of snapshot read of the same row are distinct cache entries per
// ADR-017 §18. Snapshot reads (.asOf(hlc)) against pinned immutable
// views are safely cacheable because the GC pin (NT-P3) prevents
// vacuum of pinned rows. Present reads remain invalidation-driven.
//
// Parent-chain callback: when a write mutates a hashable row, the
// optional parentChainProvider returns the Merkle-aggregate parent
// chain (e.g. drawer→room→wing). CachingRowStore evicts cached
// aggregates for every node in the chain.
//
// Sensitivity gate: rows whose `provenance` column encodes a sensitivity
// level above the configured threshold — or equal to Secret (ordinal 3) —
// are never admitted. If `provenance` is absent the row caches normally.
// If `provenance` is present but unparseable, or uses an unrecognised bit
// pattern, the row is rejected (fail closed).
//
// The sensitivity encoding follows the provenance bitmap spec (cookbook §2.5 v0.6):
//   field = (raw_int64 >> 30) & 0x3F   (6-bit field in bits [35:30])
//   raw 0 = Normal, 16 = Elevated, 32 = Restricted, 48 = Secret (scale-gapped)
// EstateCacheConfig.sensitivityThreshold stores an ordinal (0=Normal, 1=Elevated,
// 2=Restricted); the gate maps scale-gapped raw values to ordinals before comparing.
//
// LRU eviction fires when the estimated hot-tier byte size exceeds
// `config.ceilingBytes`. A ceiling of 0 means no limit.
//
// Transparency guarantee: every operation returns results identical to the
// unwrapped backing store. The cache only affects latency.

import Foundation
import OSLog
import SubstrateTypes

private let cacheLogger = Logger(subsystem: "com.mootx01.kit", category: "CachingRowStore")

/// Callback that maps a changed row to its Merkle-aggregate parent chain.
/// Returns RowHandles for each ancestor whose cached aggregate must be
/// invalidated (e.g. [room, wing, estate]). Returns nil or empty when no
/// chain invalidation is needed. PersistenceKit does not know the tree
/// shape — the consuming kit supplies this callback at construction time.
public typealias ParentChainProvider = @Sendable (String, RowKey) -> [RowHandle]

/// A `RowStore` decorator that adds an in-memory LRU hot tier with
/// sensitivity-gated admission. Wraps any conforming `RowStore`.
///
/// Pass `config: .disabled` for a zero-overhead transparent passthrough.
public final class CachingRowStore: RowStore, Sendable {
    private let backing: any RowStore
    private let config: EstateCacheConfig
    private let parentChainProvider: ParentChainProvider?
    // All mutable hot-tier state lives in the actor; the final class is
    // therefore Sendable (all stored properties are themselves Sendable).
    private let cache: CacheActor

    /// Designated initialiser.
    ///
    /// - Parameters:
    ///   - backing: The `RowStore` to wrap.
    ///   - config:  Cache configuration. Pass `.disabled` to make this
    ///              decorator a transparent pass-through.
    ///   - parentChainProvider: Optional callback that returns the
    ///     Merkle-aggregate parent chain for a changed row. When set,
    ///     writes evict cached aggregates for every node in the chain.
    ///     Pass nil for tables without Merkle rollup.
    public init(
        backing: any RowStore,
        config: EstateCacheConfig,
        parentChainProvider: ParentChainProvider? = nil
    ) {
        self.backing = backing
        self.config = config
        self.parentChainProvider = parentChainProvider
        self.cache = CacheActor(config: config)
    }

    // MARK: — RowStore conformance

    public func insert(
        table: String,
        values: [String: TypedValue]
    ) async throws -> RowHandle {
        let handle = try await backing.insert(table: table, values: values)
        if config.enabled {
            await invalidateParentChain(table: table, key: handle.key)
        }
        return handle
    }

    public func upsert(
        table: String,
        values: [String: TypedValue],
        conflictColumns: [String]
    ) async throws -> RowHandle {
        let handle = try await backing.upsert(
            table: table, values: values, conflictColumns: conflictColumns
        )
        if config.enabled {
            await cache.evictPresent(RowHandle(table: table, key: handle.key))
            await invalidateParentChain(table: table, key: handle.key)
        }
        return handle
    }

    public func update(
        table: String,
        values: [String: TypedValue],
        where predicate: StoragePredicate
    ) async throws -> Int {
        let count = try await backing.update(
            table: table, values: values, where: predicate
        )
        if config.enabled, count > 0 {
            if let key = extractKey(from: predicate) {
                await cache.evictPresent(RowHandle(table: table, key: key))
                await invalidateParentChain(table: table, key: key)
            } else {
                await cache.evictAllPresent(table: table)
            }
        }
        return count
    }

    public func delete(
        table: String,
        where predicate: StoragePredicate
    ) async throws -> Int {
        let count = try await backing.delete(table: table, where: predicate)
        if config.enabled, count > 0 {
            if let key = extractKey(from: predicate) {
                await cache.evictPresent(RowHandle(table: table, key: key))
                await invalidateParentChain(table: table, key: key)
            } else {
                await cache.evictAllPresent(table: table)
            }
        }
        return count
    }

    public func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?
    ) async throws -> [StorageRow] {
        try await temporalQuery(
            table: table, predicate: predicate,
            orderBy: orderBy, limit: limit, offset: offset,
            asOf: .present
        )
    }

    // MARK: — Temporal query (ADR-017 §18)

    /// Temporal query with cache isolation by AsOfCoordinate. A present
    /// read and an as-of snapshot read of the same row are distinct cache
    /// entries. Snapshot reads are never evicted by writes because the
    /// pinned snapshot data is immutable.
    public func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        asOf: AsOfCoordinate?
    ) async throws -> [StorageRow] {
        let coordinate = asOf ?? .present
        return try await temporalQuery(
            table: table, predicate: predicate,
            orderBy: orderBy, limit: limit, offset: offset,
            asOf: coordinate
        )
    }

    public func count(
        table: String,
        where predicate: StoragePredicate?
    ) async throws -> Int {
        try await backing.count(table: table, where: predicate)
    }

    // MARK: — Transaction boundary (GLK_BATCH1)

    /// Open a write transaction on the backing store.
    ///
    /// Explicitly delegates to `backing.beginTransaction()` rather than
    /// relying on the `RowStore` protocol's no-op default. Live GLK estates
    /// wrap `SQLiteRowStore` in a `CachingRowStore`; the no-op default would
    /// silently swallow the transaction boundary, defeating the batch API.
    public func beginTransaction() async throws {
        try await backing.beginTransaction()
    }

    /// Commit the current transaction on the backing store.
    public func commitTransaction() async throws {
        try await backing.commitTransaction()
    }

    /// Roll back the current transaction on the backing store.
    public func rollbackTransaction() async throws {
        try await backing.rollbackTransaction()
    }

    // MARK: — External invalidation

    /// Invalidate cached present-read entries. Called by `CacheInvalidator`
    /// when an external write arrives via `StorageObserver`. Pass `key: nil`
    /// when the change has no specific row identity (e.g. a bulk update) to
    /// evict all present entries for the table.
    ///
    /// Snapshot-read entries (.asOf(hlc)) are never evicted because the
    /// pinned snapshot data is immutable — the GC pin prevents vacuum.
    public func invalidate(table: String, key: RowKey?) async {
        guard config.enabled else { return }
        if let key {
            await cache.evictPresent(RowHandle(table: table, key: key))
            await invalidateParentChain(table: table, key: key)
        } else {
            await cache.evictAllPresent(table: table)
        }
    }

    // MARK: — Internal query logic

    /// Shared implementation for both present and as-of queries with
    /// temporal cache key isolation.
    private func temporalQuery(
        table: String,
        predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        asOf: AsOfCoordinate
    ) async throws -> [StorageRow] {
        // Cache lookups are only feasible for single-key UUID equality queries.
        if config.enabled, let key = extractKey(from: predicate) {
            let handle = RowHandle(table: table, key: key)
            let cacheKey = TemporalCacheKey(handle: handle, asOf: asOf)
            if let cached = await cache.get(cacheKey) {
                cacheLogger.debug("hit \(table)/\(key.uuidString)/\(String(describing: asOf))")
                return [cached]
            }
            // Cache miss: execute the temporal query against the backing store.
            let rows: [StorageRow]
            switch asOf {
            case .present:
                rows = try await backing.query(
                    table: table, where: predicate,
                    orderBy: orderBy, limit: limit, offset: offset
                )
            case .asOf:
                rows = try await backing.query(
                    table: table, where: predicate,
                    orderBy: orderBy, limit: limit, offset: offset,
                    asOf: asOf
                )
            }
            if rows.count == 1 {
                await cache.admit(key: cacheKey, row: rows[0])
            }
            return rows
        }
        // All other predicates pass through; no query-result caching.
        switch asOf {
        case .present:
            return try await backing.query(
                table: table, where: predicate,
                orderBy: orderBy, limit: limit, offset: offset
            )
        case .asOf:
            return try await backing.query(
                table: table, where: predicate,
                orderBy: orderBy, limit: limit, offset: offset,
                asOf: asOf
            )
        }
    }

    // MARK: — Parent-chain invalidation

    /// Evict cached Merkle-aggregate entries for every node in the
    /// parent chain of the changed row. The chain is supplied by the
    /// kit-registered callback; if no callback is registered, this
    /// is a no-op (backward-compatible for non-Merkle tables).
    private func invalidateParentChain(table: String, key: RowKey) async {
        guard let provider = parentChainProvider else { return }
        let chain = provider(table, key)
        for parentHandle in chain {
            await cache.evictPresent(parentHandle)
        }
    }

    // MARK: — Helpers

    /// Extract a `RowKey` UUID from `.eq(_, .uuid(key))` predicates.
    /// Returns `nil` for any other predicate shape.
    private func extractKey(from predicate: StoragePredicate?) -> RowKey? {
        guard let predicate else { return nil }
        if case .eq(_, let value) = predicate, case .uuid(let uuid) = value {
            return uuid
        }
        return nil
    }
}

// MARK: — Temporal cache key

/// Internal key type that adds the temporal coordinate to a RowHandle.
/// A present read and an as-of snapshot read of the same row produce
/// distinct keys, so they occupy separate cache entries.
private struct TemporalCacheKey: Hashable, Sendable {
    let handle: RowHandle
    let asOf: AsOfCoordinate

    init(handle: RowHandle, asOf: AsOfCoordinate) {
        self.handle = handle
        self.asOf = asOf
    }
}

// MARK: — Cache actor

/// Actor that owns all mutable hot-tier state: the entry dictionary,
/// the LRU access counter, and the running byte total.
///
/// Using an actor for the mutable state makes `CachingRowStore` Sendable
/// (a final class with all-Sendable stored properties) under Swift 6 strict
/// concurrency without any manual locking.
private actor CacheActor {
    struct Entry {
        let row: StorageRow
        var accessOrder: Int   // higher = more recently accessed
        let byteSize: Int
    }

    let config: EstateCacheConfig
    var entries: [TemporalCacheKey: Entry] = [:]
    var accessCounter: Int = 0
    var totalBytes: Int = 0

    init(config: EstateCacheConfig) {
        self.config = config
    }

    // MARK: — Public interface (called from CachingRowStore via await)

    /// Return the cached row for `key`, refreshing its LRU position.
    func get(_ key: TemporalCacheKey) -> StorageRow? {
        guard var entry = entries[key] else { return nil }
        accessCounter += 1
        entry.accessOrder = accessCounter
        entries[key] = entry
        return entry.row
    }

    /// Admit `row` under `key` if it passes the sensitivity gate and the
    /// byte budget allows it. Evicts LRU entries as needed to make room.
    func admit(key: TemporalCacheKey, row: StorageRow) {
        guard config.enabled else { return }
        guard isAdmissible(row) else { return }
        let size = estimatedBytes(row)
        if let existing = entries[key] {
            totalBytes -= existing.byteSize
            entries.removeValue(forKey: key)
        }
        // When ceilingBytes > 0 evict LRU entries until the new row fits.
        // ceilingBytes == 0 means no limit (enabled=false is guarded above).
        if config.ceilingBytes > 0 {
            while !entries.isEmpty, totalBytes + size > config.ceilingBytes {
                evictLRU()
            }
            guard totalBytes + size <= config.ceilingBytes else { return }
        }
        accessCounter += 1
        entries[key] = Entry(row: row, accessOrder: accessCounter, byteSize: size)
        totalBytes += size
    }

    /// Remove the present-read entry for `handle`. Snapshot entries
    /// (.asOf(hlc)) are left intact because pinned snapshot data is
    /// immutable — writes cannot invalidate them.
    func evictPresent(_ handle: RowHandle) {
        let key = TemporalCacheKey(handle: handle, asOf: .present)
        if let entry = entries.removeValue(forKey: key) {
            totalBytes -= entry.byteSize
        }
    }

    /// Remove all present-read entries whose table matches. Snapshot
    /// entries are left intact.
    func evictAllPresent(table: String) {
        let toRemove = entries.keys.filter {
            $0.handle.table == table && $0.asOf == .present
        }
        for key in toRemove {
            if let entry = entries.removeValue(forKey: key) {
                totalBytes -= entry.byteSize
            }
        }
    }

    // MARK: — Sensitivity gate

    /// Returns `true` when `row` is eligible for the hot tier.
    ///
    /// Sensitivity is encoded in the `provenance` bitmap at bits 30–35 (6-bit
    /// field, scale-gapped per cookbook §2.5 v0.6). The gate converts the raw
    /// field value to an ordinal (0–3) and compares it against the config
    /// threshold, which is also expressed as an ordinal.
    ///
    ///   - Column absent              → admit (no sensitivity constraint)
    ///   - ordinal > threshold        → reject
    ///   - ordinal == 3 (Secret)      → reject always regardless of threshold
    ///   - Unrecognised bit pattern   → reject (fail closed)
    ///   - Unparseable value type     → reject (fail closed)
    private func isAdmissible(_ row: StorageRow) -> Bool {
        guard let provenanceValue = row["provenance"] else { return true }
        let raw: Int64
        switch provenanceValue {
        case .int(let i):    raw = i
        case .bitmap(let i): raw = i
        default:             return false   // fail closed on unrecognised type
        }
        // Sensitivity at capture lives in bits 30–35 of the provenance bitmap
        // (6-bit field, scale-gapped: 0/16/32/48 per cookbook §2.5 v0.6).
        let rawField = Int((raw >> 30) & 0x3F)
        let ordinal: Int
        switch rawField {
        case 0:  ordinal = 0  // Normal
        case 16: ordinal = 1  // Elevated
        case 32: ordinal = 2  // Restricted
        case 48: ordinal = 3  // Secret
        default: return false // Unrecognised bit pattern → fail closed
        }
        // Hard Secret exclusion is defence-in-depth: threshold is already
        // clamped to ≤2 by EstateCacheConfig, but this guard remains correct
        // even if the clamp were ever bypassed.
        if ordinal == 3 { return false }
        return ordinal <= config.sensitivityThreshold
    }

    // MARK: — Byte estimation

    /// Conservative estimate of the in-memory footprint of one `row`. Used
    /// only for eviction budget decisions — intentional over-estimation is safe.
    private func estimatedBytes(_ row: StorageRow) -> Int {
        var size = 64   // per-entry overhead: RowHandle, Entry struct, dict bucket
        for (key, value) in row.values {
            size += key.utf8.count + 8
            size += estimatedValueBytes(value)
        }
        return size
    }

    private func estimatedValueBytes(_ value: TypedValue) -> Int {
        switch value {
        case .null:            return 8
        case .bool:            return 8
        case .int, .bitmap:    return 16
        case .float:           return 16
        case .text(let s):     return s.utf8.count + 16
        case .blob(let d):     return d.count + 16
        case .uuid:            return 24
        case .timestamp:       return 24
        case .json(let d):     return d.count + 16
        case .hlc:             return 24
        case .fingerprint:     return 40
        case .array(let arr):  return arr.reduce(16) { $0 + estimatedValueBytes($1) }
        }
    }

    // MARK: — LRU eviction

    /// Evict the least-recently-used entry (smallest `accessOrder`).
    /// O(n) over the entry count; acceptable for cache sizes bounded by
    /// `ceilingBytes` (typically megabytes with many-kilobyte rows).
    private func evictLRU() {
        guard let lruKey = entries.min(by: { $0.value.accessOrder < $1.value.accessOrder })?.key else {
            return
        }
        if let entry = entries.removeValue(forKey: lruKey) {
            totalBytes -= entry.byteSize
        }
    }
}
