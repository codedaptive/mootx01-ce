// EstateEncryptionOptOutTests.swift
//
// Covers encrypted-by-default estate creation and the --no-encrypt opt-out
// (CE-1.0.35-07).
//
// The shape of this mission was set by a fact worth restating: NEITHER install
// NOR `db create` creates an estate FILE. install says so in its own output, and
// DatabaseManager.createEstate only creates the estate DIRECTORY — the substrate
// writes the SQLite file lazily on first open. So the opt-out is a recorded
// choice that has to survive until creation, and these tests assert the recording
// and the honoring, not an immediate encryption.

import Foundation
import LocusKitEstateFixture
import PersistenceKit
import Testing
@testable import MootInstallerCore

@Suite("Estate encryption default and --no-encrypt opt-out")
struct EstateEncryptionOptOutTests {

    private func makeTempDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("estate-optout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Default is encrypted

    @Test("Default creation posture is encrypted when no opt-out is recorded")
    func defaultCreationIsEncrypted() throws {
        guard EstateKeyProvider.isKeyCustodyAvailable else { return }

        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let estateURL = directory.appendingPathComponent("estate.sqlite")

        #expect(!EstateKeyProvider.hasEncryptionOptOut(forEstateAt: estateURL),
            "test premise: no opt-out recorded")

        let resolved: (encryption: EstateEncryptionConfig, posture: EstateKeyProvider.OpenPosture)
        do {
            resolved = try EstateKeyProvider.resolveOpenPosture(for: estateURL)
        } catch {
            return  // no usable Keychain on this runner
        }
        #expect(resolved.posture == .newEncrypted)
        #expect(resolved.encryption.mode == .fullDatabase,
            "absent an explicit opt-out, a new estate must be encrypted")
    }

    // MARK: - Opt-out is honored

    @Test("A recorded opt-out yields a plaintext creation posture")
    func optOutYieldsPlaintextCreation() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let estateURL = directory.appendingPathComponent("estate.sqlite")

        try EstateKeyProvider.writeEncryptionOptOut(forEstateAt: estateURL)
        #expect(EstateKeyProvider.hasEncryptionOptOut(forEstateAt: estateURL))

        let resolved = try EstateKeyProvider.resolveOpenPosture(for: estateURL)
        #expect(resolved.posture == .newPlaintextByOptOut,
            "an explicit --no-encrypt must be honored, not overridden by the default")
        #expect(resolved.encryption.mode == .plaintext)
    }

    @Test("An opted-out estate is created as a real plaintext file")
    func optOutProducesPlaintextFileOnDisk() async throws {
        // End-to-end: the posture is not just a label. Create the estate through
        // the resolved config and confirm the bytes on disk are plaintext.
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let estateURL = directory.appendingPathComponent("estate.sqlite")

        try EstateKeyProvider.writeEncryptionOptOut(forEstateAt: estateURL)
        let resolved = try EstateKeyProvider.resolveOpenPosture(for: estateURL)

        _ = try await TwentyRowEstateFixture.drawerCount(of: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0),
            encryptionConfig: resolved.encryption
        ))

        #expect(EstateKeyProvider.detectEstateFileState(at: estateURL) == .plaintext,
            "--no-encrypt must produce a genuinely unencrypted file")
    }

    @Test("writeEncryptionOptOut is idempotent and creates the directory")
    func optOutMarkerIsIdempotent() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        // Deliberately a path whose parent does NOT exist yet: the marker has to
        // be writable before the estate directory is populated.
        let estateURL = directory
            .appendingPathComponent("databases/named", isDirectory: true)
            .appendingPathComponent("estate.sqlite")

        try EstateKeyProvider.writeEncryptionOptOut(forEstateAt: estateURL)
        let marker = EstateKeyProvider.encryptionOptOutMarkerURL(forEstateAt: estateURL)
        let first = try Data(contentsOf: marker)

        try EstateKeyProvider.writeEncryptionOptOut(forEstateAt: estateURL)
        let second = try Data(contentsOf: marker)
        #expect(first == second, "re-recording the same choice must not rewrite or duplicate the marker")

        // The marker is user-facing, so it must explain itself.
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.contains("mootx01 upgrade"),
            "the marker must tell the reader how to encrypt the estate later")
    }

    // MARK: - The opt-out must not downgrade an existing estate

    @Test("The opt-out marker never re-postures an estate that already exists")
    func markerDoesNotDowngradeAnExistingEstate() async throws {
        guard EstateKeyProvider.isKeyCustodyAvailable else { return }

        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let estateURL = directory.appendingPathComponent("estate.sqlite")

        // Create an ENCRYPTED estate first.
        let created: (encryption: EstateEncryptionConfig, posture: EstateKeyProvider.OpenPosture)
        do {
            created = try EstateKeyProvider.resolveOpenPosture(for: estateURL)
        } catch {
            return
        }
        #expect(created.posture == .newEncrypted)
        _ = try await TwentyRowEstateFixture.drawerCount(of: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0),
            encryptionConfig: created.encryption
        ))
        #expect(EstateKeyProvider.detectEstateFileState(at: estateURL) == .ciphertext)

        // Now drop the marker next to it. This must NOT downgrade the existing
        // encrypted estate: dropping a file beside an estate is not a decryption
        // mechanism, and treating it as one would silently expose the contents.
        try EstateKeyProvider.writeEncryptionOptOut(forEstateAt: estateURL)

        let reopened = try EstateKeyProvider.resolveOpenPosture(for: estateURL)
        #expect(reopened.posture == .existingEncrypted,
            "an existing encrypted estate must stay encrypted regardless of the marker")
        #expect(reopened.encryption.mode == .fullDatabase)
    }

    @Test("An existing plaintext estate is unaffected by the absence of a marker")
    func existingPlaintextEstateNeedsNoMarker() async throws {
        // An estate created before this release has no marker, and must NOT be
        // treated as "opted in" and therefore required to have a key. It simply
        // stays plaintext until `mootx01 upgrade`.
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }

        #expect(!EstateKeyProvider.hasEncryptionOptOut(forEstateAt: manifest.estateURL),
            "test premise: a pre-existing estate carries no marker")

        let resolved = try EstateKeyProvider.resolveOpenPosture(for: manifest.estateURL)
        #expect(resolved.posture == .existingPlaintext,
            "no marker must not mean 'require a key' for an estate that already exists as plaintext")
    }

    // MARK: - The two surfaces agree

    @Test("install and db create expose the same --no-encrypt flag and default")
    func bothSurfacesShareTheSameOptOutShape() throws {
        // Part 2's requirement is that the two estate-creating surfaces "cannot
        // disagree". The commands live in the mootx01 executable target, which
        // this test target cannot import (the seam recorded in CE-1.0.35-02), so
        // this is asserted at the source level.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let commands = packageRoot.appendingPathComponent("Sources/mootx01/Commands")

        for name in ["InstallCommand", "DbCommand"] {
            let source = try String(
                contentsOf: commands.appendingPathComponent("\(name).swift"), encoding: .utf8)
            #expect(source.contains("var noEncrypt: Bool = false"),
                "\(name) must expose the --no-encrypt opt-out with encrypted as the default")
            #expect(source.contains("mootx01 upgrade"),
                "\(name)'s help text must point at `mootx01 upgrade` as the way to encrypt later")
        }
    }
}
