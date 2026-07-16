// TokenStoreTests.swift
//
// Tests for Engine/TokenStore.swift (R5: persisted server change token).
//
// CKServerChangeToken has no public initializer and can only be obtained
// from a live CloudKit operation. Tests that require a real token object
// are therefore not feasible without a network-connected iCloud container.
//
// This file takes the approach mandated by the mission brief:
//
//   (a) Archiver round-trip — tested with NSString as a stand-in
//       NSSecureCoding type. NSString satisfies the same
//       NSKeyedArchiver/NSKeyedUnarchiver contract as CKServerChangeToken;
//       the test verifies the archive(_:) / unarchive(_:from:) helpers
//       correctly preserve the object through the BLOB round-trip.
//       Substitution is noted in the test body.
//
//   (b) Per-zone keying — tested via saveBlob / loadBlob, which are the
//       internal helpers exposed for testing. Two zones get distinct blobs;
//       each zone's data is independent.
//
//   (c) Expiry-reset behavior — tested at the seam reachable in-process:
//       save a blob for a zone, clear it, verify load returns nil. This
//       covers the state transition the engine performs on changeTokenExpired
//       (clear + nil reset) without needing a live CloudKit error.

import Testing
import Foundation
import CloudKit
import PersistenceKit
import PersistenceKitInMemory
import ConvergenceKit
@testable import ConvergenceKitCloudKit

// MARK: - Storage helper

private func makeStorage() async throws -> any Storage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
    try await storage.open(schema: SchemaDeclaration(
        kitID: "TestKit",
        version: 1,
        tables: [
            TableDeclaration(
                name: "items",
                columns: [.uuid("id"), .text("note")],
                primaryKey: ["id"]
            )
        ],
        indices: [],
        migrations: []
    ))
    // Ensure the _ck_change_token side table is present in the same way
    // production does: via TokenStore.ensure, not by re-declaring the schema.
    try await TokenStore.ensure(storage: storage)
    return storage
}

// MARK: - Suite: archiver round-trip

@Suite("TokenStore archiver round-trip")
struct TokenStoreArchiverTests {

    @Test("archive/unarchive round-trip preserves NSString value")
    func archiverRoundTripWithNSString() throws {
        // CKServerChangeToken has no public initializer — it is only
        // returned by live CloudKit operations, making direct construction
        // in tests impossible without an iCloud container. NSString is used
        // as a stand-in NSSecureCoding type to verify the NSKeyedArchiver
        // contract. The archive(_:)/unarchive(_:from:) helpers are generic
        // over any NSSecureCoding, so the contract holds for CKServerChangeToken
        // on the same code path.
        let original: NSString = "zone-token-payload-stub"
        let archived = try TokenStore.archive(original)
        #expect(!archived.isEmpty, "archived data must be non-empty")
        let restored = try TokenStore.unarchive(NSString.self, from: archived)
        #expect(restored == original, "round-trip must preserve the NSString value")
    }

    @Test("unarchive with wrong type throws, not crashes")
    func unarchiveWrongTypeThrows() throws {
        // Archive an NSString, then attempt to unarchive as NSArray.
        // NSKeyedUnarchiver returns nil for a type mismatch; we surface
        // this as TokenStoreError.unarchiveFailed rather than propagating
        // the raw archiver error.
        let original: NSString = "type-mismatch-test"
        let archived = try TokenStore.archive(original)
        #expect(throws: TokenStoreError.unarchiveFailed) {
            _ = try TokenStore.unarchive(NSArray.self, from: archived)
        }
    }

    @Test("empty data throws on unarchive")
    func emptyDataThrows() {
        // Corrupt or zeroed blob should not silently return nil — it should
        // throw so callers can treat it as a hard failure and reset the token.
        #expect(throws: (any Error).self) {
            _ = try TokenStore.unarchive(NSString.self, from: Data())
        }
    }
}

// MARK: - Suite: per-zone keying

@Suite("TokenStore per-zone keying")
struct TokenStoreZoneKeyingTests {

    @Test("blobs for two zones are stored and loaded independently")
    func twoZonesAreIndependent() async throws {
        let storage = try await makeStorage()
        let blobA = Data([0x01, 0x02, 0x03])
        let blobB = Data([0x04, 0x05, 0x06])

        try await TokenStore.saveBlob(blobA, zoneName: "zoneA", storage: storage)
        try await TokenStore.saveBlob(blobB, zoneName: "zoneB", storage: storage)

        let loadedA = try await TokenStore.loadBlob(zoneName: "zoneA", storage: storage)
        let loadedB = try await TokenStore.loadBlob(zoneName: "zoneB", storage: storage)

        #expect(loadedA == blobA, "zoneA must return its own blob")
        #expect(loadedB == blobB, "zoneB must return its own blob")
        #expect(loadedA != loadedB, "zones must not share blobs")
    }

