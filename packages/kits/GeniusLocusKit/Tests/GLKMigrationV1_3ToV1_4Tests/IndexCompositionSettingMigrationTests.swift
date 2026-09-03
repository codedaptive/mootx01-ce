#if GLK_MIGRATION_V1_3_TO_V1_4

// IndexCompositionSettingMigrationTests.swift
//
// Verifies that GLKMigrationCatalog.prepare runs the 1.3→1.4 capsule, which
// stores the index composition setting (manifest key
// index_composition_policy) on populated estates written before the setting
// existed and stamps the estate format v1_4.
//
// Tests:
//   1. v1_3-stamped estate without the setting: after prepare the setting
//      reads `.current` (no MOOT_INDEX_COMPOSITION in the environment) and
//      the estate is stamped v1_4.
//   2. Idempotence: a second prepare is a no-op that leaves the stamp at
//      v1_4 and the setting untouched.
//   3. A stored setting survives the capsule: an estate that already carries
//      cell B keeps cell B.
//   4. MOOT_INDEX_COMPOSITION set to a valid id at upgrade time seeds that
//      id; an invalid value seeds `.current`.
//   5. Fresh estate (nil stamp): prepare stamps v1_4 and seeds the setting
//      without running any capsule.
//   6. v1_0-stamped estate: the full chain (v1_0→v1_1→v1_2→v1_3→v1_4) ends
//      at v1_4 with the setting stored.

import CorpusKit
import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import Testing
import GeniusLocusKitMigrations

@testable import GeniusLocusKit
@testable import GLKMigrationV1_3ToV1_4

private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner-mig14")
private let testNow = Date(timeIntervalSince1970: 1_756_000_000)

/// An in-memory estate stamped at `stamp` (or unstamped when nil) with no
/// index composition setting, opened in a fresh GeniusLocusKit instance.
private func makeEstate(
    stampedAt stamp: EstateFormatVersion?
) async throws -> (kit: GeniusLocusKit, handle: EstateHandle, storage: InMemoryStorage) {
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
    if let stamp {
        try await EstateFormatStore(storage: storage).stamp(stamp, now: testNow)
    }
    let kit = GeniusLocusKit()
    let handle = try await kit.open(
        storage: storage,
        owner: testOwner,
        identityKeyStore: InMemoryEstateIdentityKeyStore()
    )
    return (kit, handle, storage)
}

/// Run `body` with MOOT_INDEX_COMPOSITION set to `value` (or removed when
/// nil) and restore the previous value afterwards. The suite is serialized,
/// so no other test in it observes the window.
private func withCreationSeed<T>(
    _ value: String?, _ body: () async throws -> T
) async throws -> T {
    let key = GeniusLocusKit.indexCompositionPolicyEnvironmentKey
    let previous = ProcessInfo.processInfo.environment[key]
    if let value { setenv(key, value, 1) } else { unsetenv(key) }
    defer {
        if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
    }
    return try await body()
}

@Suite("IndexCompositionSettingMigration", .serialized)
struct IndexCompositionSettingMigrationTests {

    // MARK: §1 Core: v1_3 estate gains the stored setting and stamps v1_4

    @Test
    func v1_3EstateGainsStoredSetting() async throws {
        try await withCreationSeed(nil) {
            let (kit, handle, storage) = try await makeEstate(stampedAt: .v1_3)
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == nil)

            let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
            #expect(prep.format == .v1_4)
            #expect(prep.format == .current)
            #expect(prep.migrated == false)
            #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_4)
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .current)
            // The row is the policy id, verbatim.
            let estate = try await kit.estate(for: handle)
            #expect(try await estate.meta(key: GeniusLocusKit.indexCompositionPolicyMetaKey)
                == IndexCompositionPolicy.current.id)
        }
    }

    // MARK: §2 Idempotence

    @Test
    func prepareTwiceIsNoOp() async throws {
        try await withCreationSeed(nil) {
            let (kit, handle, storage) = try await makeEstate(stampedAt: .v1_3)
            let first = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
            #expect(first.format == .v1_4)
            let second = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
            #expect(second.format == .v1_4)
            #expect(second.migrated == false)
            #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_4)
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .current)
        }
    }

    // MARK: §3 A stored setting survives the capsule

    @Test
    func storedSettingIsLeftUntouched() async throws {
        try await withCreationSeed(IndexCompositionPolicy.lexicalBaseline.id) {
            let (kit, handle, _) = try await makeEstate(stampedAt: .v1_3)
            try await kit.setIndexCompositionPolicy(.lexicalAdornments, for: handle)
            // Running the capsule directly (not through prepare) proves the
            // seed step itself leaves a stored value alone, even with a
            // different creation seed in the environment.
            try await kit.runIndexCompositionSettingMigration(handle: handle, now: testNow)
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .lexicalAdornments)
        }
    }

    // MARK: §4 The creation seed at upgrade time

    @Test
    func environmentSeedsTheSettingAtUpgradeTime() async throws {
        try await withCreationSeed(IndexCompositionPolicy.bothAdornments.id) {
            let (kit, handle, _) = try await makeEstate(stampedAt: .v1_3)
            _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .bothAdornments)
        }
        try await withCreationSeed("lex=nonsense;dense=distilled") {
            let (kit, handle, _) = try await makeEstate(stampedAt: .v1_3)
            _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .current)
        }
    }

    // MARK: §5 Fresh estate (nil stamp)

    @Test
    func freshEstateStampsCurrentAndSeedsWithoutCapsule() async throws {
        try await withCreationSeed(nil) {
            let (kit, handle, storage) = try await makeEstate(stampedAt: nil)
            let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
            #expect(prep.format == .current)
            #expect(prep.format == .v1_4)
            #expect(prep.migrated == false)
            #expect(prep.migrationState == nil)
            #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_4)
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .current)
        }
    }

    // MARK: §6 Full chain from v1_0 ends at v1_4

    #if GLK_MIGRATION_V1_0_TO_V1_1
    @Test
    func v1_0EstateRunsFullChainToCurrent() async throws {
        try await withCreationSeed(nil) {
            let (kit, handle, storage) = try await makeEstate(stampedAt: .v1_0)
            let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
            #expect(prep.format == .v1_4)
            #expect(prep.migrated == false)
            #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_4)
            #expect(try await kit.storedIndexCompositionPolicy(for: handle) == .current)
        }
    }
    #endif
}

#endif // GLK_MIGRATION_V1_3_TO_V1_4
