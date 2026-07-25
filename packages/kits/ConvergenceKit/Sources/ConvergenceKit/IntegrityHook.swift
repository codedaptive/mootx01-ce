// IntegrityHook.swift
//
// AppliedBatch type and invocation helper for the post-apply integrity hook
// after an inbound batch so consumers can restore domain invariants.
//
// The hook is an optional closure on SyncManifest, called once per pull batch
// AFTER all records have been applied. Its purpose is to restore cross-row or
// cross-table structural invariants that row-grain conflict policies cannot
// express (orphaned references, re-parenting rules, etc.). ConvergenceKit stays
// ignorant of the invariants themselves; the consumer supplies the logic.

import Foundation
import PersistenceKit

// MARK: - AppliedBatch

/// Summary of one inbound pull batch delivered to the post-apply integrity hook.
///
/// The hook receives this value after every pull in which at least one record
/// was applied (inserted, updated, or deleted). The `storage` handle is the
/// same `PersistenceKit.Storage` the pull used; writes made through it carry
/// `origin == .local` — they are NOT sync-tagged — and therefore flow into the
/// outbox and will be pushed to peers on the next cycle (Kong invariant:
/// hook-writes-must-ship).
///
/// ## Atomicity caveat
///
/// PersistenceKit exposes no batch-transaction API today. The hook runs after
/// all batch records have been applied but NOT inside a containing transaction.
/// A process crash between record application and hook completion leaves the
/// estate in a partially-repaired state. Consumers should design hooks so that
/// re-invoking them on a subsequent pull is safe (idempotent repairs). If
/// PersistenceKit gains a transaction API in a future release, the hook
/// invocation site can be moved inside the transaction without a breaking
/// change to this type.
///
/// ## Not Codable
///
/// `AppliedBatch` holds an `any Storage` existential and is not serialisable.
/// It is constructed by the engine at pull time and passed directly to the hook
/// closure; it is never persisted or transmitted.
public struct AppliedBatch: @unchecked Sendable {
    // @unchecked Sendable: Storage: Sendable, so any concrete conformer is safe
    // to cross concurrency boundaries. The @unchecked annotation silences the
    // compiler warning from the existential wrapper without weakening the safety
    // guarantee — the underlying storage is Sendable by protocol constraint.

    /// PersistenceKit storage against which the pull applied.
    ///
    /// Use this handle to perform structural-invariant repair writes.
    /// Writes made through `storage` use the caller-visible (non-sync-tagged)
    /// write paths, so they carry `origin == .local`. The storage observer
    /// fires normally, and ConvergenceKit's outbound observer enqueues the
    /// change for the next push cycle — satisfying the hook-writes-must-ship
    /// invariant (Kong Q2 adjudication).
    public let storage: any Storage

    /// Row keys that were upserted (inserted or updated) during this batch,
    /// keyed by table name. Rows skipped by the LWW gate (stale HLC) do not
    /// appear here — only rows that were actually written to PersistenceKit.
    public let appliedByTable: [String: [UUID]]

    /// Row keys whose tombstones were applied (hard-deleted) during this batch,
    /// keyed by table name.
    public let deletedByTable: [String: [UUID]]

    /// Designated initialiser. Called by the pull-cycle paths in each backend.
    /// Consumers receive an already-populated value from the engine.
    public init(
        storage: any Storage,
        appliedByTable: [String: [UUID]],
        deletedByTable: [String: [UUID]]
    ) {
        self.storage = storage
        self.appliedByTable = appliedByTable
        self.deletedByTable = deletedByTable
    }
}

// MARK: - Invocation helper

/// Invoke the post-apply integrity hook after a pull batch, if present.
///
/// Behavioral contract (R3, firmed in CVK-ICLOUD P2-M3):
/// - Called once per pull cycle, AFTER all records in the batch are applied.
/// - NOT called when the batch applied zero records (empty-batch rule); the
///   guard is enforced both here and at every call site.
/// - A hook throw is counted as ONE additional conflict in the SyncReceipt
///   and logged internally. The throw does NOT abort the pull cycle — all
///   records were already applied before the hook runs.
/// - Hook-originated writes use the non-sync-tagged write paths (`upsert`,
///   `insert`, `delete` — not `upsertSync` / `insertSync` / `deleteSync`).
///   They carry `origin == .local` and therefore flow into the outbox,
///   satisfying the hook-writes-must-ship invariant.
///
/// - Parameters:
///   - hook: The `postApplyIntegrityHook` from the manifest, or `nil`.
///   - batch: The batch summary constructed by the pull path.
/// - Returns: 1 if the hook threw (counts as one additional conflict), 0 otherwise.
///
/// Package access: callable by both backend modules (`ConvergenceKitFederation`,
/// `ConvergenceKitCloudKit`) within the same Swift package; not public API.
@discardableResult
package func invokeIntegrityHook(
    _ hook: (@Sendable (AppliedBatch) async throws -> Void)?,
    batch: AppliedBatch
) async -> Int {
    guard let hook else { return 0 }
    // Empty-batch guard: the invariant "hook NOT invoked when zero records
    // applied" is enforced at every pull-path call site AND here as a
    // belt-and-suspenders safety net for future callers.
    guard !batch.appliedByTable.isEmpty || !batch.deletedByTable.isEmpty else {
        return 0
    }
    do {
        try await hook(batch)
        return 0
    } catch {
        // Hook failure is non-fatal: the pull already succeeded. Count as one
        // conflict so the SyncReceipt surfaces the integrity-check failure
        // without losing information. The error is not re-thrown.
        return 1
    }
}
