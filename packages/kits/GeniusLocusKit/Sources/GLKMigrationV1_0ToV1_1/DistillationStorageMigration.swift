// DistillationStorageMigration.swift
//
// SPEC_DISTILLATION_STORAGE Appendix A.1 — data migration for the
// 1.0.x → 1.1.x distillation storage redesign.
//
// Step ordering (load-bearing — spec Appendix A.1 note):
//   (c) Re-key distillation-features-v1 lane entries from factoid IDs to
//       source drawer IDs; ambiguous provenance (≠1 _distilled_from tunnel)
//       drops the entry; also deletes orphaned factoid-keyed lane entries
//       (items whose item_id no longer exists in drawers at all — FINDING
//       11X_CUSTODIAN_WALK item 1).
//   (b) Drop all factoid drawers (addedBy = "distillation-daemon"). These
//       are the retired distilled-view rows; content is never converted.
//   (d) Drop all _distilled_from tunnels (provenance link retired in 1.1.x).
//   (e) Add the four representation columns to `drawers` with NULL initial
//       values: distilled, distilled_pipeline_version, distilled_token_count,
//       distilled_at. Tracked under kitID "GLKDistillationStorageMigration"
//       so migration state is independent of the LocusKit schema version.
//       addColumn is idempotent (PersistenceKit skips columns that already
//       exist, covering the fresh-1.1.x-estate path).
//
// (c) must precede (b) because it reads factoid drawer IDs, and must
// precede (d) because it reads _distilled_from tunnels.
//
// Steps (c)–(d) are wrapped in a single storage transaction. A crash
// during the transaction rolls back to the pre-migration state; the
// migration block runs again cleanly on resume since the estate format
// stamp at v1_1 (written by SharedContentMigration at the end of the
// full migration chain) has not been written yet.
//
// Vault protocol (A.0.5) is expressed as a closure-based struct
// (DistillationStorageMigrationVaultProtocol) to keep this target free
// of a VaultKit dependency. The app layer supplies the vault operations.
//
// Rust twin: rust-migrations/src/distillation_storage_migration.rs

import Foundation
import GeniusLocusKit
import OSLog
import PersistenceKit

private let log = Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")

// MARK: - Domain constants

/// VectorKit model lane that holds structural fingerprints.
/// 1.0.x: keyed by factoid drawer ID. 1.1.x: keyed by source drawer ID.
private let kDistillationLaneModelID = "distillation-features-v1"

/// addedBy value for all factoid drawers (the retired view layer).
private let kDistillationDaemonAddedBy = "distillation-daemon"

/// Tunnel label that links a factoid drawer (source endpoint) to the
/// original content drawer (target endpoint). Retired in 1.1.x.
private let kDistilledFromLabel = "_distilled_from"

// MARK: - Vault protocol (A.0.5)

/// Closure-based protocol for vault operations during migration.
///
/// Expressed as closures (not a protocol type) so the migration target
/// stays free of a VaultKit import. The app layer constructs this struct
/// and provides real VaultKit operations as the closure bodies.
public struct DistillationStorageMigrationVaultProtocol: Sendable {

    /// Pre-migration vault reconcile. Returns:
    ///   - `nil`   when no vault is configured for the estate.
    ///   - `true`  when the vault is clean — migration may proceed.
    ///   - `false` when the vault is unclean — migration must abort.
    public let reconcile: @Sendable () async throws -> Bool?

    /// Archive the current vault file by renaming it in place to the
    /// archival suffix path. Called before the A.1 data migration.
    /// The original file MUST NOT be deleted — only renamed.
    public let archive: @Sendable () async throws -> Void

    /// Re-export the estate to the ORIGINAL vault position in the new
    /// 1.1.x format (without the retired distilled_from_sources key).
    /// Called after the A.1 data migration completes.
    public let exportFresh: @Sendable () async throws -> Void

    /// User-visible notice that the vault was archived and re-exported.
    /// Called after exportFresh succeeds. Non-throwing; best-effort.
    public let notifyUser: @Sendable () async -> Void

    public init(
        reconcile: @escaping @Sendable () async throws -> Bool?,
        archive: @escaping @Sendable () async throws -> Void,
        exportFresh: @escaping @Sendable () async throws -> Void,
        notifyUser: @escaping @Sendable () async -> Void
    ) {
        self.reconcile = reconcile
        self.archive = archive
        self.exportFresh = exportFresh
        self.notifyUser = notifyUser
    }
}

// MARK: - Migration report

/// Summary of what the A.1 migration changed.
public struct DistillationStorageMigrationReport: Sendable, Equatable {

    /// Factoid drawers (addedBy = "distillation-daemon") deleted.
    public let factoidDrawerCount: Int

    /// _distilled_from tunnels deleted.
    public let tunnelCount: Int

