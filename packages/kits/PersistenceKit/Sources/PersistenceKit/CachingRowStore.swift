// CachingRowStore.swift
//
// Cache decorator for any `RowStore`. Wraps a backing store and serves
// frequently-accessed rows from an in-memory hot tier keyed by `RowHandle`.
//
// Sensitivity gate: rows whose `provenance` column encodes a sensitivity
// level above the configured threshold — or equal to Secret (level 3) —
// are never admitted. If `provenance` is absent the row caches normally.
// If `provenance` is present but unparseable the row is rejected (fail closed).
//
// The sensitivity encoding follows the ARIA adjective contract:
//   level = (raw_int64 >> 4) & 0x7   (3-bit field in bits [6:4])
//   0 = Normal, 1 = Elevated, 2 = Restricted, 3 = Secret
//
// LRU eviction fires when the estimated hot-tier byte size exceeds
// `config.ceilingBytes`. A ceiling of 0 means no limit.
//
// Transparency guarantee: every operation returns results identical to the
// unwrapped backing store. The cache only affects latency.

import Foundation
import OSLog

private let cacheLogger = Logger(subsystem: "com.mootx01.kit", category: "CachingRowStore")

/// A `RowStore` decorator that adds an in-memory LRU hot tier with
/// sensitivity-gated admission. Wraps any conforming `RowStore`.
///
/// Pass `config: .disabled` for a zero-overhead transparent passthrough.
public final class CachingRowStore: RowStore, Sendable {
    private let backing: any RowStore
    private let config: EstateCacheConfig
    // All mutable hot-tier state lives in the actor; the final class is
    // therefore Sendable (all stored properties are themselves Sendable).
    private let cache: CacheActor

    /// Designated initialiser.
    ///
    /// - Parameters:
    ///   - backing: The `RowStore` to wrap.
    ///   - config:  Cache configuration. Pass `.disabled` to make this
    ///              decorator a transparent pass-through.
    public init(backing: any RowStore, config: EstateCacheConfig) {
        self.backing = backing
        self.config = config
        self.cache = CacheActor(config: config)
    }

    // MARK: — RowStore conformance

    public func insert(
        table: String,
        values: [String: TypedValue]
    ) async throws -> RowHandle {
        // Insert always goes to the backing store. The returned handle is new,
        // so there is no prior cache entry to invalidate.
        try await backing.insert(table: table, values: values)
    }

