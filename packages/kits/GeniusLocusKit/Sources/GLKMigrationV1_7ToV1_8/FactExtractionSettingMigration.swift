// GLK estate-format 1.7 → 1.8 migration capsule.
//
// Root cause of this capsule's existence: fact extraction became a stored
// estate setting (LocusKit manifest key `fact_extraction`) with an opt-out
// model — on by default. Estates written before format 1.8 carry no such
// row, so this capsule seeds it: `"on"` when the key is absent, leaving
// any already-stored value untouched. The setting's presence then becomes
// a stamped estate-format fact (GENIUSLOCUSKIT_SPEC I-27).
//
// Enabled by the MigrationV1_7ToV1_8 / MigrationFloor1_0 / MigrationFloor1_1 /
// MigrationFloor1_2 / MigrationFloor1_3 / MigrationFloor1_4 / MigrationFloor1_5 /
// MigrationFloor1_6 / MigrationFloor1_7 Swift package traits and the
// GLK_MIGRATION_V1_7_TO_V1_8 compile-time define.
//
// Migration steps (all idempotent):
//   1. Seed the setting when absent: write `fact_extraction = "on"` only
//      when the manifest carries no `fact_extraction` key. An estate that
//      already carries a value keeps it.
//   2. Stamp the estate format v1_8.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category "GeniusLocusKit".

import Foundation
import MootProductIdentity
import GeniusLocusKit
import PersistenceKit
import os.log

private let log = Logger(
    subsystem: MootProductIdentity.Logging.subsystem,
    category: "GeniusLocusKit"
)

public extension GeniusLocusKit {

    /// Run the GLK 1.7 → 1.8 fact-extraction-setting migration for an estate.
    ///
    /// Writes `fact_extraction = "on"` to the estate manifest when the key
    /// is absent (the on-by-default seed), then stamps the estate format v1_8.
    ///
    /// Safe to call on any estate at v1_7 or later: an estate that already
    /// carries a `fact_extraction` value keeps it, and the stamp is a no-op
    /// when the estate is already at v1_8.
    ///
    /// - Parameters:
    ///   - handle: The estate handle for the storage to migrate.
    ///   - now: Wall-clock instant for the format stamp row.
    func runFactExtractionSettingMigration(
        handle: EstateHandle,
        now: Date
    ) async throws {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) }
        catch {
            throw FactExtractionSettingMigrationError.storageUnavailable(
                reason: "no storage registered for estate: \(error)")
        }

        // Step 1: seed `fact_extraction = "on"` only when the key is absent.
        // An estate that already carries a value — including `.off` — keeps it.
        // The read must propagate errors: collapsing a storage failure into
        // nil would silently write "on" over an estate that holds "off".
        let existing: String?
        do {
            existing = try await meta(in: handle, key: EstatePreferenceKey.factExtraction.rawValue)
        } catch {
            throw FactExtractionSettingMigrationError.storageUnavailable(
                reason: "fact_extraction key read failed: \(error)")
        }
        if existing == nil {
            do {
                try await provisionPreference(.factExtraction, .on, for: handle)
            } catch {
                throw FactExtractionSettingMigrationError.settingWriteFailed(
                    reason: "\(error)")
            }
        }

        // Step 2: advance the estate format to v1_8.
        let seedAction = existing == nil ? "seeded" : "left at existing value"
        do {
            try await EstateFormatStore(storage: storage).stamp(.v1_8, now: now)
            log.info("GLK 1.7→1.8 migration complete (fact_extraction \(seedAction))")
        } catch {
            throw FactExtractionSettingMigrationError.stampFailed(reason: "\(error)")
        }
    }
}

/// Errors thrown by the fact-extraction-setting migration capsule.
public enum FactExtractionSettingMigrationError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    /// The estate's storage backend could not be accessed.
    case storageUnavailable(reason: String)
    /// The setting could not be written.
    case settingWriteFailed(reason: String)
    /// The estate-format stamp could not be written.
    case stampFailed(reason: String)

    public var description: String {
        switch self {
        case let .storageUnavailable(reason):
            return "fact-extraction-setting migration: storage unavailable — \(reason)"
        case let .settingWriteFailed(reason):
            return "fact-extraction-setting migration: setting write failed — \(reason)"
        case let .stampFailed(reason):
            return "fact-extraction-setting migration: estate-format stamp failed — \(reason)"
        }
    }
}