    /// distillation-features-v1 lane entries re-keyed from factoid IDs
    /// to source drawer IDs (exactly-1-tunnel case).
    public let reKeyedLaneCount: Int

    /// distillation-features-v1 lane entries deleted — factoids with
    /// ambiguous provenance (0 or >1 tunnels) plus pre-existing orphans
    /// (entries whose item_id no longer existed in drawers).
    public let droppedLaneCount: Int

    public init(
        factoidDrawerCount: Int,
        tunnelCount: Int,
        reKeyedLaneCount: Int,
        droppedLaneCount: Int
    ) {
        self.factoidDrawerCount = factoidDrawerCount
        self.tunnelCount = tunnelCount
        self.reKeyedLaneCount = reKeyedLaneCount
        self.droppedLaneCount = droppedLaneCount
    }
}

// MARK: - Migration error

public enum DistillationStorageMigrationError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    /// Storage was not registered for the estate handle.
    case storageUnavailable(reason: String)

    /// Vault reconcile returned false (unclean vault); A.0.5 abort.
    case vaultUnclean

    public var description: String {
        switch self {
        case let .storageUnavailable(reason):
            return "DistillationStorageMigration: storage unavailable — \(reason)"
        case .vaultUnclean:
            return "DistillationStorageMigration: vault reconcile failed (unclean); migration aborted"
        }
    }
}

// MARK: - Step (e) schema declaration

/// PersistenceKit schema declaration for the four representation columns.
///
/// Uses its own kitID so the migration version is tracked independently
/// of the LocusKit schema version. addColumn operations are idempotent:
/// PersistenceKit skips columns that already exist (covers the
/// fresh-1.1.x-estate path where the v1 CREATE TABLE already includes
/// these columns).
enum DistillationStorageMigrationSchema {
    static let representationColumnsDeclaration = SchemaDeclaration(
        kitID: "GLKDistillationStorageMigration",
        version: 1,
        tables: [],
        indices: [],
        migrations: [
            Migration(fromVersion: 0, toVersion: 1, operations: [
                // distilled: dense parallel rendering of `content`.
                // NULL until DistillationCycle populates it post-migration.
                .addColumn(table: "drawers", column: .text("distilled", nullable: true)),
                // distilled_pipeline_version: contract identifier for the
                // pipeline that produced `distilled` (e.g. "v1").
                .addColumn(table: "drawers", column: .text("distilled_pipeline_version", nullable: true)),
                // distilled_token_count: approximate token count of `distilled`.
                .addColumn(table: "drawers", column: .int("distilled_token_count", nullable: true)),
                // distilled_at: ISO8601 timestamp of the distillation run.
                // TEXT per fleet date storage rule.
                .addColumn(table: "drawers", column: .timestamp("distilled_at", nullable: true))
            ])
        ]
    )
}

// MARK: - GeniusLocusKit extension (public API)

public extension GeniusLocusKit {

    /// Execute the distillation storage data migration (A.1 steps c–e).
    ///
    /// Must be called BEFORE `runSharedContentMigration` so that the
    /// estate format stamp (written by SharedContentMigration at the end
    /// of the full migration chain) has not yet been applied. If the
    /// stamp has already been written the outer `prepare()` loop returns
    /// early and neither migration is called.
    ///
    /// Idempotent within the migration chain: a crash during the
    /// transactional (c)–(d) block leaves the estate unchanged;
    /// step (e) via `storage.migrate(to:)` is independently idempotent.
    @discardableResult
    func runDistillationStorageMigration(
        handle: EstateHandle,
        now: Date
    ) async throws -> DistillationStorageMigrationReport {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) } catch {
            throw DistillationStorageMigrationError.storageUnavailable(
                reason: "no storage registered for \(handle.estateUUID)")
        }
        return try await Self._runDistillationDataMigration(storage: storage)
    }

    /// Execute the distillation storage migration with the vault protocol
    /// (SPEC_DISTILLATION_STORAGE Appendix A.0.5).
    ///
    /// Order:
    ///   1. Pre-migration vault reconcile — abort if unclean.
    ///   2. Archive old vault file (in-place rename, never deleted).
    ///   3. A.1 data migration (steps c–e).
    ///   4. Fresh vault export in new format (no distilled_from_sources).
    ///   5. User notice.
    @discardableResult
    func runDistillationStorageMigrationWithVaultProtocol(
        handle: EstateHandle,
        now: Date,
        vaultProtocol: DistillationStorageMigrationVaultProtocol
    ) async throws -> DistillationStorageMigrationReport {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) } catch {
            throw DistillationStorageMigrationError.storageUnavailable(
                reason: "no storage registered for \(handle.estateUUID)")
        }

        // 1. Pre-migration vault reconcile. nil → no vault, proceed.
        if let clean = try await vaultProtocol.reconcile(), !clean {
            throw DistillationStorageMigrationError.vaultUnclean
        }

        // 2. Archive old vault (in-place rename at export point).
        try await vaultProtocol.archive()

        // 3. A.1 data migration.
        let report = try await Self._runDistillationDataMigration(storage: storage)

        // 4. Fresh vault export — new format, no distilled_from_sources key.
        try await vaultProtocol.exportFresh()

        // 5. User notice.
        await vaultProtocol.notifyUser()

        return report
    }
}

