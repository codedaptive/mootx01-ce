// SensitivityFilteredStorage.swift
//
// Perkins Gate (CVK-ICLOUD P5-M1, Perkins Finding 1):
// Consumer-side sensitivity ceiling wrapper for ConvergenceKit sync.
//
// ConvergenceKit is estate-type-free — it has no concept of adjective bitmaps
// or sensitivity tiers. Those are LocusKit schema concerns. This wrapper lives
// in the ESTATE LAYER (MootGateway) between the sync engine and the underlying
// storage. It gates two paths:
//
// OUTBOUND: Wraps StorageObserver.observe() and filters out TableChange events
// for rows whose adjectiveBitmap encodes a sensitivity tier above syncCeiling.
// The engine's outbound observer (CloudKitStateActor.recordOutbound) feeds
// entirely from these events. Filtering here means above-ceiling rows never
// enter the outbox, never reach a push receipt, and never cross the CloudKit wire.
//
// INBOUND: Wraps RowStore.insertSync() / upsertSync() (the paths applyInbound
// uses to write received rows). When an inbound record's adjectiveBitmap exceeds
// the ceiling, the wrapper throws SensitivityCeilingError. PullCycle's per-record
// catch counts the throw as a conflict and continues. The row is not written locally.
//
// ─────────────────────────────────────────────────────────────────────────────
// Perkins Amendment 1 — The wrapper MUST be the EXACT handle passed to
// engine.enable(manifest:storage:). This is not a convenience; it is a structural
// invariant.
//
// Why: AppliedBatch.storage (IntegrityHook.swift:56) hands the integrity hook the
// same handle the engine holds. Hook writes carry origin == .local and flow into
// the outbox (hook-writes-must-ship, Kong Q2 adjudication). If the raw storage is
// passed to enable() instead of the wrapper, integrity-hook repair writes on
// above-ceiling rows carry origin == .local, enter the outbox, and cross the
// CloudKit wire — leaking above-ceiling content through the hook path even though
// the initial change event was filtered. Passing the wrapper as the single handle
// ensures hook-originated writes on above-ceiling rows also go through the filtered
// observer, so they are suppressed from the outbox.
//
// SyncController.enable(engine:manifest:ceiling:) enforces this invariant by
// constructing SensitivityFilteredStorage internally and passing it to engine.enable().
// No caller of SyncController should bypass this path.
// ─────────────────────────────────────────────────────────────────────────────
//
// Tier-rise retraction (Perkins Finding 1, Amendment 2 — CVK-WB1):
// When a row's tier rises above the ceiling after initial sync (e.g. a "normal"
// drawer promoted to "restricted"), two coordinated changes ship together:
//
// OUTBOUND RETRACTION (SensitivityFilteredObserver.observe):
// When an above-ceiling UPDATE event arrives, the observer emits a synthetic
// delete TableChange (origin: .local, values: nil) before discarding the content
// update. recordOutbound picks it up and enqueues a tombstone in the outbox.
// PushCycle sends the tombstone to CloudKit; peers hard-delete their below-ceiling
// copies via the normal tombstone path.
//
// WHY the observer is the right seam (not direct outbox injection):
// recordOutbound is the only path that mints HLCs and stamps them onto outbox
// entries in push order. Injecting a synthetic TableChange with origin: .local
// routes through recordOutbound naturally — no HLC generator is needed here, and
// the tombstone competes correctly with any coalesced UPDATE for the same row.
// If the row is demoted back below ceiling before the tombstone is pushed, the
// demotion UPDATE (higher HLC) coalesces over the tombstone in the outbox —
// outbox coalescing (newest HLC wins per (table, row_key)) ensures only the
// UPDATE reaches CloudKit, not the stale tombstone.
//
// WHY UPDATE events only (not INSERT or DELETE):
// - INSERT: the row was just created above-ceiling — peers never had it, nothing
//   to retract.
// - DELETE: a caller-initiated deletion of an above-ceiling row — peers already
//   don't have it (prior retraction ensured this), so no peer notification is
//   needed. Caller-initiated deletes go through delete() (not deleteSync()), so
//   they're unambiguously local intent and don't need gating here.
// - UPDATE: the only case where peers may hold a prior below-ceiling snapshot.
//   Safe to emit even if the row was always above-ceiling: a tombstone for a
//   row peers never had is a no-op on their side.
//
// LOCAL PRESERVATION (SensitivityFilteredRowStore.deleteSync):
// The retraction tombstone is self-delivered by the CloudKit pull path (every
// push is reflected back to the originating device via zone-change pull).
// Without a guard, applyInbound would call deleteSync here and hard-delete the
// local restricted row. The guard queries the row before forwarding: if the row
// is above-ceiling locally, the delete is blocked (returns 0). The local
// restricted copy is the authoritative version on this device; inbound tombstones
// for above-ceiling rows are either our own retraction (do not delete locally) or
// a peer deleting a stale below-ceiling snapshot (the peer's view was already
// retracted; local state wins).
//
// DEMOTION EDGE:
// If the row is later demoted back below the ceiling, the next local write
// produces a below-ceiling UPDATE event → passes through the observer filter
// → enters the outbox → peers re-receive the row. The deleteSync guard checks
// the CURRENT sensitivity, so a below-ceiling row is forwarded normally.
//
// ─────────────────────────────────────────────────────────────────────────────
// FAB5-ST: Dynamic ceiling (Perkins Findings, Amendment 3)
//
// The ceiling is now dynamic, backed by TierAuthorizationStore. When the user
// revokes authorization for a tier, retractAndLowerCeiling(to:tables:) is called:
//
// 1. Queries base storage for rows in the sensitive table(s) whose adjectiveBitmap
//    exceeds the new (lower) ceiling.
// 2. Yields a synthetic delete TableChange (tombstone intent) per above-ceiling
//    row into the retraction stream.
// 3. Updates the ceiling atomically.
//
// The retraction stream is merged into the "drawers" observer stream so the sync
// engine's recordOutbound picks up the tombstones and ships them on the next push.
// Observers for other tables are unaffected — only drawers carry adjectiveBitmap.
//
// SensitivityFilteredStorage is a final class (not a struct) so SyncController can
// hold a stable reference and update the ceiling after construction.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import os
import PersistenceKit
import SubstrateTypes
import LocusKit

