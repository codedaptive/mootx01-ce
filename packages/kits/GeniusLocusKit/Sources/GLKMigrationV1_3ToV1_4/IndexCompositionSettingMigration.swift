// GLK estate-format 1.3 → 1.4 migration capsule.
//
// Root cause of this capsule's existence: the index composition policy
// (which text each search index lane is built from) became a stored estate
// setting, LocusKit manifest key `index_composition_policy`, read by
// GeniusLocusKit at every open. Estates written before format 1.4 carry no
// such row, so this capsule seeds it: the creation-time seed,
// MOOT_INDEX_COMPOSITION when it is set to a valid policy id at upgrade
// time, else `IndexCompositionPolicy.current`, the policy their rows were
// built under. The setting's presence then becomes a stamped estate-format
// fact (I-23). No table, column, or row of the index changes.
//
// Enabled by the MigrationV1_3ToV1_4 / MigrationFloor1_0 / MigrationFloor1_1 /
// MigrationFloor1_2 / MigrationFloor1_3 Swift package traits and the
// GLK_MIGRATION_V1_3_TO_V1_4 compile-time define.
//
// Migration steps (all idempotent):
//   1. Seed the setting when absent through
//      `GeniusLocusKit.seedIndexCompositionPolicyIfAbsent(for:)`; a stored
//      setting is left untouched.
//   2. Stamp the estate format v1_4.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category "GeniusLocusKit".

import CorpusKit
import Foundation
import GeniusLocusKit
import PersistenceKit
import os.log

private let log = Logger(
    subsystem: "com.mootx01.kit",
    category: "GeniusLocusKit"
)

public extension GeniusLocusKit {

    /// Run the GLK 1.3 → 1.4 index-composition-setting migration for an estate.
    ///
    /// Stores the index composition setting when the estate carries none
    /// (the creation-time seed: MOOT_INDEX_COMPOSITION when set to a valid
    /// policy id, else `.current`), then stamps the estate format v1_4.
    ///
    /// Safe to call on any estate at v1_3 or later: a stored setting is left
    /// untouched and the stamp is a no-op when the estate is already at v1_4.
    ///
    /// - Parameters:
    ///   - handle: The estate handle for the storage to migrate.
    ///   - now: Wall-clock instant for the format stamp row.
    func runIndexCompositionSettingMigration(
        handle: EstateHandle,
        now: Date
    ) async throws {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) }
        catch {
            throw IndexCompositionSettingMigrationError.storageUnavailable(
                reason: "no storage registered for estate: \(error)")
        }

        // Step 1: seed the setting when absent. The seed reads the process
        // environment once, here, at upgrade time.
        let policy: IndexCompositionPolicy
        do {
            policy = try await seedIndexCompositionPolicyIfAbsent(for: handle)
        } catch {
            throw IndexCompositionSettingMigrationError.settingWriteFailed(reason: "\(error)")
        }

        // Step 2: advance the estate format to v1_4.
        do {
            try await EstateFormatStore(storage: storage).stamp(.v1_4, now: now)
            log.info("GLK 1.3→1.4 migration complete (index composition policy \(policy.id, privacy: .public))")
        } catch {
            throw IndexCompositionSettingMigrationError.stampFailed(reason: "\(error)")
        }
    }
}

/// Errors thrown by the index-composition-setting migration capsule.
public enum IndexCompositionSettingMigrationError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    /// The estate's storage backend could not be accessed.
    case storageUnavailable(reason: String)
    /// The setting could not be read or written.
    case settingWriteFailed(reason: String)
    /// The estate-format stamp could not be written.
    case stampFailed(reason: String)

    public var description: String {
        switch self {
        case let .storageUnavailable(reason):
            return "index-composition-setting migration: storage unavailable — \(reason)"
        case let .settingWriteFailed(reason):
            return "index-composition-setting migration: setting write failed — \(reason)"
        case let .stampFailed(reason):
            return "index-composition-setting migration: estate-format stamp failed — \(reason)"
        }
    }
}
