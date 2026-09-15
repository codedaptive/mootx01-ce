// GLK estate-format 1.8 → 1.9 migration capsule.
//
// Root cause of this capsule's existence: the five remaining estate
// preferences (`consolidation`, `contradiction_sweep`,
// `cross_encoder_routing`, `maintenance`, `adaptive_recall`) follow the
// same opt-out model as `fact_extraction` — on by default — and the recall
// rating ledger (`recall_ratings`) became a stored estate table. Estates
// written before format 1.9 carry neither, so this capsule seeds each
// absent preference as `"on"`, leaving any already-stored value untouched,
// and creates the empty rating table. Both then become stamped
// estate-format facts (GENIUSLOCUSKIT_SPEC I-28).
//
// Enabled by the MigrationV1_8ToV1_9 / MigrationFloor1_0 / MigrationFloor1_1 /
// MigrationFloor1_2 / MigrationFloor1_3 / MigrationFloor1_4 / MigrationFloor1_5 /
// MigrationFloor1_6 / MigrationFloor1_7 Swift package traits and the
// GLK_MIGRATION_V1_8_TO_V1_9 compile-time define.
//
// Migration steps (all idempotent):
//   1. Seed each preference when absent: for every `EstatePreferenceKey`
//      except `.factExtraction` (seeded by the 1.7 → 1.8 capsule), write
//      `"on"` only when the manifest carries no value for the key. An estate
//      that already carries a value keeps it.
//   2. Create the `recall_ratings` table when absent by applying LocusKit's
//      `RecallRating.schema` — the one declaration of the table, the same
//      value `DrawerStore` applies on first use on a fresh estate — through
//      the storage schema ladder.
//   3. Stamp the estate format v1_9.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category "GeniusLocusKit".

import Foundation
import MootProductIdentity
import GeniusLocusKit
import LocusKit
import PersistenceKit
import os.log

private let log = Logger(
    subsystem: MootProductIdentity.Logging.subsystem,
    category: "GeniusLocusKit"
)

/// The capsule's handle on the recall rating ledger's schema. The table is
/// declared once, in LocusKit (`RecallRating.schema`); this is the same
/// value, so the capsule and `DrawerStore`'s first-use creation apply an
/// identical kit id, version and column set and `migrate(to:)` is a no-op
/// once either has created the table.
public enum RecallRatingsSchema {
    /// The `recall_ratings` table declaration, ladder version 1.
    public static var schemaDeclaration: SchemaDeclaration { RecallRating.schema }
}

public extension GeniusLocusKit {

    /// The preference keys the 1.8 → 1.9 capsule seeds: every key except
    /// `.factExtraction` (seeded by the 1.7 → 1.8 capsule) and `.factExtractor`
    /// (absent reads as `.nuextract`; no seeding capsule for the extractor choice).
    static var preferenceSeedKeys: [EstatePreferenceKey] {
        EstatePreferenceKey.allCases.filter { $0 != .factExtraction && $0 != .factExtractor }
    }

    /// Run the GLK 1.8 → 1.9 preference-seed migration for an estate.
    ///
    /// Writes `"on"` to the estate manifest for each of the five seeded
    /// preference keys whose value is absent (the on-by-default seed),
    /// creates the `recall_ratings` table when absent, then stamps the
    /// estate format v1_9.
    ///
    /// Safe to call on any estate at v1_8 or later: an estate that already
    /// carries a value for a key keeps it, the table creation is a no-op
    /// once the table exists, and the stamp is a no-op when the estate is
    /// already at v1_9.
    ///
    /// - Parameters:
    ///   - handle: The estate handle for the storage to migrate.
    ///   - now: Wall-clock instant for the format stamp row.
    func runPreferenceSeedMigration(
        handle: EstateHandle,
        now: Date
    ) async throws {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) }
        catch {
            throw PreferenceSeedMigrationError.storageUnavailable(
                reason: "no storage registered for estate: \(error)")
        }

        // Step 1: seed each key as "on" only when the key is absent. An
        // estate that already carries a value — including `.off` — keeps it.
        // The read must propagate errors: collapsing a storage failure into
        // nil would silently write "on" over an estate that holds "off".
        var seeded = 0
        for key in Self.preferenceSeedKeys {
            let existing: String?
            do {
                existing = try await meta(in: handle, key: key.rawValue)
            } catch {
                throw PreferenceSeedMigrationError.storageUnavailable(
                    reason: "\(key.rawValue) key read failed: \(error)")
            }
            if existing == nil {
                do {
                    try await provisionPreference(key, .on, for: handle)
                    seeded += 1
                } catch {
                    throw PreferenceSeedMigrationError.settingWriteFailed(
                        reason: "\(key.rawValue): \(error)")
                }
            }
        }

        // Step 2: the rating table, from LocusKit's single declaration. The
        // schema ladder creates it when absent and leaves it untouched when
        // the ledger already records version 1.
        do {
            try await storage.migrate(to: RecallRatingsSchema.schemaDeclaration)
        } catch {
            throw PreferenceSeedMigrationError.tableCreateFailed(reason: "\(error)")
        }

        // Step 3: advance the estate format to v1_9.
        do {
            try await EstateFormatStore(storage: storage).stamp(.v1_9, now: now)
            log.info("GLK 1.8→1.9 migration complete (\(seeded, privacy: .public) preferences seeded)")
        } catch {
            throw PreferenceSeedMigrationError.stampFailed(reason: "\(error)")
        }
    }
}

/// Errors thrown by the preference-seed migration capsule.
public enum PreferenceSeedMigrationError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    /// The estate's storage backend could not be accessed.
    case storageUnavailable(reason: String)
    /// A preference could not be written.
    case settingWriteFailed(reason: String)
    /// The `recall_ratings` table could not be created.
    case tableCreateFailed(reason: String)
    /// The estate-format stamp could not be written.
    case stampFailed(reason: String)

    public var description: String {
        switch self {
        case let .storageUnavailable(reason):
            return "preference-seed migration: storage unavailable — \(reason)"
        case let .settingWriteFailed(reason):
            return "preference-seed migration: setting write failed — \(reason)"
        case let .tableCreateFailed(reason):
            return "preference-seed migration: recall_ratings table create failed — \(reason)"
        case let .stampFailed(reason):
            return "preference-seed migration: estate-format stamp failed — \(reason)"
        }
    }
}
