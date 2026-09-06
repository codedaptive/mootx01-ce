@_exported import GeniusLocusKit

#if GLK_MIGRATION_V1_0_TO_V1_1
@_exported import GLKMigrationV1_0ToV1_1
#endif

#if GLK_MIGRATION_V1_4_TO_V1_5
@_exported import GLKMigrationV1_4ToV1_5
#endif

#if GLK_MIGRATION_V1_5_TO_V1_6
@_exported import GLKMigrationV1_5ToV1_6
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
        // Floor covers the 1.0→1.1, 1.4→1.5 and 1.5→1.6 capsules.
        .v1_0
        #elseif GLK_MIGRATION_V1_4_TO_V1_5
        // The 1.4→1.5 and 1.5→1.6 capsules are compiled. They serve every
        // stamp from 1.1 up: the 1.1→1.2 column is added by CorpusKit's own
        // ladder at open, the 1.2→1.3 column was removed by schema v19, and
        // the 1.3→1.4 setting retired with the index composition policy, so
        // nothing separates 1.1, 1.2, 1.3 and 1.4 any more.
        .v1_1
        #elseif GLK_MIGRATION_V1_5_TO_V1_6
        // Only the 1.5→1.6 column-drop capsule is compiled.
        .v1_5
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
            // `provision`. Stamp current; no historical capsules need to run.
            try await formatStore.stamp(.current, now: now)
            return GLKMigrationPreparation(
                format: .current, migrated: false, migrationState: nil)
        }

        return try await runCompiledChain(kit: kit, handle: handle, from: found, now: now)
    }

    /// Run the compiled capsules from `found` to the current format as one
    /// contiguous chain: found == v1_0 runs 1.0 -> 1.1, then 1.4 -> 1.5, then
    /// 1.5 -> 1.6; found == v1_1, v1_2, v1_3 or v1_4 runs 1.4 -> 1.5 and
    /// 1.5 -> 1.6, because no capsule separates those stamps (the 1.1 -> 1.2
    /// column is added by CorpusKit's own ladder at open, the 1.2 -> 1.3
    /// column was removed by schema v19, and the 1.3 -> 1.4 setting retired
    /// with the index composition policy); found == v1_5 runs 1.5 -> 1.6
    /// only. The 1.4 -> 1.5 ledger rewrite runs before every older capsule
    /// (the 1.0 -> 1.1 capsule opens the vector store, whose ladder must find
    /// its row under the new id); the 1.5 -> 1.6 column drop runs last and
    /// writes the final stamp. A build that compiles no chain reaching the
    /// current format cannot serve a historical estate at all.
    private static func runCompiledChain(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        from found: EstateFormatVersion,
        now: Date
    ) async throws -> GLKMigrationPreparation {
        #if GLK_MIGRATION_V1_5_TO_V1_6
        var migrated = false
        var migrationState: String? = nil
        #if GLK_MIGRATION_V1_4_TO_V1_5
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
            // SharedContentMigration stamps v1_1; the chain continues to 1.5.
        }
        #endif
        // Step 2 of the 1.4 -> 1.5 capsule: the rewrite again (a no-op after
        // the call at the top of the chain) and the v1_5 stamp, written only
        // now that every older capsule has stamped its own format.
        try await kit.runStorageLedgerKitIDMigration(handle: handle, now: now)
        #endif
        // The 1.5 -> 1.6 capsule: replay CorpusKit's checkpoint ladder (v4
        // drops corpus_index_state.composition_policy) and write the v1_6
        // stamp, the last write of the chain (I-25).
        try await kit.runIndexCompositionColumnDropMigration(handle: handle, now: now)
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