// MARK: - Error

/// Thrown by SensitivityFilteredRowStore when an inbound sync write carries a row
/// whose adjectiveBitmap sensitivity tier exceeds the configured syncCeiling.
///
/// PullCycle catches this per-record and increments its conflict counter, then
/// continues to the next record. The above-ceiling row is not written locally.
/// The throw is equivalent to "delete + count conflict" in the sync layer — the
/// record is not applied locally, and the conflict count accurately reflects the
/// gate rejection.
public struct SensitivityCeilingError: Error, Sendable, CustomStringConvertible {
    public let table: String
    public let sensitivityRaw: Int
    public let ceilingRaw: Int

    public var description: String {
        "CVK sensitivity ceiling violation: table='\(table)' row sensitivity raw \(sensitivityRaw) > ceiling raw \(ceilingRaw)"
    }
}

// MARK: - Internal bitmap helpers

/// Extract the sensitivity raw value from an adjectiveBitmap TypedValue.
///
/// Bits 6–11 of the Int64 bitmap carry the 6-bit sensitivity axis per
/// LocusKit/Adjectives.swift (AdjectiveSensitivity: normal=0 / elevated=16 /
/// restricted=32 / secret=48). The scale-gapped encoding means larger raw values
/// are higher-sensitivity tiers.
///
/// Returns nil for TypedValue cases that are not bitmap/int (unrecognised encoding
/// or absent column). A nil result passes through — tables without an
/// adjectiveBitmap are not sensitivity-gated.
private func sensitivityRaw(from value: TypedValue) -> Int? {
    let raw: Int64
    switch value {
    case .bitmap(let v): raw = v
    case .int(let v): raw = v
    default: return nil
    }
    return Int((raw >> 6) & 0x3F)
}

