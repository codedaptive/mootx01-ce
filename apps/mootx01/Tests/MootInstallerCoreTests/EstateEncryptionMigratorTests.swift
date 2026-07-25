// EstateEncryptionMigratorTests.swift
//
// CE-1.0.35-08: the migration behind `mootx01 upgrade`'s encryption offer.
// Every test drives the CE-1.0.35-04 twenty-row fixture in a temp directory;
// the real estate is never opened, read, or referenced — the fixture's own
// production-path refusal guard is asserted below so that stays true.

import Foundation
import LocusKitEstateFixture
import PersistenceKit
import SQLCipher
import Testing
@testable import MootInstallerCore

#if os(macOS)

@Suite("Estate encryption migration — clone, verify, swap, and failure paths")
struct EstateEncryptionMigratorTests {

    /// A fresh random 256-bit key. Tests never touch the Keychain: key
    /// provisioning belongs to EstateKeyProvider (already covered), and the
    /// migrator takes raw key bytes.
    private func makeKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    private func encryptedSibling(of estateURL: URL) -> URL {
        estateURL.deletingLastPathComponent()
            .appendingPathComponent(estateURL.lastPathComponent + ".encrypting")
    }

    // MARK: - Guard rails

    @Test("The fixture refuses to generate inside the real data directory")
    func fixtureRefusesProductionPath() async throws {
        // The refuse-to-run guard the whole suite depends on. If this stops
        // throwing, every other test here is pointed at a loaded gun.
        let production = TwentyRowEstateFixture.productionDataDirectory()
            .appendingPathComponent("estate.sqlite")
        await #expect(throws: (any Error).self) {
            try await TwentyRowEstateFixture.generate(at: production)
        }
    }

    // MARK: - Part 3: verify before swap

    @Test("Verification passes on a faithful copy with exact manifest counts")
    func verificationPassesOnFaithfulCopy() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let key = makeKey()
        let copy = encryptedSibling(of: manifest.estateURL)
        defer { EstateEncryptionMigrator.removeDatabase(at: copy) }
        try EstateEncryptionMigrator.exportEncryptedCopy(
            from: manifest.estateURL, to: copy, key: key)

        let counts = try EstateEncryptionMigrator.verifyEncryptedCopy(
            original: manifest.estateURL, encryptedCopy: copy, key: key)

        // Not just source==copy: the counts must equal what the fixture SAYS
        // it wrote, so a bug that loses rows on BOTH sides cannot hide.
        #expect(counts.drawers == manifest.drawerCount)
        #expect(counts.kgFacts == manifest.factCount)
        #expect(counts.tunnels == manifest.tunnelCount)
        #expect(counts.recallTraces == 0,
            "the fixture runs no recalls, so its trace table is empty")
    }

    @Test("An artificially damaged copy is rejected and the original survives")
    func damagedCopyIsRejectedAndOriginalSurvives() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let key = makeKey()
        let copy = encryptedSibling(of: manifest.estateURL)
        defer { EstateEncryptionMigrator.removeDatabase(at: copy) }
        try EstateEncryptionMigrator.exportEncryptedCopy(
            from: manifest.estateURL, to: copy, key: key)

        // Damage the copy the way a real fault would: rows missing, file
        // still a valid encrypted database. Deleting drawers through the raw
        // connection models a partial export.
        let db = try EstateEncryptionMigrator.openRaw(
            path: copy.path, keyHex: EstateEncryptionMigrator.keyHex(key))
        try EstateEncryptionMigrator.exec(
            db, sql: "DELETE FROM \"drawers\" WHERE rowid IN (SELECT rowid FROM \"drawers\" LIMIT 3);",
            step: "damage (test)")
        _ = sqlite3_close_v2(db)

        #expect(throws: (any Error).self) {
            _ = try EstateEncryptionMigrator.verifyEncryptedCopy(
                original: manifest.estateURL, encryptedCopy: copy, key: key)
        }
        // The damaged copy must be gone; the original untouched and complete.
        #expect(!FileManager.default.fileExists(atPath: copy.path),
            "a rejected copy must be deleted, never left for a later swap")
        let survivors = try await TwentyRowEstateFixture.drawerCount(of: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: manifest.estateURL, busyTimeout: 5.0),
            encryptionConfig: .plaintext))
        #expect(survivors == manifest.drawerCount,
            "the original must survive a failed verification byte-complete")
    }

    @Test("Verification with the wrong key throws rather than reporting zeros")
    func wrongKeyThrowsInsteadOfZeroCounts() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let copy = encryptedSibling(of: manifest.estateURL)
        defer { EstateEncryptionMigrator.removeDatabase(at: copy) }
        try EstateEncryptionMigrator.exportEncryptedCopy(
            from: manifest.estateURL, to: copy, key: makeKey())

        // A wrong key must never read as "0 rows" — that could match an
        // empty table and wave a garbage copy through.
        #expect(throws: (any Error).self) {
            _ = try EstateEncryptionMigrator.verificationCounts(
                atPath: copy.path,
                keyHex: EstateEncryptionMigrator.keyHex(makeKey()))
        }
    }

    // MARK: - Part 2: the clone

    @Test("Export produces a ciphertext file that opens with the key")
    func exportProducesOpenableCiphertext() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let key = makeKey()
        let destination = encryptedSibling(of: manifest.estateURL)
        defer { EstateEncryptionMigrator.removeDatabase(at: destination) }

        try EstateEncryptionMigrator.exportEncryptedCopy(
            from: manifest.estateURL, to: destination, key: key)

        // Ciphertext by the same detection function the offer uses.
        #expect(EstateKeyProvider.detectEstateFileState(at: destination) == .ciphertext,
            "the encrypted copy must not carry the plaintext SQLite header")

        // And it must genuinely OPEN with the key — through the same config a
        // command would build, so a wrong key surfaces as a thrown error.
        let count = try await TwentyRowEstateFixture.drawerCount(of: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: destination, busyTimeout: 5.0),
            encryptionConfig: .fullDatabase(key: key)))
        #expect(count == manifest.drawerCount,
            "every drawer must survive the physical clone")

        // The source stays plaintext and untouched by classification.
        #expect(EstateKeyProvider.detectEstateFileState(at: manifest.estateURL) == .plaintext)
    }

    @Test("Export refuses a ciphertext source")
    func exportRefusesCiphertextSource() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let key = makeKey()
        let encrypted = encryptedSibling(of: manifest.estateURL)
        defer { EstateEncryptionMigrator.removeDatabase(at: encrypted) }
        try EstateEncryptionMigrator.exportEncryptedCopy(
            from: manifest.estateURL, to: encrypted, key: key)

        // Migrating an already-encrypted estate must refuse, not double-wrap.
        let again = encrypted.appendingPathExtension("again")
        #expect(throws: EstateEncryptionMigrator.MigrationError
            .sourceNotPlaintext(path: encrypted.path)) {
            try EstateEncryptionMigrator.exportEncryptedCopy(
                from: encrypted, to: again, key: key)
        }
        #expect(!FileManager.default.fileExists(atPath: again.path),
            "a refused export must leave nothing behind")
    }

    @Test("A failed export leaves no partial ciphertext behind")
    func failedExportCleansUp() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        // A destination whose parent directory does not exist makes ATTACH
        // fail after the source is already open — the export path's first
        // real failure point.
        let destination = manifest.estateURL.deletingLastPathComponent()
            .appendingPathComponent("missing-subdir", isDirectory: true)
            .appendingPathComponent("copy.sqlite")

        #expect(throws: (any Error).self) {
            try EstateEncryptionMigrator.exportEncryptedCopy(
                from: manifest.estateURL, to: destination, key: makeKey())
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        // The original is untouched and still plaintext.
        #expect(EstateKeyProvider.detectEstateFileState(at: manifest.estateURL) == .plaintext)
    }
}

#endif
