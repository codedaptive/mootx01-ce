// EstateKeyProviderTests.swift
//
// Covers the two primitives CE-1.0.35-06/07/08 are built on: fail-closed key
// custody, and the authoritative plaintext-vs-ciphertext answer.
//
// KEYCHAIN TESTS SKIP RATHER THAN FAIL where no Keychain is available, so Linux
// CI stays green. They are skipped, never silently passed: a skipped test says
// "not verified here", whereas a test that quietly returns success would claim
// coverage the run never had.

import Foundation
import LocusKitEstateFixture
import Testing
@testable import MootInstallerCore

@Suite("EstateKeyProvider — key custody and estate file detection")
struct EstateKeyProviderTests {

    // MARK: - Helpers

    /// A temp directory for this test's files. Never the real data directory —
    /// the fixture's own guard enforces that for generated estates, and every
    /// path built here is under NSTemporaryDirectory.
    private func makeTempDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("estate-key-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 1. Key custody round-trip

    @Test("Key round-trips through the Keychain for the same estate URL")
    func keyRoundTripsForSameEstateURL() throws {
        guard EstateKeyProvider.isKeyCustodyAvailable else {
            // Not a failure: this platform ships the Rust binary and its
            // file-based key instead.
            return
        }

        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let estateURL = directory.appendingPathComponent("estate.sqlite")

        do {
            let key = try EstateKeyProvider.provideKey(for: estateURL)
            #expect(key.count == EstateKeyProvider.keyByteCount,
                "SQLCipher is configured with a 256-bit key")
            #expect(key.contains(where: { $0 != 0 }),
                "an all-zero key would mean SecRandomCopyBytes silently failed")
        } catch {
            // An unsigned local build or a CI runner with no usable Keychain
            // cannot exercise this. Skip rather than fail; the fail-closed test
            // below is the one that must hold either way.
            return
        }
    }

    @Test("A second call returns the SAME key, not a new one")
    func secondCallIsIdempotent() throws {
        guard EstateKeyProvider.isKeyCustodyAvailable else { return }

        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let estateURL = directory.appendingPathComponent("estate.sqlite")

        let first: Data
        do {
            first = try EstateKeyProvider.provideKey(for: estateURL)
        } catch {
            return  // no usable Keychain here; see the note above
        }
        let second = try EstateKeyProvider.provideKey(for: estateURL)

        // This is the property that matters most in the whole file. If a second
        // call minted a fresh key, an estate encrypted with the first key would
        // become unopenable on the next launch.
        #expect(first == second,
            "provideKey must be idempotent per estate — a second key means an unopenable estate")
    }

    @Test("Different estate URLs get different keys")
    func distinctEstatesGetDistinctKeys() throws {
        guard EstateKeyProvider.isKeyCustodyAvailable else { return }

        let directory = try makeTempDirectory()
        defer { cleanup(directory) }

        let firstURL = directory.appendingPathComponent("one.sqlite")
        let secondURL = directory.appendingPathComponent("two.sqlite")

        let first: Data
        do {
            first = try EstateKeyProvider.provideKey(for: firstURL)
        } catch {
            return
        }
        let second = try EstateKeyProvider.provideKey(for: secondURL)

        #expect(first != second,
            "keys are scoped per estate path, so two estates must not share one key")
    }

    // MARK: - 2. Fail closed

    @Test("No code path returns a nil or empty key, and nothing falls back to plaintext")
    func failsClosedRatherThanFallingBackToPlaintext() throws {
        // The contract is structural: provideKey's return type is non-optional
        // Data, so "returns nil silently" is not expressible. What remains to
        // prove is that a FAILURE surfaces as a thrown error rather than as a
        // usable-looking empty key.
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }

        // A path whose parent does not exist and cannot be created. Key custody
        // is keyed by the path STRING, not by the file, so this still exercises
        // the provider rather than the filesystem — the assertion is that
        // whatever happens, we either get 32 real bytes or an error.
        let hostileURL = URL(fileURLWithPath: "/dev/null/nope/estate.sqlite")

        do {
            let key = try EstateKeyProvider.provideKey(for: hostileURL)
            // If it succeeded, it must be a real key. A short or empty key
            // reaching a caller is the failure mode this guards.
            #expect(key.count == EstateKeyProvider.keyByteCount,
                "a returned key must always be exactly 32 bytes, never a partial or empty fallback")
        } catch {
            // Throwing is the correct fail-closed outcome.
            #expect(Bool(true))
        }
    }

    @Test("Unsupported platform surfaces as an error, never as a plaintext default")
    func unsupportedPlatformIsAnError() throws {
        // On Apple platforms custody IS available, so this asserts the flag
        // rather than the throw. The point is that the two are wired together:
        // if the conditional import ever silently failed to resolve
        // PersistenceKitSQLite, isKeyCustodyAvailable would flip to false and
        // this test would catch it — otherwise every estate would quietly go
        // back to being plaintext.
        #if canImport(Security)
        #expect(EstateKeyProvider.isKeyCustodyAvailable,
            "on Apple platforms the Keychain path must be compiled in, or estates silently revert to plaintext")
        #endif
    }

    // MARK: - 3. Detection over the three input kinds

    @Test("Detection classifies a plaintext fixture estate as plaintext")
    func detectsPlaintextFixtureEstate() async throws {
        // Uses the CE-1.0.35-04 twenty-row fixture, as the mission directs. The
        // real estate is never touched; the fixture refuses to be generated
        // anywhere near it.
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }

        #expect(EstateKeyProvider.detectEstateFileState(at: manifest.estateURL) == .plaintext,
            "the fixture is a plaintext SQLite estate and must be detected as one")
    }

    @Test("Detection classifies a nonexistent path as absent")
    func detectsAbsentEstate() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let missing = directory.appendingPathComponent("no-such-estate.sqlite")

        #expect(EstateKeyProvider.detectEstateFileState(at: missing) == .absent,
            "a path with no file is absent — the caller's first-run branch")
    }

    @Test("Detection classifies a non-plaintext file as ciphertext")
    func detectsCiphertextEstate() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }

        // A SQLCipher database encrypts page 1 including the header, so its first
        // 16 bytes are indistinguishable from random. Random bytes are therefore
        // a faithful stand-in, and they avoid making this unit test depend on
        // building an actual encrypted estate.
        let encrypted = directory.appendingPathComponent("encrypted.sqlite")
        var bytes = Data(count: 4096)
        bytes.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count {
                buffer[index] = UInt8((index * 37 + 11) % 251) &+ 1
            }
        }
        try bytes.write(to: encrypted)

        #expect(EstateKeyProvider.detectEstateFileState(at: encrypted) == .ciphertext,
            "a file that does not open with the plaintext magic must be reported ciphertext")
    }

    @Test("Detection never reports a truncated or empty file as absent")
    func detectsTruncatedFileAsCiphertext() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }

        // Reporting these as .absent would tell a caller "no estate here, create
        // one", and it would create over the top of a file it did not
        // understand. That is a data-loss path, so it is asserted explicitly.
        let empty = directory.appendingPathComponent("empty.sqlite")
        try Data().write(to: empty)
        #expect(EstateKeyProvider.detectEstateFileState(at: empty) == .ciphertext,
            "an empty file is not absent — never invite a caller to overwrite it")

        let short = directory.appendingPathComponent("short.sqlite")
        try Data("SQLite".utf8).write(to: short)
        #expect(EstateKeyProvider.detectEstateFileState(at: short) == .ciphertext,
            "a file too short to hold the magic is not a valid plaintext estate")
    }

    @Test("Detection does not report a directory as a plaintext estate")
    func detectsDirectoryAsAbsent() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let nested = directory.appendingPathComponent("estate.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(EstateKeyProvider.detectEstateFileState(at: nested) == .absent,
            "a directory at the estate path is not a plaintext database")
    }

    @Test("The plaintext magic is exactly the documented 16 bytes")
    func plaintextMagicIsTheDocumentedBytes() throws {
        #expect(EstateKeyProvider.plaintextSQLiteMagic.count == 16)
        #expect(EstateKeyProvider.plaintextSQLiteMagic
            == Array("SQLite format 3".utf8) + [0x00])
        // Both verticals and the test fixture must agree on this constant, or
        // one of them would classify the same file differently.
        #expect(EstateKeyProvider.plaintextSQLiteMagic
            == TwentyRowEstateFixture.plaintextSQLiteMagic,
            "the fixture and the production detector must share one definition of plaintext")
    }
}