/// True when the row encoded in `values` carries a sensitivity tier above `ceiling`.
///
/// The gate is table-agnostic: any row missing an `adjectiveBitmap` column returns
/// false and passes through (tunnels, kg_facts, diary have no sensitivity axis).
/// Only the `drawers` table carries the adjective bitmap in the standard estate schema.
private func exceedsCeiling(_ values: [String: TypedValue]?, ceiling: AdjectiveSensitivity) -> Bool {
    guard let bitmapValue = values?["adjectiveBitmap"],
          let raw = sensitivityRaw(from: bitmapValue) else { return false }
    return raw > ceiling.rawValue
}

// MARK: - SensitivityFilteredObserver

/// StorageObserver wrapper that filters outbound TableChange events for rows
/// whose adjectiveBitmap sensitivity tier exceeds syncCeiling.
///
/// The engine's outbound observer (CloudKitStateActor.recordOutbound, called from
/// the storage observer stream) reads observe() to build the outbox. Filtering here
/// prevents above-ceiling rows from ever entering the outbox, regardless of whether
/// the write originated from a direct caller or from an integrity-hook repair.
///
/// For the "drawers" table, the observer merges the upstream (filtered) stream with
/// the parent's retraction stream so ceiling-lowering tombstones from
/// retractAndLowerCeiling() reach the outbox without a separate channel.
///
/// observeBlobs() and observeDirtyChain() are forwarded unchanged — those streams
/// carry no row-level sensitivity information.
private struct SensitivityFilteredObserver: StorageObserver {
    let base: any StorageObserver
    /// Reads the current ceiling at event time. Captures parent weakly.
    let ceilingGetter: @Sendable () -> AdjectiveSensitivity
    /// Tombstones from retractAndLowerCeiling(). Merged into the "drawers" stream only.
    let retractionStream: AsyncStream<TableChange>