    @Test("saving zone A does not affect zone B")
    func saveZoneADoesNotTouchZoneB() async throws {
        let storage = try await makeStorage()
        let blobB = Data([0xAA, 0xBB])

        try await TokenStore.saveBlob(blobB, zoneName: "zoneB", storage: storage)

        // Write a different blob to zone A.
        try await TokenStore.saveBlob(Data([0x11]), zoneName: "zoneA", storage: storage)

        // Zone B must still return the original blob.
        let loadedB = try await TokenStore.loadBlob(zoneName: "zoneB", storage: storage)
        #expect(loadedB == blobB, "zone B must be unaffected by a save to zone A")
    }

    @Test("upsert on same zone replaces the previous blob")
    func upsertReplacesExistingBlob() async throws {
        let storage = try await makeStorage()
        let first = Data([0x01])
        let second = Data([0x02])

        try await TokenStore.saveBlob(first, zoneName: "zone", storage: storage)
        try await TokenStore.saveBlob(second, zoneName: "zone", storage: storage)

        let loaded = try await TokenStore.loadBlob(zoneName: "zone", storage: storage)
        #expect(loaded == second, "second save must replace first (upsert semantics)")
    }

    @Test("loadBlob returns nil for an unknown zone")
    func loadUnknownZoneReturnsNil() async throws {
        let storage = try await makeStorage()
        let result = try await TokenStore.loadBlob(zoneName: "never-saved", storage: storage)
        #expect(result == nil, "unknown zone must return nil, not an error")
    }
}

// MARK: - Suite: expiry-reset behavior

@Suite("TokenStore expiry-reset behavior")
struct TokenStoreExpiryResetTests {

    @Test("clear removes the persisted token so load returns nil")
    func clearMakesLoadReturnNil() async throws {
        // This covers the state transition the engine performs on
        // CKError.changeTokenExpired: clear persisted token → reset
        // in-memory → re-pull from scratch. The seam tested here is the
        // storage layer; the engine's pull() method itself calls
        // TokenStore.clear() followed by serverChangeToken = nil.
        let storage = try await makeStorage()
        try await TokenStore.saveBlob(Data([0xDE, 0xAD]), zoneName: "myZone", storage: storage)

        // Verify the blob is present before clearing.
        let before = try await TokenStore.loadBlob(zoneName: "myZone", storage: storage)
        #expect(before != nil, "blob must be present before clear")

        // Clear simulates the changeTokenExpired reset path.
        try await TokenStore.clear(zoneName: "myZone", storage: storage)

        // After clear, load must return nil (driving a full-zone pull).
        let after = try await TokenStore.loadBlob(zoneName: "myZone", storage: storage)
        #expect(after == nil, "load after clear must return nil")
    }

    @Test("clear on an absent zone is a no-op (does not throw)")
    func clearAbsentZoneIsNoOp() async throws {
        // changeTokenExpired may be triggered even if our persisted token
        // row was already absent (e.g. DB was wiped). clear() must not fail.
        let storage = try await makeStorage()
        // Should not throw.
        try await TokenStore.clear(zoneName: "non-existent-zone", storage: storage)
        // And the table is still usable afterwards.
        let result = try await TokenStore.loadBlob(zoneName: "non-existent-zone", storage: storage)
        #expect(result == nil)
    }

    @Test("save followed by clear followed by save restores a fresh blob")
    func saveClearSaveCycle() async throws {
        // Full cycle: persist → expire-reset → persist again.
        // Confirms no leftover state from the previous token blocks re-use.
        let storage = try await makeStorage()
        let firstBlob = Data([0x10])
        let secondBlob = Data([0x20])

        try await TokenStore.saveBlob(firstBlob, zoneName: "zone", storage: storage)
        try await TokenStore.clear(zoneName: "zone", storage: storage)
        try await TokenStore.saveBlob(secondBlob, zoneName: "zone", storage: storage)

        let loaded = try await TokenStore.loadBlob(zoneName: "zone", storage: storage)
        #expect(loaded == secondBlob, "post-clear save must be readable as fresh state")
    }

    @Test("ensure is idempotent — calling it twice does not error")
    func ensureIsIdempotent() async throws {
        // Production calls ensure() on every enable(). If called more than
        // once on the same storage (e.g. disable + re-enable), it must not
        // fail or corrupt the existing tokens.
        let storage = try await makeStorage()
        // First call is already done in makeStorage(). Call again.
        try await TokenStore.ensure(storage: storage)
        // Table still works after second ensure.
        try await TokenStore.saveBlob(Data([0xFF]), zoneName: "z", storage: storage)
        let result = try await TokenStore.loadBlob(zoneName: "z", storage: storage)
        #expect(result == Data([0xFF]))
    }
}
