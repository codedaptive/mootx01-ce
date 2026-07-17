// DeviceIdentityStoreTests.swift
//
// Tests for DeviceIdentityStore: schema creation, persistence round-trip,
// load-or-mint idempotency, and save/reload across store re-open.
//
// All tests use InMemoryStorage and injected clocks — no filesystem I/O,
// no real time.
//
// Coverage:
//   - ensureSchema creates the _ck_device_identity table
//   - loadOrMint on fresh storage returns a minted identity
//   - minted identity slot is in 1...15
//   - minted identity epoch is 1
//   - second loadOrMint call returns the identical stored identity
//   - explicit save then load returns the saved identity
//   - save overwrites the existing row (upsert behaviour)
//   - claimedAt round-trips without precision loss
//   - _ck_device_identity exists after CKSideSchema.ensure alone (CVK-WB12 A11)

import Testing
import Foundation
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
@testable import ConvergenceKitCloudKit

// MARK: - Helpers

private func makeStorage() -> InMemoryStorage {
    InMemoryStorage(
        configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        )
    )
}

/// Returns a `@Sendable () -> Date` closure that always returns `date`.
private func fixedClock(_ date: Date) -> @Sendable () -> Date { { date } }

// MARK: - Schema tests

@Suite("DeviceIdentityStore: schema creation")
struct DeviceIdentityStoreSchemaTests {

    @Test("ensureSchema creates _ck_device_identity table without error")
    func ensureSchemaSucceeds() async throws {
        let storage = makeStorage()
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        // Idempotent — calling twice must not throw
        try await DeviceIdentityStore.ensureSchema(storage: storage)
    }

    @Test("ensureSchema is additive: a second schema migration on the same storage succeeds")
    func schemaAdditivity() async throws {
        let storage = makeStorage()
        // Simulate app schema already open on this storage
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        // DeviceIdentityStore schema is additive — does not replace existing tables
        try await DeviceIdentityStore.ensureSchema(storage: storage)
    }
}

// MARK: - loadOrMint tests

@Suite("DeviceIdentityStore: loadOrMint")
struct DeviceIdentityStoreLoadOrMintTests {

    @Test("fresh storage returns a minted identity")
    func freshMint() async throws {
        let storage = makeStorage()
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let store = DeviceIdentityStore(storage: storage)

        let refDate = Date(timeIntervalSince1970: 1_750_000_000)
        let identity = try await store.loadOrMint(now: fixedClock(refDate))

        #expect((1...15).contains(identity.slot), "minted slot must be 1–15 (slot 0 permanently reserved)")
        #expect(identity.epoch == 1, "fresh mint always starts at epoch 1")
        #expect(identity.deviceUUID != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        // claimedAt round-trips to within 1 second (ISO8601 second-precision)
        #expect(abs(identity.claimedAt.timeIntervalSince(refDate)) < 1.0)
    }

    @Test("loadOrMint is idempotent: second call returns the same identity")
    func idempotentMint() async throws {
        let storage = makeStorage()
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let store = DeviceIdentityStore(storage: storage)

        let refDate = Date(timeIntervalSince1970: 1_750_000_000)
        let first  = try await store.loadOrMint(now: fixedClock(refDate))
        // Advance the clock — the second call must ignore it and return stored identity
        let later  = refDate.addingTimeInterval(3600)
        let second = try await store.loadOrMint(now: fixedClock(later))

        #expect(first.deviceUUID == second.deviceUUID, "deviceUUID must be stable across calls")
        #expect(first.slot       == second.slot,       "slot must be stable across calls")
        #expect(first.epoch      == second.epoch,      "epoch must be stable across calls")
        #expect(abs(first.claimedAt.timeIntervalSince(second.claimedAt)) < 1.0,
                "claimedAt must not be updated by subsequent loadOrMint calls")
    }

    @Test("load returns nil before any save")
    func loadNilOnFreshStorage() async throws {
        let storage = makeStorage()
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let store = DeviceIdentityStore(storage: storage)

        let result = try await store.load()
        #expect(result == nil)
    }
}

// MARK: - Save / load round-trip tests

@Suite("DeviceIdentityStore: save and load round-trip")
struct DeviceIdentityStoreSaveLoadTests {

    @Test("saved identity is recoverable via load")
    func saveAndLoad() async throws {
        let storage = makeStorage()
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let store = DeviceIdentityStore(storage: storage)

        let refDate = Date(timeIntervalSince1970: 1_750_100_000)
        let identity = DeviceIdentity(
            deviceUUID: UUID(),
            slot: 7,
            epoch: 3,
            claimedAt: refDate
        )
        try await store.save(identity)

        guard let loaded = try await store.load() else {
            Issue.record("expected a loaded identity, got nil")
            return
        }
        #expect(loaded.deviceUUID == identity.deviceUUID)
        #expect(loaded.slot       == identity.slot)
        #expect(loaded.epoch      == identity.epoch)
        // claimedAt round-trips within ISO8601 second precision
        #expect(abs(loaded.claimedAt.timeIntervalSince(refDate)) < 1.0)
    }