    public func upsert(
        table: String,
        values: [String: TypedValue],
        conflictColumns: [String]
    ) async throws -> RowHandle {
        let handle = try await backing.upsert(
            table: table, values: values, conflictColumns: conflictColumns
        )
        // Upsert may have updated an existing cached row; invalidate so the
        // next read falls through to the backing store and gets fresh data.
        if config.enabled {
            await cache.evict(handle)
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
            // Narrow invalidation when the predicate identifies a single row;
            // fall back to full table eviction for complex predicates.
            if let key = extractKey(from: predicate) {
                await cache.evict(RowHandle(table: table, key: key))
            } else {
                await cache.evictAll(table: table)
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
                await cache.evict(RowHandle(table: table, key: key))
            } else {
                await cache.evictAll(table: table)
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
        // Cache lookups are only feasible for single-key UUID equality queries.
        // A UUID equality predicate matches at most one row, so pagination
        // constraints do not change the set of matching rows.
        if config.enabled, let key = extractKey(from: predicate) {
            let handle = RowHandle(table: table, key: key)
            if let cached = await cache.get(handle) {
                cacheLogger.debug("hit \(table)/\(key.uuidString)")
                return [cached]
            }
            // Cache miss: execute the query and populate the hot tier.
            let rows = try await backing.query(
                table: table, where: predicate,
                orderBy: orderBy, limit: limit, offset: offset
            )
            if rows.count == 1 {
                // Only cache when the backing store returns exactly one row so
                // the RowHandle → StorageRow mapping is unambiguous.
                await cache.admit(handle: handle, row: rows[0])
            }
            return rows
        }
        // All other predicates pass through; no query-result caching.
        return try await backing.query(
            table: table, where: predicate,
            orderBy: orderBy, limit: limit, offset: offset
        )
    }

    public func count(
        table: String,
        where predicate: StoragePredicate?
    ) async throws -> Int {
        try await backing.count(table: table, where: predicate)
    }

    // MARK: — External invalidation

    /// Invalidate a cached entry. Called by `CacheInvalidator` when an
    /// external write arrives via `StorageObserver`. Pass `key: nil` when
    /// the change has no specific row identity (e.g. a bulk update) to
    /// evict all entries for the table.
    public func invalidate(table: String, key: RowKey?) async {
        guard config.enabled else { return }
        if let key {
            await cache.evict(RowHandle(table: table, key: key))
        } else {
            await cache.evictAll(table: table)
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
    var entries: [RowHandle: Entry] = [:]
    var accessCounter: Int = 0
    var totalBytes: Int = 0

    init(config: EstateCacheConfig) {
        self.config = config
    }

    // MARK: — Public interface (called from CachingRowStore via await)

    /// Return the cached row for `handle`, refreshing its LRU position.
    func get(_ handle: RowHandle) -> StorageRow? {
        guard var entry = entries[handle] else { return nil }
        accessCounter += 1
        entry.accessOrder = accessCounter
        entries[handle] = entry
        return entry.row
    }

    /// Admit `row` under `handle` if it passes the sensitivity gate and the
    /// byte budget allows it. Evicts LRU entries as needed to make room.
    func admit(handle: RowHandle, row: StorageRow) {
        guard config.enabled else { return }
        guard isAdmissible(row) else { return }
        let size = estimatedBytes(row)
        // Remove any stale entry for this handle before checking the budget.
        if let existing = entries[handle] {
            totalBytes -= existing.byteSize
            entries.removeValue(forKey: handle)
        }
        // When ceilingBytes > 0 evict LRU entries until the new row fits.
        // ceilingBytes == 0 means no limit (enabled=false is guarded above).
        if config.ceilingBytes > 0 {
            while !entries.isEmpty, totalBytes + size > config.ceilingBytes {
                evictLRU()
            }
            // If the new row is larger than the entire ceiling, skip it.
            guard totalBytes + size <= config.ceilingBytes else { return }
        }
        accessCounter += 1
        entries[handle] = Entry(row: row, accessOrder: accessCounter, byteSize: size)
        totalBytes += size
    }

    /// Remove the entry for `handle`.
    func evict(_ handle: RowHandle) {
        if let entry = entries.removeValue(forKey: handle) {
            totalBytes -= entry.byteSize
        }
    }

    /// Remove all entries whose `RowHandle.table` matches `table`.
    func evictAll(table: String) {
        let toRemove = entries.keys.filter { $0.table == table }
        for handle in toRemove {
            if let entry = entries.removeValue(forKey: handle) {
                totalBytes -= entry.byteSize
            }
        }
    }

    // MARK: — Sensitivity gate

    /// Returns `true` when `row` is eligible for the hot tier.
    ///
    /// `provenance` encodes sensitivity in bits [6:4]: `level = (raw >> 4) & 0x7`.
    ///
    ///   - Column absent           → admit (no sensitivity constraint)
    ///   - level > threshold       → reject
    ///   - level == 3 (Secret)     → reject always regardless of threshold
    ///   - Unparseable value       → reject (fail closed)
    private func isAdmissible(_ row: StorageRow) -> Bool {
        guard let provenanceValue = row["provenance"] else { return true }
        let raw: Int64
        switch provenanceValue {
        case .int(let i):    raw = i
        case .bitmap(let i): raw = i
        default:             return false   // fail closed on unrecognised type
        }
        let level = Int((raw >> 4) & 0x7)
        // Hard Secret exclusion is defence-in-depth: threshold is already
        // clamped to ≤2 by EstateCacheConfig, but this guard remains correct
        // even if the clamp were ever bypassed.
        if level == 3 { return false }
        return level <= config.sensitivityThreshold
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
        guard let lruHandle = entries.min(by: { $0.value.accessOrder < $1.value.accessOrder })?.key else {
            return
        }
        if let entry = entries.removeValue(forKey: lruHandle) {
            totalBytes -= entry.byteSize
        }
    }
}
