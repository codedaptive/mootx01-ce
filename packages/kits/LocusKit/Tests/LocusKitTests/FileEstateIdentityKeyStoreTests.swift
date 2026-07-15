// FileEstateIdentityKeyStoreTests.swift
//
// Tests for `FileEstateIdentityKeyStore` (DEBUG-only; see the doc
// comment on the type for the Perkins posture and the ad-hoc-signing
// keychain-hang story this exists to fix).
//
// The whole file is gated `#if DEBUG` because the type under test does
// not exist outside DEBUG builds — there is nothing to compile, let
// alone run, in a release configuration. `swift test` builds Debug by
// default (SwiftPM convention), so this suite runs on every normal
// `swift test` invocation; a release-configuration build never sees
// this file's contents at all, which is itself the compile-time proof
// of release-unreachability (see the type's own doc comment) — that
// property is a compile-config assertion, not something a runtime test
// can additionally demonstrate, so no test attempts to.
#if DEBUG

import Foundation
import Testing
@testable import LocusKit

@Suite("FileEstateIdentityKeyStoreTests")
struct FileEstateIdentityKeyStoreTests {

    // Distinct from any real product's Application Support subdirectory
    // so this suite can never collide with a developer's actual dev-run
    // key files, and cleans up after itself in each test.
    private static let testSubdirectory = "LocusKitTests-FileEstateIdentityKeyStore"

    private func makeStore() throws -> FileEstateIdentityKeyStore {
        try FileEstateIdentityKeyStore(appSupportSubdirectory: Self.testSubdirectory)
    }

    private func keyFileURL(forEstateID estateID: UUID) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent(Self.testSubdirectory, isDirectory: true)
            .appendingPathComponent("estate-identity-keys", isDirectory: true)
            .appendingPathComponent("\(estateID.uuidString).key")
    }

    // MARK: - 1. Identity persists across reopen from file

    /// Storing a key then constructing a FRESH `FileEstateIdentityKeyStore`
    /// (simulating a process relaunch reading the same on-disk directory)
    /// must load back the identical bytes — this is the whole point of the
    /// type: a stable dev-run identity across rebuilds, unlike
    /// `InMemoryEstateIdentityKeyStore` which re-mints per process.
    @Test("private key persists across a fresh store instance reading the same directory")
    func identityPersistsAcrossReopenFromFile() throws {
        let estateID = UUID()
        let keyURL = try keyFileURL(forEstateID: estateID)
        defer { try? FileManager.default.removeItem(at: keyURL) }

        let original = Data((0..<32).map { UInt8($0) }) // 32-byte stand-in key
        let writer = try makeStore()
        try writer.storePrivateKey(original, forEstateID: estateID)

        // Fresh instance — no shared in-memory state with `writer`. Only
        // the file on disk connects the two.
        let reader = try makeStore()
        let reloaded = try reader.loadPrivateKey(forEstateID: estateID)

        #expect(reloaded == original)
    }

    // MARK: - 2. Unknown estate ID returns nil, not an error

    /// A fresh estate UUID with no prior `storePrivateKey` call must load
    /// as `nil`, matching `EstateIdentityKeyStore`'s documented contract
    /// (nil means "no key stored yet", not a thrown error) — the same
    /// contract `KeychainEstateIdentityKeyStore` honors for
    /// `errSecItemNotFound`.
    @Test("loadPrivateKey returns nil for an estate ID with no stored key")
    func loadReturnsNilForUnknownEstateID() throws {
        let store = try makeStore()
        let neverStored = UUID()
        let result = try store.loadPrivateKey(forEstateID: neverStored)
        #expect(result == nil)
    }

    // MARK: - 3. Independent estates do not collide

    /// Two distinct estate UUIDs must resolve to two distinct key files
    /// and never overwrite one another's key material — the filename is
    /// keyed by estate UUID specifically so this holds.
    @Test("two distinct estate IDs store and load independent key material")
    func distinctEstatesDoNotCollide() throws {
        let estateA = UUID()
        let estateB = UUID()
        let urlA = try keyFileURL(forEstateID: estateA)
        let urlB = try keyFileURL(forEstateID: estateB)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let keyA = Data((0..<32).map { UInt8($0) })
        let keyB = Data((0..<32).map { UInt8(255 - $0) })
        let store = try makeStore()
        try store.storePrivateKey(keyA, forEstateID: estateA)
        try store.storePrivateKey(keyB, forEstateID: estateB)

        #expect(try store.loadPrivateKey(forEstateID: estateA) == keyA)
        #expect(try store.loadPrivateKey(forEstateID: estateB) == keyB)
    }

    // MARK: - 4. File and directory permissions

    /// The key file is written 0600 (owner read/write only) and the
    /// containing directory 0700 (owner traversal only) — the Perkins
    /// posture this type exists under depends on both, since a
    /// world-readable directory or file would defeat the "developer-local,
    /// low-value" threat-model reasoning the security review relied on.
    @Test("stored key file is 0600 and its directory is 0700")
    func filePermissionsAreOwnerOnly() throws {
        let estateID = UUID()
        let keyURL = try keyFileURL(forEstateID: estateID)
        defer { try? FileManager.default.removeItem(at: keyURL) }

        let store = try makeStore()
        try store.storePrivateKey(Data([0x01]), forEstateID: estateID)

        let fileAttrs = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        let filePerms = (fileAttrs[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(filePerms == 0o600)

        let dirAttrs = try FileManager.default.attributesOfItem(
            atPath: keyURL.deletingLastPathComponent().path
        )
        let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(dirPerms == 0o700)
    }

    // MARK: - 5. Overwrite replaces rather than appends

    /// A second `storePrivateKey` call for the same estate UUID overwrites
    /// the previous value in place — matching the protocol's documented
    /// contract ("a second call for the same UUID overwrites the previous
    /// value") and `KeychainEstateIdentityKeyStore`'s update-in-place
    /// behavior on `errSecDuplicateItem`.
    @Test("storing a second key for the same estate ID overwrites the first")
    func secondStoreOverwritesFirst() throws {
        let estateID = UUID()
        let keyURL = try keyFileURL(forEstateID: estateID)
        defer { try? FileManager.default.removeItem(at: keyURL) }

        let store = try makeStore()
        try store.storePrivateKey(Data([0x01, 0x02]), forEstateID: estateID)
        try store.storePrivateKey(Data([0x03, 0x04, 0x05]), forEstateID: estateID)

        let reloaded = try store.loadPrivateKey(forEstateID: estateID)
        #expect(reloaded == Data([0x03, 0x04, 0x05]))
    }
}

#endif
