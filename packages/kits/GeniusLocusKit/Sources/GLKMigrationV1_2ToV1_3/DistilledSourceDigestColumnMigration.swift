// GLK estate-format 1.2 → 1.3 migration capsule.
//
// Root cause of this capsule's existence: LocusKitSchema reached version 18
// with an addColumn migration for `distilled_source_digest TEXT NULL` on the
// drawers table — the SHA-256 of the complete original content that the
// stored distilled representation was rendered from. A row whose digest is
// NULL or differs from the digest of its content is stale by definition and
// regenerates on the next sweep, so the column has to exist on every estate
// before the currency rule can be evaluated. LocusKit replays its own ladder
// at every `Estate.open`, but the composite declarations that populated
// estates are also opened through (`GeniusLocusKitSchema
// .estateSchemaDeclaration`) carry an empty migrations list and record only
// the bumped composite version. This capsule makes the column's presence a
// stamped estate-format fact (I-22) by replaying the component kit's own
// schema ladder and re-applying the composite version record.
//
// Enabled by the MigrationV1_2ToV1_3 / MigrationFloor1_0 / MigrationFloor1_1 /
// MigrationFloor1_2 Swift package traits and the GLK_MIGRATION_V1_2_TO_V1_3
// compile-time define.
//
// Migration steps (all idempotent via PersistenceKit's addColumn / CREATE IF NOT EXISTS):
//   1. Apply LocusKitSchema.schema through its own ladder. This replays the
//      v17→v18 migration: addColumn distilled_source_digest.
//   2. Apply GeniusLocusKitSchema.estateSchemaDeclaration so the composite
//      version record ("GeniusLocusKit") reflects the bumped component sum.
//      No-op on tables.
//   3. Stamp the estate format v1_3.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category "GeniusLocusKit".

import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import os.log

private let log = Logger(
    subsystem: "com.mootx01.kit",
    category: "GeniusLocusKit"
)

public extension GeniusLocusKit {

    /// Run the GLK 1.2 → 1.3 distilled-source-digest-column migration for an estate.
    ///
    /// Applies `LocusKitSchema.schema` through its component kit ladder
    /// (idempotent addColumn of `distilled_source_digest`), then re-applies
    /// `GeniusLocusKitSchema.estateSchemaDeclaration` to update the composite
    /// version record, then stamps the estate format v1_3.
    ///
    /// Safe to call on any estate at v1_2 or later: the addColumn is
    /// idempotent and the stamp is a no-op when the estate is already at v1_3.
    ///
    /// - Parameters:
    ///   - handle: The estate handle for the storage to migrate.
    ///   - now: Wall-clock instant for the format stamp row.
    func runDistilledSourceDigestColumnMigration(
        handle: EstateHandle,
        now: Date
    ) async throws {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) }
        catch {
            throw DistilledSourceDigestColumnMigrationError.storageUnavailable(
                reason: "no storage registered for estate: \(error)")
        }

        // Step 1: apply the component kit's own schema ladder.
        // PersistenceKit's migrate(to:) runs v17→v18 (addColumn
        // distilled_source_digest) only when the stored kit version is below
        // 18; idempotent otherwise.
        do {
            try await storage.migrate(to: LocusKitSchema.schema)
        } catch {
            throw DistilledSourceDigestColumnMigrationError.schemaApplicationFailed(
                target: LocusKitSchema.kitID, reason: "\(error)")
        }

        // Step 2: re-apply the composite declaration so PersistenceKit
        // updates the composite version record ("GeniusLocusKit"). The tables
        // and indices already exist — this is a version-record update only.
        do {
            try await storage.migrate(to: GeniusLocusKitSchema.estateSchemaDeclaration)
        } catch {
            throw DistilledSourceDigestColumnMigrationError.schemaApplicationFailed(
                target: GeniusLocusKitSchema.kitID, reason: "\(error)")
        }

        // Step 3: advance the estate format to v1_3.
        do {
            try await EstateFormatStore(storage: storage).stamp(.v1_3, now: now)
            log.info("GLK 1.2→1.3 migration complete")
        } catch {
            throw DistilledSourceDigestColumnMigrationError.stampFailed(reason: "\(error)")
        }
    }
}

/// Errors thrown by the distilled-source-digest-column migration capsule.
public enum DistilledSourceDigestColumnMigrationError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    /// The estate's storage backend could not be accessed.
    case storageUnavailable(reason: String)
    /// A schema application step failed.
    case schemaApplicationFailed(target: String, reason: String)
    /// The estate-format stamp could not be written.
    case stampFailed(reason: String)

    public var description: String {
        switch self {
        case let .storageUnavailable(reason):
            return "distilled-source-digest-column migration: storage unavailable — \(reason)"
        case let .schemaApplicationFailed(target, reason):
            return "distilled-source-digest-column migration: schema application failed for \(target) — \(reason)"
        case let .stampFailed(reason):
            return "distilled-source-digest-column migration: estate-format stamp failed — \(reason)"
        }
    }
}
