// Tests for the GLK 1.7 → 1.8 migration capsule and the EstatePreference
// accessor pair on the fact_extraction key. Seven tests: the six capsule gates G1–G6 (enum default,
// absent-means-on seeding, explicit-off preservation, stamp advance,
// idempotent re-run, unrecognised-value fallback) and one chain test (an
// estate stamped v1_7 driven through GLKMigrationCatalog.prepare reaches
// .current with the key seeded).
//
// The catalog's 1.6→1.7 vacuum guard (`found < .v1_7`) is gated where the
// vacuum fixture lives: WholeRecordFloatVacuumMigrationTests §8 seeds the
// rows the vacuum would delete and asserts they survive a chain from v1_7.
// This target carries no SynapseKit or CorpusKit product and cannot seed
// those rows.
//
// Enabled by the MigrationV1_7ToV1_8 trait (GLK_MIGRATION_V1_7_TO_V1_8 define).

#if GLK_MIGRATION_V1_7_TO_V1_8

import Foundation
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import Testing
import GeniusLocusKitMigrations
@testable import GeniusLocusKit
@testable import GLKMigrationV1_7ToV1_8

private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner-mig18")
private let testNow = Date(timeIntervalSince1970: 1_790_000_000)

private func makeEstate(
    stampedAt stamp: EstateFormatVersion? = .v1_7
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

// MARK: - G1 EstatePreferenceKey defaultValue

@Test("G1: EstatePreferenceKey.defaultValue returns the correct per-key default")
func estatePreferenceKeyDefaultValue() {
    // The six on/off switches default to .on; the extractor key defaults to .nuextract.
    #expect(EstatePreferenceKey.factExtraction.defaultValue == .on)
    #expect(EstatePreferenceKey.factExtraction.defaultValue.rawValue == "on")
    #expect(EstatePreferenceKey.factExtractor.defaultValue == .nuextract)
    #expect(EstatePreferenceKey.factExtraction.rawValue == "fact_extraction")
    #expect(EstatePreferenceKey.factExtractor.rawValue == "fact_extractor")
    // Roundtrip the rawValue initializer for on/off.
    #expect(EstatePreferenceValue(rawValue: "on") == .on)
    #expect(EstatePreferenceValue(rawValue: "off") == .off)
    // Roundtrip for the extractor values.
    #expect(EstatePreferenceValue(rawValue: "nuextract") == .nuextract)
    #expect(EstatePreferenceValue(rawValue: "apple") == .apple)
    #expect(EstatePreferenceValue(rawValue: "garbage") == nil)
}

// MARK: - G2 absent-means-on seeding

@Test("G2: migration seeds fact_extraction=on when the key is absent")
func migrationSeedsFactExtractionWhenAbsent() async throws {
    let (kit, handle, storage) = try await makeEstate()

    // The key must be absent before migration runs.
    let rawBefore = try? await kit.estate(for: handle).meta(key: EstatePreferenceKey.factExtraction.rawValue)
    #expect(rawBefore == nil, "key must be absent before migration")

    // The public accessor returns .on even when absent (absent-means-on).
    let settingBefore = try await kit.provisionedPreference(.factExtraction, for: handle)
    #expect(settingBefore == .on)

    // Run the capsule.
    try await kit.runFactExtractionSettingMigration(handle: handle, now: testNow)

    // The key must now be physically present and set to "on".
    let rawAfter = try? await kit.estate(for: handle).meta(key: EstatePreferenceKey.factExtraction.rawValue)
    #expect(rawAfter == "on", "migration must seed fact_extraction = on")
    let settingAfter = try await kit.provisionedPreference(.factExtraction, for: handle)
    #expect(settingAfter == .on)
}

// MARK: - G3 explicit-off preserved

@Test("G3: migration preserves an explicit .off setting")
func migrationPreservesExplicitOff() async throws {
    let (kit, handle, storage) = try await makeEstate()

    // Pre-write .off through the provisioner before migration.
    try await kit.provisionPreference(.factExtraction, .off, for: handle)

    // Run the capsule.
    try await kit.runFactExtractionSettingMigration(handle: handle, now: testNow)

    // The capsule must not overwrite an existing value; the stamp advances to v1_8.
    let after = try await kit.provisionedPreference(.factExtraction, for: handle)
    #expect(after == .off, "capsule must not overwrite an existing value")
    let raw = try? await kit.estate(for: handle).meta(key: EstatePreferenceKey.factExtraction.rawValue)
    #expect(raw == "off")
    let stamp = try await EstateFormatStore(storage: storage).readIfPresent()
    #expect(stamp == .v1_8, "capsule stamps v1_8 even when the value is pre-set")
}

// MARK: - G4 stamp advance to v1_8

@Test("G4: migration stamps the estate format to v1_8")
func migrationStampsV1_8() async throws {
    let (kit, handle, storage) = try await makeEstate()

    try await kit.runFactExtractionSettingMigration(handle: handle, now: testNow)

    let stamp = try await EstateFormatStore(storage: storage).readIfPresent()
    #expect(stamp == .v1_8, "capsule must stamp v1_8")
}

// MARK: - G5 idempotent re-run

@Test("G5: running the capsule twice is idempotent")
func migrationIsIdempotent() async throws {
    let (kit, handle, storage) = try await makeEstate()

    // First run: seeds and stamps.
    try await kit.runFactExtractionSettingMigration(handle: handle, now: testNow)
    // Second run: must not throw.
    try await kit.runFactExtractionSettingMigration(handle: handle, now: testNow)

    let setting = try await kit.provisionedPreference(.factExtraction, for: handle)
    #expect(setting == .on, "second run must leave value at .on")
    let stamp = try await EstateFormatStore(storage: storage).readIfPresent()
    #expect(stamp == .v1_8, "second run must leave stamp at v1_8")
}

// MARK: - G6 accessor unrecognised-value fallback

@Test("G6: provisionedPreference(.factExtraction) returns .on when stored value is unrecognised (\"garbage\")")
func provisionedPreferenceReturnsOnForUnrecognisedValue_garbage() async throws {
    let (kit, handle, _) = try await makeEstate()

    // Write an unrecognised string directly via setMeta, bypassing the
    // typed provisioner, so the accessor's unrecognised-value branch runs.
    try await kit.estate(for: handle).setMeta(
        key: EstatePreferenceKey.factExtraction.rawValue,
        value: "garbage")

    // The accessor must degrade to .on — the fail-quiet fallback.
    let result = try await kit.provisionedPreference(.factExtraction, for: handle)
    #expect(result == .on, "unrecognised value must fall back to .on")
}

// MARK: - Chain from v1_7 reaches current through the 1.7→1.8 capsule

// An estate stamped v1_7 driven through the chain entry point ends at .current
// with `fact_extraction` seeded: the seeded key is what shows the chain invoked
// this capsule rather than stamping on its own. Whether the chain skipped the
// 1.6→1.7 vacuum on the way is not observable on this bare fixture; that guard
// is gated by WholeRecordFloatVacuumMigrationTests §8.
@Test("Chain from v1_7: reaches current with fact_extraction seeded")
func chainFromV1_7EstateReachesCurrentFormat() async throws {
    let (kit, handle, storage) = try await makeEstate(stampedAt: .v1_7)
    let rawBefore = try? await kit.estate(for: handle).meta(key: EstatePreferenceKey.factExtraction.rawValue)
    #expect(rawBefore == nil, "key must be absent before the chain runs")
    let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow, offlineUpgrade: true)
    #expect(prep.format == .current)
    #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .current)
    let rawAfter = try? await kit.estate(for: handle).meta(key: EstatePreferenceKey.factExtraction.rawValue)
    #expect(rawAfter == "on", "the chain must run the 1.7→1.8 capsule, which seeds the key")
}

#endif
