// GLK estate-format 1.5 → 1.6 migration capsule.
//
// Root cause of this capsule's existence: `corpus_index_state.composition_policy`
// (CorpusKit checkpoint schema v3) carried the index composition policy id, a
// knob that retired when every id came to compose the same document. The
// column was left declared because populated estates carry it; Bob ruled it
// dropped. CorpusKit's checkpoint ladder drops it at v4, but a populated
// estate opens CorpusKit only through the composite estate declarations,
// which carry no migrations, so the ladder never runs at serve open. This
// capsule replays the checkpoint ladder on the estate storage through
// `Storage.migrate(to: CorpusIndexStateStore.schemaDeclaration)` and stamps
// the estate format v1_6 (GENIUSLOCUSKIT_SPEC I-25).
//
// Why the replay is safe on every estate shape:
//   - An estate whose ledger records `CorpusKitIndexState` at v3 (a 1.0 estate
//     the shared-content capsule walked) replays v3 → v4: the drop.
//   - An estate with no `CorpusKitIndexState` row (created through the
//     composite declarations) is treated as fresh: PersistenceKit creates
//     the tables at the v4 layout with IF NOT EXISTS (the existing table is
//     left as it is) and replays the ladder from version 0; addColumn skips
//     the columns already present, and the v3 → v4 drop removes the column.
//   - A second run finds the column gone; PersistenceKit dropColumn is
//     idempotent (the addColumn rule in reverse), so the run is a no-op.
//
// Placement in the chain: LAST. The 1.4 → 1.5 capsule stamps v1_5 before
// this one runs, so a crash mid-chain never leaves an estate stamped v1_6
// with an older capsule's work undone. `GLKMigrationCatalog.prepare` calls
// `runIndexCompositionColumnDropMigration` after the 1.4 → 1.5 stamp; the
// capsule runs before `wireSubstores`, which is where the engine opens the
// composite declaration over the migrated table.
//
// Enabled by the MigrationV1_5ToV1_6 trait and every MigrationFloor trait
// (floors 1.1 through 1.4 compile it with the 1.4 → 1.5 capsule; floor 1.5
// compiles it alone) and the GLK_MIGRATION_V1_5_TO_V1_6 compile-time define.
//
// Migration steps (all idempotent):
//   1. Replay CorpusKit's checkpoint ladder to v4 on the estate storage.
//   2. Stamp the estate format v1_6.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category "GeniusLocusKit".

import CorpusKit
import Foundation
import MootProductIdentity
import GeniusLocusKit
import PersistenceKit
import os.log

private let log = Logger(
    subsystem: MootProductIdentity.Logging.subsystem,
    category: "GeniusLocusKit"
)

/// What the capsule left behind.
public struct IndexCompositionColumnDropMigrationReport: Sendable, Equatable {
    /// The `CorpusKitIndexState` ledger version after the replay: the
    /// checkpoint schema version whose layout has no `composition_policy`.
    public let checkpointSchemaVersion: Int
    /// The estate format the capsule stamped.
    public let format: EstateFormatVersion

    public init(checkpointSchemaVersion: Int, format: EstateFormatVersion) {
        self.checkpointSchemaVersion = checkpointSchemaVersion
        self.format = format
    }
}

public extension GeniusLocusKit {

    /// Run the GLK 1.5 → 1.6 index-composition column-drop migration for an
    /// estate.
    ///
    /// Replays CorpusKit's checkpoint ladder (v4 drops
    /// `corpus_index_state.composition_policy`) on the estate storage, then
    /// stamps the estate format v1_6. Safe to call on any estate at v1_5 or
    /// later: the replay is a no-op once the column is gone and the stamp is a
    /// no-op when the estate is already at v1_6.
    ///
    /// - Parameters:
    ///   - handle: The estate handle for the storage to migrate.
    ///   - now: Wall-clock instant for the format stamp row.
    /// - Returns: The checkpoint ledger version after the replay and the
    ///   stamped format.
    @discardableResult
    func runIndexCompositionColumnDropMigration(
        handle: EstateHandle,
        now: Date
    ) async throws -> IndexCompositionColumnDropMigrationReport {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) }
        catch {
            throw IndexCompositionColumnDropMigrationError.storageUnavailable(
                reason: "no storage registered for estate: \(error)")
        }

        // Step 1: the checkpoint ladder to v4 (idempotent).
        let declaration = CorpusIndexStateStore.schemaDeclaration
        do { try await storage.migrate(to: declaration) }
        catch {
            throw IndexCompositionColumnDropMigrationError.ladderFailed(reason: "\(error)")
        }
        let version: Int
        do { version = try await storage.currentSchemaVersion(for: declaration.kitID) }
        catch {
            throw IndexCompositionColumnDropMigrationError.ladderFailed(
                reason: "checkpoint ledger read failed: \(error)")
        }

        // Step 2: advance the estate format to v1_6.
        do {
            try await EstateFormatStore(storage: storage).stamp(.v1_6, now: now)
        } catch {
            throw IndexCompositionColumnDropMigrationError.stampFailed(reason: "\(error)")
        }
        log.info("GLK 1.5→1.6 migration complete (CorpusKitIndexState v\(version, privacy: .public))")
        return IndexCompositionColumnDropMigrationReport(
            checkpointSchemaVersion: version, format: .v1_6)
    }
}

/// Errors thrown by the index-composition column-drop migration capsule.
public enum IndexCompositionColumnDropMigrationError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    /// The estate's storage backend could not be accessed.
    case storageUnavailable(reason: String)
    /// CorpusKit's checkpoint ladder could not be replayed or its ledger read.
    case ladderFailed(reason: String)
    /// The estate-format stamp could not be written.
    case stampFailed(reason: String)

    public var description: String {
        switch self {
        case let .storageUnavailable(reason):
            return "index-composition column-drop migration: storage unavailable — \(reason)"
        case let .ladderFailed(reason):
            return "index-composition column-drop migration: checkpoint ladder failed — \(reason)"
        case let .stampFailed(reason):
            return "index-composition column-drop migration: estate-format stamp failed — \(reason)"
        }
    }
}
