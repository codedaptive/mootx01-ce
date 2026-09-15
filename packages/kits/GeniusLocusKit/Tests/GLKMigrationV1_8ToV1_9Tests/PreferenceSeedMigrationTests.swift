// Tests for the GLK 1.8 → 1.9 preference-seed migration capsule. Two gates:
// a 1.8 estate gains the five seeded preference keys and the recall_ratings
// table and is stamped v1_9; an existing "off" value survives the capsule.
//
// Enabled by the MigrationV1_8ToV1_9 trait (GLK_MIGRATION_V1_8_TO_V1_9 define).

#if GLK_MIGRATION_V1_8_TO_V1_9

import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import Testing
import GeniusLocusKitMigrations
@testable import GeniusLocusKit
@testable import GLKMigrationV1_8ToV1_9

private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner-mig19")
private let testNow = Date(timeIntervalSince1970: 1_790_000_000)

private func makeEstate(
    stampedAt stamp: EstateFormatVersion? = .v1_8
) async throws -> (kit: GeniusLocusKit, handle: EstateHandle, storage: any Storage) {
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
    if let stamp {
        try await EstateFormatStore(storage: storage).stamp(stamp, now: testNow)
    }
    let kit = GeniusLocusKit()
    let handle = try await kit.open(
        storage: storage, owner: testOwner, identityKeyStore: InMemoryEstateIdentityKeyStore())
    return (kit, handle, storage)
}

// MARK: - G1 a 1.8 estate gains five keys, the table and the v1_9 stamp

@Test("G1: migration seeds the five preference keys, creates recall_ratings and stamps v1_9")
func migrationSeedsFivePreferencesCreatesTableAndStampsV1_9() async throws {
    let (kit, handle, storage) = try await makeEstate()

    // Every seeded key must be absent before the capsule runs.
    for key in GeniusLocusKit.preferenceSeedKeys {
        let rawBefore = try? await kit.estate(for: handle).meta(key: key.rawValue)
        #expect(rawBefore == nil, "\(key.rawValue) must be absent before migration")
    }
    #expect(GeniusLocusKit.preferenceSeedKeys.count == 5)
    #expect(!GeniusLocusKit.preferenceSeedKeys.contains(.factExtraction))
    #expect(try await storage.currentSchemaVersion(for: "GLKRecallRatings") == 0,
            "recall_ratings must not exist before migration")

    try await kit.runPreferenceSeedMigration(handle: handle, now: testNow)

    // Each key is now physically present as "on".
    for key in GeniusLocusKit.preferenceSeedKeys {
        let rawAfter = try? await kit.estate(for: handle).meta(key: key.rawValue)
        #expect(rawAfter == "on", "migration must seed \(key.rawValue) = on")
        #expect(try await kit.provisionedPreference(key, for: handle) == .on)
    }
    // The table exists and is empty.
    #expect(try await storage.currentSchemaVersion(for: "GLKRecallRatings") == 1,
            "recall_ratings ladder must record version 1")
    #expect(try await storage.rowStore.count(table: "recall_ratings", where: nil) == 0)
    // The stamp advanced to v1_9, the current format.
    let stamp = try await EstateFormatStore(storage: storage).readIfPresent()
    #expect(stamp == .v1_9, "capsule must stamp v1_9")
    #expect(EstateFormatVersion.current == .v1_9, "current format is v1_9")
}

// MARK: - G2 an existing "off" survives

@Test("G2: migration preserves an explicit .off value and still stamps v1_9")
func migrationPreservesExplicitOff() async throws {
    let (kit, handle, storage) = try await makeEstate()

    // Pre-write .off for one seeded key through the provisioner.
    try await kit.provisionPreference(.maintenance, .off, for: handle)

    try await kit.runPreferenceSeedMigration(handle: handle, now: testNow)

    // The pre-set key keeps "off"; the other four are seeded "on".
    #expect(try await kit.provisionedPreference(.maintenance, for: handle) == .off,
            "capsule must not overwrite an existing value")
    let raw = try? await kit.estate(for: handle).meta(key: EstatePreferenceKey.maintenance.rawValue)
    #expect(raw == "off")
    for key in GeniusLocusKit.preferenceSeedKeys where key != .maintenance {
        #expect(try await kit.provisionedPreference(key, for: handle) == .on)
    }
    let stamp = try await EstateFormatStore(storage: storage).readIfPresent()
    #expect(stamp == .v1_9, "capsule stamps v1_9 even when a value is pre-set")
}

// MARK: - Chain from v1_8 reaches current through the 1.8→1.9 capsule

@Test("Chain from v1_8: reaches v1_9 with the preferences seeded")
func chainFromV1_8EstateReachesCurrentFormat() async throws {
    let (kit, handle, storage) = try await makeEstate(stampedAt: .v1_8)
    let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
    #expect(prep.format == .current)
    #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .current)
    let rawAfter = try? await kit.estate(for: handle).meta(key: EstatePreferenceKey.consolidation.rawValue)
    #expect(rawAfter == "on", "the chain must run the 1.8→1.9 capsule, which seeds the keys")
}

#endif