    func observe(table: String, events: Set<StorageEvent>) -> AsyncStream<TableChange> {
        let upstream = base.observe(table: table, events: events)
        let getCeiling = ceilingGetter

        if table == "drawers" {
            // For drawers: merge upstream (filtered by dynamic ceiling) +
            // retraction tombstones from retractAndLowerCeiling().
            let retraction = retractionStream
            return AsyncStream { continuation in
                let upstreamTask = Task {
                    for await change in upstream {
                        let cap = getCeiling()
                        guard exceedsCeiling(change.values, ceiling: cap) else {
                            continuation.yield(change)
                            continue
                        }
                        // Above-ceiling event — emit retraction tombstone for UPDATEs.
                        if change.event == .update, let rowKey = change.rowKey {
                            continuation.yield(TableChange(
                                table: change.table, event: .delete,
                                rowKey: rowKey, values: nil, origin: .local))
                        }
                        // INSERT and DELETE above-ceiling: skip entirely.
                    }
                    // Upstream exhausted — finish continuation. onTermination cancels
                    // retractionTask; retraction tombstones from retractAndLowerCeiling
                    // are yielded via the retraction stream before upstream drains in
                    // normal ceiling-lowering operation.
                    continuation.finish()
                }
                let retractionTask = Task {
                    for await tombstone in retraction {
                        continuation.yield(tombstone)
                    }
                }
                continuation.onTermination = { _ in
                    upstreamTask.cancel()
                    retractionTask.cancel()
                }
            }
        } else {
            // Non-drawers: simple dynamic-ceiling filter (no retraction path).
            return AsyncStream { continuation in
                let task = Task {
                    for await change in upstream {
                        let cap = getCeiling()
                        guard exceedsCeiling(change.values, ceiling: cap) else {
                            continuation.yield(change)
                            continue
                        }
                        if change.event == .update, let rowKey = change.rowKey {
                            continuation.yield(TableChange(
                                table: change.table, event: .delete,
                                rowKey: rowKey, values: nil, origin: .local))
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    func observeBlobs() -> AsyncStream<BlobChange> { base.observeBlobs() }
    func observeDirtyChain() -> AsyncStream<DirtyChainEvent> { base.observeDirtyChain() }
}

// MARK: - SensitivityFilteredRowStore

/// RowStore wrapper that intercepts the sync-tagged write paths (insertSync, upsertSync)
/// to enforce the sensitivity ceiling on inbound applies.
///
/// When ConvergenceKit's applyInbound calls insertSync/upsertSync on this wrapper and
/// the inbound record's adjectiveBitmap exceeds the ceiling, the wrapper throws
/// SensitivityCeilingError. PullCycle's per-record catch counts it as a conflict and
/// continues to the next record. The row is not written locally.
///
/// All non-sync write paths (insert, upsert, update, delete) are forwarded unchanged —
/// caller-initiated writes are sensitivity-gated at the LocusKit verb layer at capture
/// time, not here.
///
/// deleteSync is guarded: when the local row is above-ceiling, the inbound tombstone
/// is blocked (tier-rise self-delivery guard, CVK-WB1). When the row is at or below
/// ceiling, the tombstone is forwarded so peer-deletion signals propagate normally.
private struct SensitivityFilteredRowStore: RowStore {
    let base: any RowStore
    /// Reads current ceiling at call time. Captures parent weakly via closure.
    let ceilingGetter: @Sendable () -> AdjectiveSensitivity

    // MARK: Caller-initiated write paths (forwarded unchanged)

    func insert(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        try await base.insert(table: table, values: values)
    }

    @discardableResult
    func upsert(table: String, values: [String: TypedValue],
                conflictColumns: [String]) async throws -> RowHandle {
        try await base.upsert(table: table, values: values, conflictColumns: conflictColumns)
    }

    @discardableResult
    func update(table: String, values: [String: TypedValue],
                where predicate: StoragePredicate) async throws -> Int {
        try await base.update(table: table, values: values, where: predicate)
    }

    @discardableResult
    func delete(table: String, where predicate: StoragePredicate) async throws -> Int {
        try await base.delete(table: table, where: predicate)
    }

    // MARK: Read paths (forwarded unchanged)

    func query(table: String, where predicate: StoragePredicate?,
               orderBy: [OrderClause], limit: Int?, offset: Int?) async throws -> [StorageRow] {
        try await base.query(table: table, where: predicate,
                             orderBy: orderBy, limit: limit, offset: offset)
    }

    func count(table: String, where predicate: StoragePredicate?) async throws -> Int {
        try await base.count(table: table, where: predicate)
    }

    func querySkipCorrupt(table: String, where predicate: StoragePredicate?,
                          orderBy: [OrderClause], limit: Int?, offset: Int?,
                          columns: [String]?) async throws -> (rows: [StorageRow], skipped: Int) {
        try await base.querySkipCorrupt(table: table, where: predicate,
                                        orderBy: orderBy, limit: limit, offset: offset,
                                        columns: columns)
    }

    func query(table: String, where predicate: StoragePredicate?,
               orderBy: [OrderClause], limit: Int?, offset: Int?,
               columns: [String]?) async throws -> [StorageRow] {
        try await base.query(table: table, where: predicate,
                             orderBy: orderBy, limit: limit, offset: offset, columns: columns)
    }

    // MARK: Sync-tagged write paths — inbound sensitivity gate

    /// Inbound sync insert gate.
    ///
    /// Throws SensitivityCeilingError when the row's adjectiveBitmap sensitivity
    /// exceeds the configured ceiling. PullCycle's per-record catch counts the throw
    /// as a conflict; the row is not written locally.
    func insertSync(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        let ceiling = ceilingGetter()
        if exceedsCeiling(values, ceiling: ceiling) {
            let raw = values["adjectiveBitmap"].flatMap { sensitivityRaw(from: $0) } ?? 0
            throw SensitivityCeilingError(table: table, sensitivityRaw: raw, ceilingRaw: ceiling.rawValue)
        }
        return try await base.insertSync(table: table, values: values)
    }

    /// Inbound sync upsert gate.
    ///
    /// Throws SensitivityCeilingError when the row's adjectiveBitmap sensitivity
    /// exceeds the configured ceiling. Also covers integrity-hook repair writes
    /// (hook writes use origin == .local and call upsert, not upsertSync — but the
    /// filtered observer suppresses their resulting TableChange events, so the hook
    /// path does not bypass the outbound gate even through the non-sync upsert path).
    @discardableResult
    func upsertSync(table: String, values: [String: TypedValue],
                    conflictColumns: [String]) async throws -> RowHandle {
        let ceiling = ceilingGetter()
        if exceedsCeiling(values, ceiling: ceiling) {
            let raw = values["adjectiveBitmap"].flatMap { sensitivityRaw(from: $0) } ?? 0
            throw SensitivityCeilingError(table: table, sensitivityRaw: raw, ceilingRaw: ceiling.rawValue)
        }
        return try await base.upsertSync(table: table, values: values, conflictColumns: conflictColumns)
    }

    /// Inbound sync delete (tombstone) — forwarded unless the row is above-ceiling locally.
    ///
    /// Tombstone CKRecords carry only row identity (UUID + delete HLC), not content.
    /// Forwarding tombstone deletes normally preserves the deletion signal's propagation
    /// without leaking content.
    ///
    /// TIER-RISE SELF-DELIVERY GUARD (CVK-WB1):
    /// When SensitivityFilteredObserver emits a retraction tombstone for an above-ceiling
    /// UPDATE, that tombstone is pushed to CloudKit and then self-delivered to this device
    /// on the next pull cycle. Without this guard, applyInbound would hard-delete the local
    /// restricted row. The guard queries the row: if it is above-ceiling locally, the
    /// tombstone is blocked (returns 0). The local restricted copy is the authoritative
    /// version; inbound tombstones for above-ceiling rows are either our own retraction
    /// (must not delete locally) or a peer deleting a stale below-ceiling snapshot
    /// (peer's view was already retracted; local state wins). Below-ceiling rows are
    /// forwarded unchanged — peer-delete semantics are preserved for visible rows.
    @discardableResult
    func deleteSync(table: String, where predicate: StoragePredicate) async throws -> Int {
        let ceiling = ceilingGetter()
        // Pre-flight: check whether the row being deleted is above-ceiling locally.
        // Use the same predicate as the delete so this compiles to one DB lookup.
        let existing = try? await base.query(
            table: table,
            where: predicate,
            orderBy: [],
            limit: 1,
            offset: nil
        )
        if let row = existing?.first, exceedsCeiling(row.values, ceiling: ceiling) {
            // Row exists locally and is above the sensitivity ceiling.
            // Block the inbound tombstone — the local restricted copy must survive.
            // Caller-initiated deletes use delete() (not deleteSync()) so they are
            // not affected by this gate.
            //
            // Demotion edge (Perkins ADVISORY-3 — documented gap):
            // If the row's tier rises above ceiling (retraction tombstone ships),
            // then falls back below ceiling, and the tombstone self-delivers while
            // the row is already demoted, the guard FORWARDS the tombstone here
            // (demotion means exceedsCeiling returns false for the demoted row).
            // The local row is hard-deleted. ConvergenceKit's HLC-based resurrection
            // (the demotion UPDATE at a higher HLC than the tombstone) is expected
            // to restore the row on the next push/pull cycle — but this behavior
            // is not explicitly specified in CONVERGENCEKIT_SPEC and should be
            // confirmed before the secret tier is cleared for production.
            return 0
        }
        return try await base.deleteSync(table: table, where: predicate)
    }

    // MARK: Transaction boundary (forwarded)

    func beginTransaction() async throws { try await base.beginTransaction() }
    func commitTransaction() async throws { try await base.commitTransaction() }
    func rollbackTransaction() async throws { try await base.rollbackTransaction() }
}

// MARK: - SensitivityFilteredStorage

/// A Storage wrapper that enforces a sensitivity ceiling on ConvergenceKit sync I/O.
///
/// ## Purpose
///
/// ConvergenceKit is estate-type-free. It has no concept of sensitivity tiers or
/// adjective bitmaps. `SensitivityFilteredStorage` is the consumer-side (MootGateway)
/// enforcement point that keeps ConvergenceKit sensitivity-ignorant while correctly
/// gating sync at the estate layer.
///
/// ## Invariant — this instance MUST be passed to engine.enable()
///
/// See the file header for the Perkins Amendment 1 rationale. In short: this wrapper
/// must be the EXACT storage handle `engine.enable(manifest:storage:)` receives.
/// SyncController.enable(engine:manifest:ceiling:) constructs and passes this wrapper.
///
/// ## Outbound gating
///
/// `observer.observe()` returns a filtered `AsyncStream<TableChange>` that drops events
/// where `adjectiveBitmap` > `syncCeiling`. The engine's recordOutbound only sees
/// below-ceiling changes; above-ceiling rows never enter the outbox.
///
/// ## Inbound gating
///
/// `rowStore.insertSync()` / `upsertSync()` throw `SensitivityCeilingError` when the
/// inbound record's `adjectiveBitmap` exceeds the ceiling. PullCycle counts the throw
/// as a conflict and continues. The row is not written locally.
///
/// ## Tier-rise retraction (CVK-WB1)
///
/// When a previously-synced row's sensitivity tier rises above the ceiling,
/// SensitivityFilteredObserver emits a retraction tombstone (synthetic delete,
/// origin: .local, nil values) for above-ceiling UPDATE events. Peers receive
/// the tombstone CKRecord and hard-delete their snapshot via the normal path.
/// The self-delivered tombstone is blocked by SensitivityFilteredRowStore.deleteSync
/// so the local restricted row survives. See the file header for the full design.
///
/// ## Dynamic ceiling (FAB5-ST)
///
/// `retractAndLowerCeiling(to:tables:)` scans base storage for rows above the new
/// ceiling, emits tombstones into the retraction stream (merged into the drawers
/// observer), then atomically updates the ceiling. The observer and rowStore both
/// read the ceiling at call time via a closure — no stale ceiling values.
///
/// ## Tables without adjectiveBitmap
///
/// Tunnels, kg_facts, and diary rows carry no `adjectiveBitmap` column. The bitmap
/// extraction returns nil for those tables → all rows in those tables pass both the
/// outbound filter and the inbound gate unchanged.
public final class SensitivityFilteredStorage: Storage, @unchecked Sendable {

    private let base: any Storage

    // OSAllocatedUnfairLock<AdjectiveSensitivity> provides fast, correct concurrent
    // access to the ceiling from Task contexts (observer/rowStore closures) while the
    // actor-isolated retractAndLowerCeiling writes it on the SyncController actor.
    private let _ceiling: OSAllocatedUnfairLock<AdjectiveSensitivity>

    // Retraction stream: tombstones yielded by retractAndLowerCeiling() are merged
    // into the "drawers" observer stream so the sync engine ships them on the next push.
    // Single-consumer by design: the sync engine's recordOutbound task reads it once
    // per session. A new session (disable + enable) creates a new SensitivityFilteredStorage
    // via SyncController.enable(), which has a fresh stream.
    private let _retractionContinuation: AsyncStream<TableChange>.Continuation
    // Internal (not private) so test targets (@testable import) can verify tombstone
    // emission via retractAndLowerCeiling() without wiring the full merged observer.
    let _retractionStream: AsyncStream<TableChange>

    /// The sensitivity ceiling applied to outbound and inbound sync.
    ///
    /// Reads atomically from the internal lock — safe to call from any concurrency domain.
    /// Updated only via `retractAndLowerCeiling(to:tables:)`.
    public var syncCeiling: AdjectiveSensitivity {
        _ceiling.withLock { $0 }
    }

    /// Construct a sensitivity-filtered storage wrapper.
    ///
    /// - Parameters:
    ///   - base: The underlying Storage instance (SQLiteStorage or InMemoryStorage).
    ///   - ceiling: Initial rows-above-ceiling gate. Default `.elevated`.
    public init(wrapping base: any Storage, ceiling: AdjectiveSensitivity = .elevated) {
        self.base = base
        self._ceiling = OSAllocatedUnfairLock(initialState: ceiling)
        let (stream, continuation) = AsyncStream<TableChange>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        self._retractionStream = stream
        self._retractionContinuation = continuation
    }

    // MARK: Storage protocol — filtered surfaces

    public var configuration: EstateConfiguration { base.configuration }

    /// Filtered row store — gates inbound sync writes above syncCeiling.
    ///
    /// Created on each call; captures ceiling via closure for dynamic updates.
    public var rowStore: any RowStore {
        SensitivityFilteredRowStore(
            base: base.rowStore,
            ceilingGetter: { [weak self] in self?.syncCeiling ?? .elevated })
    }

    public var blobStore: any BlobStore { base.blobStore }
    public var auditLog: any AuditLog { base.auditLog }

    /// Filtered observer — suppresses outbound TableChange events for above-ceiling rows.
    ///
    /// For the "drawers" table, merges the upstream (filtered) stream with the retraction
    /// stream so ceiling-lowering tombstones from retractAndLowerCeiling() reach the outbox.
    public var observer: any StorageObserver {
        SensitivityFilteredObserver(
            base: base.observer,
            ceilingGetter: { [weak self] in self?.syncCeiling ?? .elevated },
            retractionStream: _retractionStream)
    }

    public var datasetStore: any DatasetStore {
        get throws { try base.datasetStore }
    }

    // MARK: Forwarded lifecycle and schema

    public func open(schema: SchemaDeclaration) async throws {
        try await base.open(schema: schema)
    }

    public func close() async { await base.close() }

    public func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        try await base.transaction(isolation: isolation, block)
    }

    public func currentSchemaVersion() async throws -> Int {
        try await base.currentSchemaVersion()
    }

    public func currentSchemaVersion(for kitID: String) async throws -> Int {
        try await base.currentSchemaVersion(for: kitID)
    }

    public func migrate(to schema: SchemaDeclaration) async throws {
        try await base.migrate(to: schema)
    }

    // MARK: Dynamic ceiling — FAB5-ST

    /// Scan `tables` for rows above `newCeiling`, emit WB1-style tombstones into the
    /// retraction stream (merged into the drawers observer), then update the ceiling.
    ///
    /// Called by SyncController when TierAuthorizationStore reports a ceiling change.
    ///
    /// Tombstone semantics: the retraction stream delivers synthetic delete TableChange
    /// events (origin: .local, nil values) with the row's UUID as rowKey. The drawers
    /// observer merges these into its output stream so CloudKitStateActor.recordOutbound
    /// enqueues them in the outbox on the next push cycle. Peers receive a tombstone
    /// CKRecord and hard-delete their below-ceiling copy (normal tombstone path).
    ///
    /// Self-delivery guard (CVK-WB1): SensitivityFilteredRowStore.deleteSync blocks
    /// inbound tombstones for rows that are locally above-ceiling, so the local copy
    /// survives the retraction round-trip.
    ///
    /// When ceiling RAISES (newCeiling > current): no rows are above the new ceiling
    /// relative to the new threshold, so no tombstones are emitted. The ceiling is
    /// updated, and new observer reads use the higher ceiling immediately.
    ///
    /// - Parameters:
    ///   - newCeiling: The ceiling to enforce after retraction.
    ///   - tables: Tables to scan for above-ceiling rows (typically `["drawers"]`).
    public func retractAndLowerCeiling(
        to newCeiling: AdjectiveSensitivity,
        tables: [String]
    ) async {
        // Ceiling is updated FIRST so no concurrent observer Task can slip an
        // above-ceiling UPDATE through the stale (higher) ceiling between the
        // last tombstone yield and the lock write (Perkins ADVISORY-2).
        _ceiling.withLock { $0 = newCeiling }
        for table in tables {
            let rows = (try? await base.rowStore.query(
                table: table, where: nil, orderBy: [], limit: nil, offset: nil)) ?? []
            for row in rows {
                guard exceedsCeiling(row.values, ceiling: newCeiling) else { continue }
                // Extract row ID: drawers use the "id" UUID column.
                guard case .uuid(let rowKey) = row.values["id"] else { continue }
                _retractionContinuation.yield(TableChange(
                    table: table,
                    event: .delete,
                    rowKey: rowKey,
                    values: nil,
                    origin: .local
                ))
            }
        }
    }
}
