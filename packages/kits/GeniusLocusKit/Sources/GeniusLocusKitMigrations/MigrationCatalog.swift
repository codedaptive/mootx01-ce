@_exported import GeniusLocusKit

#if GLK_MIGRATION_V1_0_TO_V1_1
@_exported import GLKMigrationV1_0ToV1_1
#endif

#if GLK_MIGRATION_V1_1_TO_V1_2
@_exported import GLKMigrationV1_1ToV1_2
#endif

#if GLK_MIGRATION_V1_3_TO_V1_4
@_exported import GLKMigrationV1_3ToV1_4
#endif

#if GLK_MIGRATION_V1_4_TO_V1_5
@_exported import GLKMigrationV1_4ToV1_5
#endif

import Foundation

/// Errors owned by the optional migration catalog. The current GLK runtime
/// never contains this historical compatibility policy.
public enum GLKMigrationCatalogError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case noHistoricalMigrationsCompiled(current: EstateFormatVersion)
    case belowCompiledFloor(found: EstateFormatVersion, floor: EstateFormatVersion)
    case unsupportedFuture(found: EstateFormatVersion, current: EstateFormatVersion)

    public var description: String {
        switch self {
        case let .noHistoricalMigrationsCompiled(current):
            return "this GLK \(current) build contains no historical migration capsules"
        case let .belowCompiledFloor(found, floor):
            return "estate format \(found) is below this build's compiled migration floor \(floor)"
        case let .unsupportedFuture(found, current):
            return "estate format \(found) is newer than this GLK \(current) runtime"
        }
    }
}

public struct GLKMigrationPreparation: Sendable, Equatable {
    public let format: EstateFormatVersion
    public let migrated: Bool
    public let migrationState: String?

    public init(format: EstateFormatVersion, migrated: Bool, migrationState: String?) {
        self.format = format
        self.migrated = migrated
        self.migrationState = migrationState
    }
}

/// Build-time migration catalog. Traits select concrete capsule targets; an
/// ordinary `GeniusLocusKit` consumer never builds this module or its history.
public enum GLKMigrationCatalog {
    public static var compiledFloor: EstateFormatVersion? {
        #if GLK_MIGRATION_V1_0_TO_V1_1
        // Floor covers the 1.0→1.1, 1.1→1.2, 1.3→1.4, and 1.4→1.5 capsules.
        .v1_0
        #elseif GLK_MIGRATION_V1_1_TO_V1_2
        // Floor covers the 1.1→1.2, 1.3→1.4, and 1.4→1.5 capsules.
        .v1_1
        #elseif GLK_MIGRATION_V1_3_TO_V1_4
        // Floor covers the 1.3→1.4 and 1.4→1.5 capsules. It also serves a
        // 1.2-stamped estate: the 1.2→1.3 step added a LocusKit column that
        // schema v19 removed, so nothing separates 1.2 from 1.3 any more and
        // the 1.3→1.4 capsule runs directly on either stamp.
        .v1_2
        #elseif GLK_MIGRATION_V1_4_TO_V1_5
        // Floor covers the 1.4→1.5 capsule only.
        .v1_4
        #else
        nil
        #endif
    }

    /// Bring an opened Locus estate to the current format before the caller
    /// invokes `wireGLKSubstores`. Fresh, unstamped estates are stamped current
    /// without creating a migration record. Historical estates run the
    /// contiguous compiled chain and return only after the five-signal lane is
    /// verified; physical reclamation remains separately retryable.
    ///
    /// Geometry normalization runs FIRST — before the format check — because
    /// VACUUM (called by later capsules) fails on estates with nonzero SQLite
    /// reserved-bytes-per-page. Errors are parked by the capsule so a geometry
    /// failure never blocks the estate from opening.
    public static func prepare(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        now: Date = Date()
    ) async throws -> GLKMigrationPreparation {
        let storage = try await kit.migrationStorage(for: handle)

        // Step 0: geometry normalization (format-agnostic, must precede VACUUM).
        _ = await GeometryNormalizationCapsule.run(storage: storage)

        let formatStore = EstateFormatStore(storage: storage)
        // Read the stamped estate format, or stamp current for fresh estates.
        let found: EstateFormatVersion
        if let stamped = try await formatStore.readIfPresent() {
            if stamped == .current {
                return GLKMigrationPreparation(
                    format: stamped, migrated: false, migrationState: nil)
            }
            if stamped > .current {
                throw GLKMigrationCatalogError.unsupportedFuture(
                    found: stamped, current: .current)
            }
            if let floor = compiledFloor, stamped < floor {
                throw GLKMigrationCatalogError.belowCompiledFloor(
                    found: stamped, floor: floor)
            }
            // found is between the compiled floor and current — run historical chain.
            found = stamped
        } else {
            // Fresh estate (nil stamp): created by a bare open without
            // `provision`. Store the index composition setting the estate is
            // born with (the creation-time seed), then stamp current — the
            // same order as the 1.3 → 1.4 capsule, so a stamp never precedes
            // the setting it vouches for. No historical capsules need to run.
            try await kit.seedIndexCompositionPolicyIfAbsent(for: handle)
            try await formatStore.stamp(.current, now: now)
            return GLKMigrationPreparation(
                format: .current, migrated: false, migrationState: nil)
        }

        return try await runCompiledChain(kit: kit, handle: handle, from: found, now: now)
    }