// MARK: - Core migration logic (private)

private extension GeniusLocusKit {

    /// Execute A.1 steps (c)→(b)→(d)→(e).
    ///
    /// Static so it has no actor isolation; storage operations are the
    /// only async work and carry their own concurrency model.
    static func _runDistillationDataMigration(
        storage: any Storage
    ) async throws -> DistillationStorageMigrationReport {

        // Steps (c)→(b)→(d) run inside a single storage transaction.
        // Ordering is load-bearing: (c) reads the tunnels that (d) drops
        // and the factoid IDs that (b) deletes.
        let (reKeyedCount, droppedCount, factoidDeleteCount, tunnelDeleteCount) =
            try await storage.transaction { txn in
                // ── (c) Phase 1: build tunnel map ──────────────────────────
                //
                // Load all _distilled_from tunnels.
                // sourceDrawerId = factoid drawer ID (the view node).
                // targetDrawerId = source drawer ID (the original content).
                let tunnelRows = try await txn.rowStore.query(
                    table: "tunnels",
                    where: .eq(
                        Column(table: "tunnels", name: "label"),
                        .text(kDistilledFromLabel)
                    ),
                    orderBy: [],
                    limit: nil,
                    offset: nil
                )
                var tunnelMap: [String: [String]] = [:]
                for row in tunnelRows {
                    guard let factoidID = _textValue(row["sourceDrawerId"]),
                          let sourceID = _textValue(row["targetDrawerId"])
                    else { continue }
                    tunnelMap[factoidID, default: []].append(sourceID)
                }

                // ── (c) Phase 2: load factoid drawer IDs ──────────────────
                let factoidRows = try await txn.rowStore.query(
                    table: "drawers",
                    where: .eq(
                        Column(table: "drawers", name: "addedBy"),
                        .text(kDistillationDaemonAddedBy)
                    ),
                    orderBy: [],
                    limit: nil,
                    offset: nil
                )
                let factoidIDs = Set(factoidRows.compactMap { _textValue($0["id"]) })

                // ── (c) Phase 3: load lane item IDs ───────────────────────
                //
                // All item_ids in the distillation-features-v1 lane.
                let laneRows = try await txn.rowStore.query(
                    table: "vectors",
                    where: .eq(
                        Column(table: "vectors", name: "model_id"),
                        .text(kDistillationLaneModelID)
                    ),
                    orderBy: [],
                    limit: nil,
                    offset: nil
                )
                let laneItemIDs = Set(laneRows.compactMap { _textValue($0["item_id"]) })

                // ── (c) Phase 4: detect and delete orphaned lane entries ───
                //
                // Orphaned = item_id is in the lane but is NOT a factoid
                // and NOT in the drawers table at all. These are pre-existing
                // data gaps (FINDING_11X_CUSTODIAN_WALK item 1): a factoid
                // was deleted but its lane entry was not cleaned up.
                let nonFactoidLaneIDs = laneItemIDs.subtracting(factoidIDs)
                var validSourceLaneIDs: Set<String> = []
                var droppedCount = 0

                if !nonFactoidLaneIDs.isEmpty {
                    // Ask the drawers table which of these are real drawers.
                    let existingRows = try await txn.rowStore.query(
                        table: "drawers",
                        where: .in(
                            Column(table: "drawers", name: "id"),
                            nonFactoidLaneIDs.map { TypedValue.text($0) }
                        ),
                        orderBy: [],
                        limit: nil,
                        offset: nil
                    )
                    let existingDrawerIDs = Set(existingRows.compactMap { _textValue($0["id"]) })
                    // Orphans = in the lane but no drawer exists for them.
                    let orphanIDs = nonFactoidLaneIDs.subtracting(existingDrawerIDs)
                    // Valid = in the lane and already correctly keyed by
                    // a non-factoid source drawer. Leave these alone; track
                    // them to detect re-key collisions in phase 5.
                    validSourceLaneIDs = existingDrawerIDs.intersection(nonFactoidLaneIDs)

                    for orphanID in orphanIDs {
                        _ = try await txn.rowStore.delete(
                            table: "vectors",
                            where: .and([
                                .eq(Column(table: "vectors", name: "item_id"),
                                    .text(orphanID)),
                                .eq(Column(table: "vectors", name: "model_id"),
                                    .text(kDistillationLaneModelID))
                            ])
                        )
                        droppedCount += 1
                    }
                }

                // ── (c) Phase 5: re-key or drop factoid lane entries ───────
                //
                // For each factoid that has a lane entry:
                //   - exactly 1 _distilled_from tunnel → re-key item_id to
                //     the source drawer ID (unless that source already has a
                //     lane entry, which would collide on the UNIQUE constraint;
                //     in that case drop instead).
                //   - 0 or >1 tunnels (ambiguous provenance) → drop entry.
                var reKeyedCount = 0

                for factoidID in factoidIDs where laneItemIDs.contains(factoidID) {
                    let sources = tunnelMap[factoidID] ?? []
                    if sources.count == 1 {
                        let sourceID = sources[0]
                        if validSourceLaneIDs.contains(sourceID) {
                            // Collision: the source drawer already has a
                            // lane entry. Drop the factoid-keyed entry to
                            // preserve the unique constraint on (item_id,
                            // vector_index, model_id).
                            _ = try await txn.rowStore.delete(
                                table: "vectors",
                                where: .and([
                                    .eq(Column(table: "vectors", name: "item_id"),
                                        .text(factoidID)),
                                    .eq(Column(table: "vectors", name: "model_id"),
                                        .text(kDistillationLaneModelID))
                                ])
                            )
                            droppedCount += 1
                        } else {
                            // Re-key: change item_id from the factoid UUID
                            // to the source drawer UUID.
                            _ = try await txn.rowStore.update(
                                table: "vectors",
                                values: ["item_id": .text(sourceID)],
                                where: .and([
                                    .eq(Column(table: "vectors", name: "item_id"),
                                        .text(factoidID)),
                                    .eq(Column(table: "vectors", name: "model_id"),
                                        .text(kDistillationLaneModelID))
                                ])
                            )
                            // Mark this source as having a lane entry so a
                            // second factoid pointing to the same source
                            // (shouldn't happen but defensive) doesn't
                            // collide on re-key.
                            validSourceLaneIDs.insert(sourceID)
                            reKeyedCount += 1
                        }
                    } else {
                        // Ambiguous provenance (0 or >1 tunnels): drop.
                        _ = try await txn.rowStore.delete(
                            table: "vectors",
                            where: .and([
                                .eq(Column(table: "vectors", name: "item_id"),
                                    .text(factoidID)),
                                .eq(Column(table: "vectors", name: "model_id"),
                                    .text(kDistillationLaneModelID))
                            ])
                        )
                        droppedCount += 1
                    }
                }

                // ── (b) Drop all factoid drawers ───────────────────────────
                //
                // Content is never converted — these are retired view rows.
                // All associated vectors were handled above in step (c).
                let factoidDeleteCount = try await txn.rowStore.delete(
                    table: "drawers",
                    where: .eq(
                        Column(table: "drawers", name: "addedBy"),
                        .text(kDistillationDaemonAddedBy)
                    )
                )

                // ── (d) Drop all _distilled_from tunnels ───────────────────
                //
                // Provenance links retired in 1.1.x; source-drawer lineage
                // is now recorded in the drawers columns added in step (e).
                let tunnelDeleteCount = try await txn.rowStore.delete(
                    table: "tunnels",
                    where: .eq(
                        Column(table: "tunnels", name: "label"),
                        .text(kDistilledFromLabel)
                    )
                )

                return (reKeyedCount, droppedCount, factoidDeleteCount, tunnelDeleteCount)
            }

        // ── (e) Add four representation columns ────────────────────────────
        //
        // Uses its own kitID so migration state is tracked independently of
        // the LocusKit schema version. Idempotent: addColumn skips columns
        // that already exist (PersistenceKit fresh-DB invariant).
        // NULL initial values — bit 19 (hasCurrentRepresentation) in
        // operationalBitmap is already 0 on all existing rows by construction.
        try await storage.migrate(to: DistillationStorageMigrationSchema.representationColumnsDeclaration)

        log.info("""
            DistillationStorageMigration complete — \
            factoids: \(factoidDeleteCount), \
            tunnels: \(tunnelDeleteCount), \
            reKeyed: \(reKeyedCount), \
            dropped: \(droppedCount)
            """)

        return DistillationStorageMigrationReport(
            factoidDrawerCount: factoidDeleteCount,
            tunnelCount: tunnelDeleteCount,
            reKeyedLaneCount: reKeyedCount,
            droppedLaneCount: droppedCount
        )
    }

    /// Extract a text string from a TypedValue.
    /// Accepts both .text and .uuid forms; SQLite may return either for
    /// TEXT-declared columns depending on how the value was stored.
    static func _textValue(_ v: TypedValue?) -> String? {
        switch v {
        case .text(let s): return s
        case .uuid(let u): return u.uuidString
        case .none, .some(.null): return nil
        default: return nil
        }
    }
}
