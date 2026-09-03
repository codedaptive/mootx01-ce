@_exported import GeniusLocusKit

#if GLK_MIGRATION_V1_0_TO_V1_1
@_exported import GLKMigrationV1_0ToV1_1
#endif

#if GLK_MIGRATION_V1_1_TO_V1_2
@_exported import GLKMigrationV1_1ToV1_2
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
        // Floor covers both 1.0→1.1 and 1.1→1.2 capsules.
        .v1_0
        #elseif GLK_MIGRATION_V1_1_TO_V1_2
        // Floor covers the 1.1→1.2 capsule only.
        .v1_1
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
            // Fresh estate (nil stamp): provisioned without migration. Stamp current
            // and return — no historical capsules need to run.
            try await formatStore.stamp(.current, now: now)
            return GLKMigrationPreparation(
                format: .current, migrated: false, migrationState: nil)
        }

        return try await runCompiledChain(kit: kit, handle: handle, from: found, now: now)
    }

    /// Run the compiled capsules from `found` to the current format as one
    /// contiguous chain: found == v1_0 runs 1.0 -> 1.1 then 1.1 -> 1.2;
    /// found == v1_1 runs 1.1 -> 1.2 only. A build that compiles no chain
    /// reaching the current format cannot serve a historical estate at all.
    private static func runCompiledChain(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        from found: EstateFormatVersion,
        now: Date
    ) async throws -> GLKMigrationPreparation {
        #if GLK_MIGRATION_V1_1_TO_V1_2
        var migrated = false
        var migrationState: String? = nil
        #if GLK_MIGRATION_V1_0_TO_V1_1
        if found < .v1_1 {
            // Distillation storage migration (SPEC_DISTILLATION_STORAGE Appendix A.1)
            // must run before SharedContentMigration because SharedContentMigration
            // stamps the estate at v1_1 at the end of its chain. If the stamp were
            // written first, a resume after a crash during the distillation migration
            // would see v1_1 and return early without completing A.1.
            try await kit.runDistillationStorageMigration(handle: handle, now: now)
            let report = try await kit.runSharedContentMigration(handle: handle, now: now)
            migrated = report.legacyChunkCount > 0
            migrationState = report.state.rawValue
            // SharedContentMigration stamps v1_1; the chain continues to 1.2.
        }
        #endif
        // Adds composition_policy to corpus_index_state through CorpusKit's own
        // ladder (idempotent addColumn) and stamps v1_2.
        try await kit.runIndexCompositionColumnMigration(handle: handle, now: now)
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
