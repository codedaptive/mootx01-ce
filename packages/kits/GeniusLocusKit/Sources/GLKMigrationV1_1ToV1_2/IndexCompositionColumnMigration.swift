// GLK estate-format 1.1 → 1.2 migration capsule.
//
// Root cause of this capsule's existence: CorpusIndexStateStore.schemaDeclaration
// reached version 3 with an addColumn migration for `composition_policy TEXT NOT NULL
// DEFAULT ''`. Populated estates open CorpusKit only through the composite
// declarations (CorpusSchemaProfile.attachedDeclaration, GeniusLocusKitSchema
// .estateSchemaDeclaration), which carry an empty migrations list. PersistenceKit
// records the bumped composite version and has nothing to replay, so the column is
// never added. Fresh estates get the column from CREATE TABLE. This capsule fixes
// populated estates by replaying the component kit's own schema ladder.
//
// Enabled by the MigrationV1_1ToV1_2 / MigrationFloor1_0 / MigrationFloor1_1
// Swift package traits and the GLK_MIGRATION_V1_1_TO_V1_2 compile-time define.
//
// Migration steps (all idempotent via PersistenceKit's addColumn / CREATE IF NOT EXISTS):
//   1. Apply CorpusIndexStateStore.schemaDeclaration through its own ladder.
//      This replays the v2→v3 migration: addColumn composition_policy.
//   2. Apply CorpusSchemaProfile.attachedDeclaration so the composite version
//      record ("CorpusKitAttached") is updated. No-op on tables.
//   3. Stamp the estate format v1_2.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category "GeniusLocusKit".

import Foundation
import GeniusLocusKit
import CorpusKit
import PersistenceKit
import os.log

private let log = Logger(
    subsystem: "com.mootx01.kit",
    category: "GeniusLocusKit"
)

public extension GeniusLocusKit {

    /// Run the GLK 1.1 → 1.2 index-composition-column migration for an estate.
    ///
    /// Applies `CorpusIndexStateStore.schemaDeclaration` through its component
    /// kit ladder (idempotent addColumn), then re-applies
    /// `CorpusSchemaProfile.attachedDeclaration` to update the composite version
    /// record, then stamps the estate format v1_2.
    ///
    /// Safe to call on any estate at v1_1 or later: the addColumn is
    /// idempotent and the stamp is a no-op when the estate is already at v1_2.
    ///
    /// - Parameters:
    ///   - handle: The estate handle for the storage to migrate.
    ///   - now: Wall-clock instant for the format stamp row.
    func runIndexCompositionColumnMigration(
        handle: EstateHandle,
        now: Date
    ) async throws {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) }
        catch {
            throw IndexCompositionColumnMigrationError.storageUnavailable(
                reason: "no storage registered for estate: \(error)")
        }

        // Step 1: apply the component kit's own schema ladder.
        // PersistenceKit's migrate(to:) runs v2→v3 (addColumn composition_policy)
        // only when the stored kit version is below 3; idempotent otherwise.
        do {
            try await storage.migrate(to: CorpusIndexStateStore.schemaDeclaration)
        } catch {
            throw IndexCompositionColumnMigrationError.schemaApplicationFailed(
                target: "CorpusKitIndexState", reason: "\(error)")
        }

        // Step 2: re-apply the attached composite declaration so PersistenceKit
        // updates the composite version record ("CorpusKitAttached"). The tables
        // and indices already exist — this is a version-record update only.
        do {
            try await storage.migrate(to: CorpusSchemaProfile.attachedDeclaration)
        } catch {
            throw IndexCompositionColumnMigrationError.schemaApplicationFailed(
                target: "CorpusKitAttached", reason: "\(error)")
        }

        // Step 3: advance the estate format to v1_2.
        do {
            try await EstateFormatStore(storage: storage).stamp(.v1_2, now: now)
            log.info("GLK 1.1→1.2 migration complete")
        } catch {
            throw IndexCompositionColumnMigrationError.stampFailed(reason: "\(error)")
        }
    }
}

/// Errors thrown by the index-composition-column migration capsule.
public enum IndexCompositionColumnMigrationError: Error, Sendable, Equatable,
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
            return "index-composition-column migration: storage unavailable — \(reason)"
        case let .schemaApplicationFailed(target, reason):
            return "index-composition-column migration: schema application failed for \(target) — \(reason)"
        case let .stampFailed(reason):
            return "index-composition-column migration: estate-format stamp failed — \(reason)"
        }
    }
}
