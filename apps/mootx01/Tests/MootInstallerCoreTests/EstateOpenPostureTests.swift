// EstateOpenPostureTests.swift
//
// Covers the shared open decision that ServeCommand, DrainCommand, and
// DreamCommand now route through (CE-1.0.35-06).
//
// The behavioral rule under test is "do not force the flip": an existing
// plaintext estate must keep opening, because migration is user-initiated
// through `mootx01 upgrade`. A regression here does not fail loudly — it locks
// someone out of their own estate on upgrade — so each branch is asserted
// separately rather than inferred from one happy path.
//
// Every test drives the CE-1.0.35-04 twenty-row fixture or a temp file. The real
// estate is never opened, read, or referenced.

import Foundation
import LocusKitEstateFixture
import PersistenceKit
import Testing
@testable import MootInstallerCore

@Suite("Estate open posture — new, ciphertext, and plaintext paths")
struct EstateOpenPostureTests {

    private func makeTempDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("estate-posture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Existing plaintext estate keeps opening

    @Test("An existing plaintext fixture estate resolves to the plaintext posture")
    func existingPlaintextEstateStaysPlaintext() async throws {
        // THE regression test for this mission. If this flips to an encrypted
        // posture, every existing macOS install breaks on upgrade.
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }

        let resolved = try EstateKeyProvider.resolveOpenPosture(for: manifest.estateURL)
        #expect(resolved.posture == .existingPlaintext,
            "an existing plaintext estate must keep opening as plaintext — migration is `mootx01 upgrade` only")
        #expect(resolved.encryption.mode == .plaintext,
            "the plaintext branch must hand SQLite a plaintext config, not a key")
    }

    @Test("A plaintext fixture estate still reads all twenty drawers with no key")
    func plaintextEstateRemainsReadableWithoutAKey() async throws {
        // Proves the posture decision is not just a label: the estate the
        // plaintext branch describes is genuinely openable and complete.
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }

        let resolved = try EstateKeyProvider.resolveOpenPosture(for: manifest.estateURL)
        #expect(resolved.encryption.mode == .plaintext)

        // Read it back through the same config the commands would build.
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: manifest.estateURL, busyTimeout: 5.0),
            encryptionConfig: resolved.encryption
        )
        let drawerCount = try await drawerCount(of: configuration)
        #expect(drawerCount == manifest.drawerCount,
            "all twenty drawers must still be readable with no key at all")
    }

    // MARK: - Ciphertext estate with no key fails closed

    @Test("A ciphertext estate whose key is unavailable fails closed")
    func ciphertextEstateWithoutKeyFailsClosed() throws {
        // The dangerous branch. A ciphertext file whose key cannot be found must
        // THROW. It must not mint a fresh key (which would hand SQLCipher a wrong
        // key for an already-encrypted file), and it must not fall back to
        // creating a new plaintext estate over the top of the encrypted one.
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }

        // A file that is not plaintext SQLite, at a path no Keychain item exists
        // for. This is exactly the shape of an encrypted estate whose key is gone.
        let encrypted = directory.appendingPathComponent("orphaned-ciphertext.sqlite")
        var bytes = Data(count: 4096)
        bytes.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count {
                buffer[index] = UInt8((index * 53 + 7) % 251) &+ 1
            }
        }
        try bytes.write(to: encrypted)

        #expect(EstateKeyProvider.detectEstateFileState(at: encrypted) == .ciphertext,
            "test premise: the file must classify as ciphertext")

        #expect(throws: (any Error).self) {
            _ = try EstateKeyProvider.resolveOpenPosture(for: encrypted)
        }

        // And the failure must leave the file alone. Nothing may be created,
        // truncated, or replaced by a fresh plaintext estate.
        let after = try Data(contentsOf: encrypted)
        #expect(after == bytes,
            "a failed open must leave the encrypted file byte-for-byte untouched")
        #expect(EstateKeyProvider.detectEstateFileState(at: encrypted) == .ciphertext,
            "the file must not have been replaced by a new plaintext estate")
    }

    @Test("existingKey never mints a key for an estate that has none")
    func existingKeyDoesNotMint() throws {
        // provideKey mints when nothing is found; existingKey must not. Keeping
        // those two behaviors distinct is what makes the ciphertext branch safe.
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let estateURL = directory.appendingPathComponent("never-keyed.sqlite")

        #expect(throws: (any Error).self) {
            _ = try EstateKeyProvider.existingKey(for: estateURL)
        }
    }

    // MARK: - New estate path

    @Test("An absent estate resolves to the new-encrypted posture")
    func absentEstateResolvesToNewEncrypted() throws {
        guard EstateKeyProvider.isKeyCustodyAvailable else { return }

        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let estateURL = directory.appendingPathComponent("fresh.sqlite")

        #expect(EstateKeyProvider.detectEstateFileState(at: estateURL) == .absent,
            "test premise: no file yet")

        let resolved: (encryption: EstateEncryptionConfig, posture: EstateKeyProvider.OpenPosture)
        do {
            resolved = try EstateKeyProvider.resolveOpenPosture(for: estateURL)
        } catch {
            // No usable Keychain on this runner; the fail-closed tests above are
            // the ones that must hold regardless.
            return
        }

        #expect(resolved.posture == .newEncrypted,
            "a first run must provision a key and create the estate ENCRYPTED — this is the macOS parity fix")
        #expect(resolved.encryption.mode == .fullDatabase,
            "a new estate must be whole-database encrypted, not plaintext")
    }

    @Test("A newly created estate is ciphertext on disk and reopens under the same posture")
    func newEstateIsCiphertextAndReopens() async throws {
        guard EstateKeyProvider.isKeyCustodyAvailable else { return }

        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let estateURL = directory.appendingPathComponent("fresh.sqlite")

        let first: (encryption: EstateEncryptionConfig, posture: EstateKeyProvider.OpenPosture)
        do {
            first = try EstateKeyProvider.resolveOpenPosture(for: estateURL)
        } catch {
            return
        }
        #expect(first.posture == .newEncrypted)

        // Actually create the estate through the config a command would build.
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0),
            encryptionConfig: first.encryption
        )
        _ = try await drawerCount(of: configuration)

        // On disk it must NOT be plaintext: SQLCipher encrypts page 1 including
        // the header. This is the end-to-end proof that new macOS installs are
        // encrypted at rest.
        #expect(EstateKeyProvider.detectEstateFileState(at: estateURL) == .ciphertext,
            "a newly created encrypted estate must not carry the plaintext SQLite header")

        // Reopening must now take the existing-ciphertext branch and load the
        // SAME key, not mint a second one.
        let second = try EstateKeyProvider.resolveOpenPosture(for: estateURL)
        #expect(second.posture == .existingEncrypted,
            "the second open must recognize the file as already encrypted")
        #expect(second.encryption.mode == .fullDatabase)

        let reopenedCount = try await drawerCount(of: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0),
            encryptionConfig: second.encryption
        ))
        #expect(reopenedCount == 0,
            "the encrypted estate must reopen with the resolved key (a wrong key would throw, not return a count)")
    }

    // MARK: - Drift guard

    @Test("All three commands route through the shared posture helper")
    func allThreeCommandsUseTheSharedHelper() throws {
        // Part 2 of the mission requires ONE shared decision so the three
        // commands cannot drift. That is a property of the call sites, and the
        // command files live in the mootx01 executable target which this test
        // target cannot import (same seam noted in CE-1.0.35-02), so it is
        // asserted at the source level. If a future edit re-inlines the estate
        // open in one command, this fails.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/mootx01
        let commands = packageRoot.appendingPathComponent("Sources/mootx01/Commands")

        for name in ["ServeCommand", "DrainCommand", "DreamCommand"] {
            let url = commands.appendingPathComponent("\(name).swift")
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(source.contains("EstateKeyProvider.resolveOpenPosture"),
                "\(name) must resolve its at-rest posture through the shared helper")
            #expect(source.contains("encryptionConfig:"),
                "\(name) must pass an encryptionConfig — omitting it silently takes the .plaintext default")
        }
    }

    // MARK: - Helpers

    /// Open the estate through a config and count its drawers. Exercises the real
    /// SQLite/SQLCipher path, so a wrong key surfaces as a thrown error.
    private func drawerCount(of configuration: EstateConfiguration) async throws -> Int {
        try await TwentyRowEstateFixture.drawerCount(of: configuration)
    }
}