    /// Run the compiled capsules from `found` to the current format as one
    /// contiguous chain: found == v1_0 runs 1.0 -> 1.1, 1.1 -> 1.2, 1.3 -> 1.4,
    /// then 1.4 -> 1.5; found == v1_1 starts at 1.1 -> 1.2; found == v1_2 or
    /// v1_3 starts at 1.3 -> 1.4 (the 1.2 -> 1.3 step added a LocusKit column
    /// that schema v19 removed, so it no longer exists); found == v1_4 runs
    /// 1.4 -> 1.5 only. The 1.4 -> 1.5 ledger rewrite runs
    /// before every older capsule (the 1.0 -> 1.1 capsule opens the vector
    /// store, whose ladder must find its row under the new id) and its stamp
    /// is written last. A build that compiles no chain reaching the current
    /// format cannot serve a historical estate at all.
    private static func runCompiledChain(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        from found: EstateFormatVersion,
        now: Date
    ) async throws -> GLKMigrationPreparation {
        #if GLK_MIGRATION_V1_4_TO_V1_5
        var migrated = false
        var migrationState: String? = nil
        // Step 1 of the 1.4 -> 1.5 capsule, ahead of the chain: move the
        // vector tier's ledger rows to their SynapseKit ids so no capsule
        // below, and no store wired after this call, opens under the old id
        // and replays the vector ladder (I-24). Idempotent; stamps nothing.
        _ = try await kit.rewriteStorageLedgerKitIDs(handle: handle)
        #if GLK_MIGRATION_V1_0_TO_V1_1
        if found < .v1_1 {
            // The shared-content migration moves the legacy `chunks` copy lane
            // onto the shared-content layout and stamps v1_1 at the end of its
            // chain. The retired distilled-view rows of a 1.0 estate are
            // ordinary drawer rows to it; schema v19 carries no distilled
            // columns, so nothing rewrites them here.
            let report = try await kit.runSharedContentMigration(handle: handle, now: now)
            migrated = report.legacyChunkCount > 0
            migrationState = report.state.rawValue
            // SharedContentMigration stamps v1_1; the chain continues to 1.2.
        }
        #endif
        #if GLK_MIGRATION_V1_1_TO_V1_2
        if found < .v1_2 {
            // Adds composition_policy to corpus_index_state through CorpusKit's
            // own ladder (idempotent addColumn) and stamps v1_2; the chain
            // continues to 1.3.
            try await kit.runIndexCompositionColumnMigration(handle: handle, now: now)
        }
        #endif
        #if GLK_MIGRATION_V1_3_TO_V1_4
        if found < .v1_4 {
            // Stores the index composition setting when the estate carries
            // none (the creation-time seed) and stamps v1_4; the chain
            // continues to 1.5. Runs on 1.2- and 1.3-stamped estates alike.
            try await kit.runIndexCompositionSettingMigration(handle: handle, now: now)
        }
        #endif
        // Step 2 of the 1.4 -> 1.5 capsule: the rewrite again (a no-op after
        // the call at the top of the chain) and the v1_5 stamp, written only
        // now that every older capsule has stamped its own format.
        try await kit.runStorageLedgerKitIDMigration(handle: handle, now: now)
        return GLKMigrationPreparation(
            format: .current,
            migrated: migrated,
            migrationState: migrationState)
        #else
        // No compiled chain reaches the current format, so a historical estate
        // cannot be served by this build.
        throw GLKMigrationCatalogError.noHistoricalMigrationsCompiled(current: .current)
        #endif
    }
}