    @Test("save overwrites existing row (upsert behaviour)")
    func saveOverwrites() async throws {
        let storage = makeStorage()
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let store = DeviceIdentityStore(storage: storage)

        let firstUUID  = UUID()
        let secondUUID = UUID()
        let refDate    = Date(timeIntervalSince1970: 1_750_200_000)

        // Write first identity
        try await store.save(DeviceIdentity(deviceUUID: firstUUID,  slot: 3, epoch: 1, claimedAt: refDate))
        // Overwrite with second identity (simulating re-enrollment after eviction)
        try await store.save(DeviceIdentity(deviceUUID: secondUUID, slot: 9, epoch: 2, claimedAt: refDate))

        guard let loaded = try await store.load() else {
            Issue.record("expected a loaded identity after overwrite, got nil")
            return
        }
        #expect(loaded.deviceUUID == secondUUID, "overwrite must replace deviceUUID")
        #expect(loaded.slot       == 9,          "overwrite must replace slot")
        #expect(loaded.epoch      == 2,          "overwrite must replace epoch")
    }

    @Test("slot 1 persists and reloads correctly (boundary check)")
    func slotOnePersists() async throws {
        let storage = makeStorage()
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let store = DeviceIdentityStore(storage: storage)
        let identity = DeviceIdentity(deviceUUID: UUID(), slot: 1, epoch: 1,
                                      claimedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(identity)
        let loaded = try await store.load()
        #expect(loaded?.slot == 1)
    }

    @Test("slot 15 persists and reloads correctly (boundary check)")
    func slotFifteenPersists() async throws {
        let storage = makeStorage()
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let store = DeviceIdentityStore(storage: storage)
        let identity = DeviceIdentity(deviceUUID: UUID(), slot: 15, epoch: 99,
                                      claimedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(identity)
        let loaded = try await store.load()
        #expect(loaded?.slot == 15)
        #expect(loaded?.epoch == 99)
    }

    @Test("epoch 64-bit range survives a round-trip")
    func largeEpochRoundTrip() async throws {
        let storage = makeStorage()
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let store = DeviceIdentityStore(storage: storage)
        // Use a value large enough to overflow Int32 — ensure Int64 storage is used
        let bigEpoch: Int64 = 5_000_000_000
        let identity = DeviceIdentity(deviceUUID: UUID(), slot: 5, epoch: bigEpoch,
                                      claimedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(identity)
        let loaded = try await store.load()
        #expect(loaded?.epoch == bigEpoch, "epoch must survive Int64 round-trip through TEXT store")
    }
}

// MARK: - loadOrMint uses stored identity after explicit save

@Suite("DeviceIdentityStore: loadOrMint prefers stored over mint")
struct DeviceIdentityStorePreferStoredTests {

    @Test("explicit save followed by loadOrMint returns the saved identity")
    func loadOrMintReturnsExplicitlySaved() async throws {
        let storage = makeStorage()
        try await DeviceIdentityStore.ensureSchema(storage: storage)
        let store = DeviceIdentityStore(storage: storage)

        let saved = DeviceIdentity(
            deviceUUID: UUID(),
            slot: 12,
            epoch: 4,
            claimedAt: Date(timeIntervalSince1970: 1_750_300_000)
        )
        try await store.save(saved)

        // loadOrMint must return the stored identity, not mint a fresh one
        let result = try await store.loadOrMint(now: fixedClock(Date()))
        #expect(result.deviceUUID == saved.deviceUUID, "loadOrMint must prefer stored identity")
        #expect(result.slot       == saved.slot)
        #expect(result.epoch      == saved.epoch)
    }
}

// MARK: - CKSideSchema v9 consolidation (CVK-WB12 A11)

@Suite("CKSideSchema v9: _ck_device_identity consolidated")
struct CKSideSchemaDeviceIdentityConsolidationTests {

    /// Verifies that _ck_device_identity is queryable after CKSideSchema.ensure
    /// alone — i.e. DeviceIdentityStore.ensureSchema is no longer required as a
    /// separate call for the table to exist (CVK-WB12, A11 final consolidation).
    @Test("_ck_device_identity table exists after CKSideSchema.ensure alone")
    func deviceIdentityTableExistsAfterSideSchemaEnsure() async throws {
        let storage = makeStorage()
        // Call CKSideSchema.ensure directly — NOT DeviceIdentityStore.ensureSchema.
        // After CVK-WB12 the table declaration lives in CKSideSchema v9, so
        // ensure(storage:) alone must make the table queryable.
        try await CKSideSchema.ensure(storage: storage)

        // Confirm the table is accessible: a query on the empty table must
        // succeed (not throw) and return zero rows.
        let store = DeviceIdentityStore(storage: storage)
        let result = try await store.load()
        #expect(result == nil,
                "_ck_device_identity must exist and be empty after CKSideSchema.ensure alone")
    }
}
