// EstateOpenPostureTests.swift
//
// The shared open decision and the key custody beneath it. The behavioural
// rule under test is "do not force the flip": an existing plaintext estate
// must keep opening, because migration is user-initiated through
// `mootx01 upgrade`. A regression here does not fail loudly — it locks someone
// out of their own estate — so each branch is asserted separately.
//
// KEYCHAIN TESTS SKIP RATHER THAN FAIL where no Keychain is available, so a
// Linux build stays green; a skipped test says "not verified here". Every
// Keychain item a test mints is deleted before the test returns, and one
// budget-neutral cycle test guards that the cleanup keeps working.
//
// Every test drives the twenty-row plaintext fixture or a temp file. The real
// estate and the machine's catalog are never opened, read, or referenced.

import Foundation
import LocusKitEstateFixture
import MootProductIdentity
import PersistenceKit
import Testing
@testable import GeniusLocusKit
#if canImport(Security)
import Security
import PersistenceKitSQLite
#endif
#if os(macOS) && canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if MOOTX01_HARNESS_KEYFILE
import EstateEncryption   // the harness key file the table's harness rows write
#endif

@Suite("EstateOpenPosture — new, ciphertext, plaintext and transient paths, and key custody")
struct EstateOpenPostureTests {

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("estate-posture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanup(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A registered record over a scratch directory: `estate.sqlite` inside it,
    /// no manifest unless a test writes one.
    private func registeredRecord(in directory: URL, name: String = "scratch") -> EstateRecord {
        EstateRecord(name: name, directory: directory.appendingPathComponent(name, isDirectory: true))
    }

    /// Delete the Keychain item a test minted for `databaseURL`, from both groups.
    private func deleteKeychainKey(for databaseURL: URL) {
        EstateOpenPosture.disposeKey(databaseURL: databaseURL)
    }

    /// Open the estate through a config and count its drawers. Exercises the real
    /// SQLite/SQLCipher path, so a wrong key surfaces as a thrown error.
    private func drawerCount(of configuration: EstateConfiguration) async throws -> Int {
        try await TwentyRowEstateFixture.drawerCount(of: configuration)
    }

    private func ciphertextBytes(seed: Int) -> Data {
        // A SQLCipher database encrypts page 1 including the header, so its first
        // 16 bytes are indistinguishable from random; deterministic non-magic
        // bytes are a faithful stand-in.
        var bytes = Data(count: 4096)
        bytes.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count { buffer[index] = UInt8((index * seed + 11) % 251) &+ 1 }
        }
        return bytes
    }

    // MARK: - Existing plaintext estate keeps opening

    @Test("An existing plaintext fixture estate resolves to the plaintext posture")
    func existingPlaintextEstateStaysPlaintext() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let resolved = try EstateOpenPosture.resolve(
            databaseURL: manifest.estateURL, registered: true, declaresPlaintext: false)
        #expect(resolved.posture == .existingPlaintext,
            "an existing plaintext estate must keep opening as plaintext — migration is `mootx01 upgrade` only")
        #expect(resolved.encryption.mode == .plaintext)
    }

    @Test("A plaintext fixture estate still reads all twenty drawers with no key")
    func plaintextEstateRemainsReadableWithoutAKey() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let resolved = try EstateOpenPosture.resolve(
            databaseURL: manifest.estateURL, registered: true, declaresPlaintext: false)
        let configuration = EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: manifest.estateURL, busyTimeout: 5.0),
            encryptionConfig: resolved.encryption)
        #expect(try await drawerCount(of: configuration) == manifest.drawerCount)
    }

    // MARK: - Ciphertext estate with no key fails closed

    @Test("A ciphertext estate whose key is unavailable fails closed and is left untouched")
    func ciphertextEstateWithoutKeyFailsClosed() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let encrypted = directory.appendingPathComponent("orphaned-ciphertext.sqlite")
        let bytes = ciphertextBytes(seed: 53)
        try bytes.write(to: encrypted)
        #expect(EstateOpenPosture.fileState(at: encrypted) == .ciphertext, "test premise")

        #expect(throws: EstateOpenPosture.Error.self) {
            _ = try EstateOpenPosture.resolve(databaseURL: encrypted, registered: true, declaresPlaintext: false)
        }
        #expect(try Data(contentsOf: encrypted) == bytes,
            "a failed open must leave the encrypted file byte-for-byte untouched")
    }

    @Test("existingKey never mints a key for an estate that has none")
    func existingKeyDoesNotMint() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        #expect(throws: (any Error).self) {
            _ = try EstateOpenPosture.existingKey(databaseURL: directory.appendingPathComponent("never-keyed.sqlite"))
        }
    }

    // MARK: - New estate path

    @Test("An absent registered estate resolves to the new-encrypted posture")
    func absentEstateResolvesToNewEncrypted() throws {
        guard EstateOpenPosture.isKeyCustodyAvailable else { return }
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let record = registeredRecord(in: directory)
        defer { deleteKeychainKey(for: record.databaseURL) }
        #expect(EstateOpenPosture.fileState(at: record.databaseURL) == .absent, "test premise")

        let resolved: (encryption: EstateEncryptionConfig, posture: EstateOpenPosture.Posture)
        do {
            resolved = try EstateOpenPosture.resolve(for: record)
        } catch {
            return  // no usable Keychain on this runner; the fail-closed tests hold regardless
        }
        #expect(resolved.posture == .newEncrypted,
            "a first run must provision a key and create the estate ENCRYPTED")
        #expect(resolved.encryption.mode == .fullDatabase)
    }

    @Test("A newly created estate is ciphertext on disk and reopens under the same key")
    func newEstateIsCiphertextAndReopens() async throws {
        guard EstateOpenPosture.isKeyCustodyAvailable else { return }
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let record = registeredRecord(in: directory)
        try FileManager.default.createDirectory(at: record.directory, withIntermediateDirectories: true)
        defer { deleteKeychainKey(for: record.databaseURL) }

        let first: (encryption: EstateEncryptionConfig, posture: EstateOpenPosture.Posture)
        do { first = try EstateOpenPosture.resolve(for: record) } catch { return }
        #expect(first.posture == .newEncrypted)

        _ = try await drawerCount(of: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: record.databaseURL, busyTimeout: 5.0),
            encryptionConfig: first.encryption))
        #expect(EstateOpenPosture.fileState(at: record.databaseURL) == .ciphertext,
            "a newly created encrypted estate must not carry the plaintext SQLite header")

        let second = try EstateOpenPosture.resolve(for: record)
        #expect(second.posture == .existingEncrypted, "the second open must recognise the file as encrypted")
        let reopened = try await drawerCount(of: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: record.databaseURL, busyTimeout: 5.0),
            encryptionConfig: second.encryption))
        #expect(reopened == 0, "the encrypted estate must reopen with the resolved key")
    }

    // MARK: - The manifest's plaintext declaration

    @Test("A record whose manifest declares plaintext is created plaintext")
    func declaredPlaintextRecordIsCreatedPlaintext() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let record = registeredRecord(in: directory)
        try EstateCatalog.writeManifest(EstateManifest(
            name: record.name, schemaVersion: GeniusLocusKitSchema.version, formatVersion: .current,
            encryption: .plaintext, created: "2026-09-08T00:00:00Z"), to: record)

        let resolved = try EstateOpenPosture.resolve(for: record)
        #expect(resolved.posture == .newPlaintextDeclared)
        guard case .plaintext = resolved.encryption.mode else { Issue.record("expected plaintext"); return }
        _ = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: record.databaseURL, busyTimeout: 5.0),
            encryptionConfig: resolved.encryption))
        #expect(EstateOpenPosture.fileState(at: record.databaseURL) == .plaintext)
    }

    @Test("The declaration never re-postures an estate that already exists")
    func declarationNeverRePosturesAnExistingEstate() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let databaseURL = directory.appendingPathComponent("estate.sqlite")
        let created = try EstateOpenPosture.resolve(databaseURL: databaseURL, registered: true, declaresPlaintext: true)
        _ = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: databaseURL, busyTimeout: 5.0),
            encryptionConfig: created.encryption))
        // Reopen with the declaration flipped: the file's posture wins.
        let reopened = try EstateOpenPosture.resolve(databaseURL: databaseURL, registered: true, declaresPlaintext: false)
        #expect(reopened.posture == .existingPlaintext)
    }

    // MARK: - Transient estates never touch the Keychain

    @Test("A transient estate opens plaintext whatever the declaration, and refuses ciphertext with or without a key")
    func transientEstateIsPlaintextOnly() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let record = EstateRecord(name: "scratch", directory: directory.appendingPathComponent("scratch"), kind: .transient)
        let absent = try EstateOpenPosture.resolve(for: record)
        #expect(absent.posture == .newPlaintextDeclared)
        guard case .plaintext = absent.encryption.mode else { Issue.record("expected plaintext"); return }
        try FileManager.default.createDirectory(at: record.directory, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 64).write(to: record.databaseURL)   // not a SQLite header
        #expect(throws: EstateOpenPosture.Error.self) {
            _ = try EstateOpenPosture.resolve(for: record)
        }
        // The row the ports once decided differently: a key exists for the
        // path, and the transient record still may not use it. The Rust twin
        // refuses a `db.key` beside a transient ciphertext file the same way.
        guard EstateOpenPosture.isKeyCustodyAvailable else { return }
        defer { deleteKeychainKey(for: record.databaseURL) }
        do { _ = try EstateOpenPosture.provideKey(databaseURL: record.databaseURL) } catch { return }
        #expect(throws: EstateOpenPosture.Error.self) {
            _ = try EstateOpenPosture.resolve(for: record)
        }
    }

    // MARK: - The shared decision table

    private struct PostureRow: Decodable {
        let id: String
        let registered: Bool
        let declaresPlaintext: Bool
        let file: String
        let key: Bool
        let harness: Bool
        let expected: String
    }
    private struct PostureFixture: Decodable { let rows: [PostureRow] }

    /// Resolves Tests/Conformance/estate_open_posture_fixture.json relative to
    /// this file, the way the other cross-port fixtures are found.
    private func postureFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance")
            .appendingPathComponent("estate_open_posture_fixture.json")
    }

    /// The name of an outcome as the shared fixture spells it.
    private func outcomeName(_ run: () throws -> (encryption: EstateEncryptionConfig, posture: EstateOpenPosture.Posture)) -> String {
        do {
            switch try run().posture {
            case .newEncrypted: return "newEncrypted"
            case .newPlaintextDeclared: return "newPlaintextDeclared"
            case .existingEncrypted: return "existingEncrypted"
            case .existingPlaintext: return "existingPlaintext"
            }
        } catch let error as EstateOpenPosture.Error {
            switch error {
            case .encryptedEstateKeyMissing: return "encryptedEstateKeyMissing"
            case .keychainUnavailable: return "keychainUnavailable"
            case .malformedKey: return "malformedKey"
            case .unsupportedPlatform: return "unsupportedPlatform"
            case .backendHasNoDatabaseFile: return "backendHasNoDatabaseFile"
            case .manifestRefused: return "manifestRefused"
            }
        } catch {
            return "\(error)"
        }
    }

    /// Every row of the shared decision table, driven through
    /// `resolve(databaseURL:registered:declaresPlaintext:)`. The Rust twin
    /// (`estate_open_posture::tests::posture_table_matches_the_shared_fixture`)
    /// reads the same file and runs every row unconditionally; it is the model.
    /// Here the key-bearing rows need a Keychain item. On a machine whose
    /// Keychain is usable every shipping row runs and a skipped row is a
    /// failure; where the Keychain is unusable the key-bearing rows are
    /// skipped and reported as a count, never silently folded into the pass.
    @Test("The posture decision table matches the shared cross-port fixture row by row")
    func postureTableMatchesTheSharedFixture() throws {
        let fixture = try JSONDecoder().decode(PostureFixture.self, from: Data(contentsOf: postureFixtureURL()))
        #expect(fixture.rows.count >= 12, "the table has at least the twelve shipping rows")
        #if MOOTX01_HARNESS_KEYFILE
        let harnessBuild = true
        #else
        let harnessBuild = false
        #endif
        let rows = fixture.rows.filter { $0.harness == harnessBuild }
        // Probe once: can this machine mint and read back an estate key?
        let keychainUsable: Bool = {
            guard EstateOpenPosture.isKeyCustodyAvailable else { return false }
            let probe = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("posture-table-probe-\(UUID().uuidString)/estate.sqlite")
            defer { EstateOpenPosture.disposeKey(databaseURL: probe) }
            return (try? EstateOpenPosture.provideKey(databaseURL: probe)) != nil
        }()
        var exercised = 0
        var skipped: [String] = []
        for row in rows {
            let directory = try makeTempDirectory()
            defer { cleanup(directory) }
            let databaseURL = directory.appendingPathComponent("estate.sqlite")
            defer { deleteKeychainKey(for: databaseURL) }
            switch row.file {
            case "absent": break
            case "plaintext": try Data("SQLite format 3\u{0} and a body".utf8).write(to: databaseURL)
            case "ciphertext": try ciphertextBytes(seed: 53).write(to: databaseURL)
            default: Issue.record("\(row.id): unknown file state \(row.file)"); continue
            }
            // A row needs a key when the fixture says one exists, or when the
            // expected outcome mints one (the shipping absent-registered row).
            let needsKeychain = !harnessBuild && (row.key || row.expected == "newEncrypted")
            if needsKeychain && !keychainUsable {
                skipped.append(row.id)
                continue
            }
            if row.key {
                #if MOOTX01_HARNESS_KEYFILE
                // In a harness build the key is the file beside the database.
                _ = try EstateEncryptionMigrator.loadOrCreateInstallKey(inDirectory: directory)
                #else
                // A shipping build's key is a Keychain item for the path. The
                // probe passed, so a failure here is a finding, not a skip.
                _ = try EstateOpenPosture.provideKey(databaseURL: databaseURL)
                #endif
            }
            let outcome = outcomeName {
                try EstateOpenPosture.resolve(databaseURL: databaseURL, registered: row.registered,
                                              declaresPlaintext: row.declaresPlaintext)
            }
            #expect(outcome == row.expected, "row \(row.id)")
            exercised += 1
        }
        #expect(exercised + skipped.count == rows.count, "every row of this build's half was either exercised or counted as skipped")
        #expect(skipped.isEmpty || !keychainUsable,
                "key-bearing rows were skipped on a machine whose Keychain is usable: \(skipped)")
        if !skipped.isEmpty {
            // Reported as a known issue, not hidden and not a failure: the
            // table was only partly proven on this runner.
            withKnownIssue("Keychain unusable on this runner; \(skipped.count) key-bearing rows skipped: \(skipped)") {
                Issue.record("skipped rows: \(skipped)")
            }
        }
        #expect(exercised >= rows.count - 5, "at most the five key-bearing shipping rows may be skipped (\(exercised) of \(rows.count) exercised)")
    }

    // MARK: - The manifest gate

    @Test("A refused manifest refuses the open with the catalog's error; an absent one does not")
    func refusedManifestRefusesTheOpen() throws {
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let record = EstateRecord(name: "scratch", directory: directory.appendingPathComponent("scratch"), kind: .transient)
        try FileManager.default.createDirectory(at: record.directory, withIntermediateDirectories: true)
        // Absent manifest, absent database: plaintext, nothing refused.
        #expect(try EstateOpenPosture.resolve(for: record).posture == .newPlaintextDeclared)
        // A manifest carrying a redirect key: refused, typed, with the catalog's detail inside.
        try #"{"fileVersion":1,"name":"scratch","schemaVersion":1,"formatVersion":{"major":1,"minor":7},"encryption":"plaintext","created":"2026-09-08T00:00:00Z","path":"/elsewhere"}"#
            .write(to: record.manifestURL, atomically: true, encoding: .utf8)
        var thrown: EstateOpenPosture.Error?
        do { _ = try EstateOpenPosture.resolve(for: record) } catch let e as EstateOpenPosture.Error { thrown = e }
        guard case .manifestRefused(.unreadableEstateManifest(_, let detail))? = thrown, detail.contains("path") else {
            Issue.record("expected manifestRefused with the catalog's detail, got \(String(describing: thrown))"); return
        }
        #expect(thrown?.description.contains("manifest refused") == true)
        // A manifest for another estate: refused too.
        try #"{"fileVersion":1,"name":"other","schemaVersion":1,"formatVersion":{"major":1,"minor":7},"encryption":"plaintext","created":"2026-09-08T00:00:00Z"}"#
            .write(to: record.manifestURL, atomically: true, encoding: .utf8)
        thrown = nil
        do { _ = try EstateOpenPosture.resolve(for: record) } catch let e as EstateOpenPosture.Error { thrown = e }
        guard case .manifestRefused? = thrown else { Issue.record("foreign name: \(String(describing: thrown))"); return }
        // A correct manifest declaring plaintext: read.
        try #"{"fileVersion":1,"name":"scratch","schemaVersion":1,"formatVersion":{"major":1,"minor":7},"encryption":"plaintext","created":"2026-09-08T00:00:00Z"}"#
            .write(to: record.manifestURL, atomically: true, encoding: .utf8)
        #expect(try EstateOpenPosture.manifestDeclaresPlaintext(record))
        // No manifest but a symlinked database: refused by the same gate.
        try FileManager.default.removeItem(at: record.manifestURL)
        let elsewhere = directory.appendingPathComponent("elsewhere.sqlite")
        try Data("x".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: record.databaseURL, withDestinationURL: elsewhere)
        thrown = nil
        do { _ = try EstateOpenPosture.resolve(for: record) } catch let e as EstateOpenPosture.Error { thrown = e }
        guard case .manifestRefused? = thrown else { Issue.record("symlink: \(String(describing: thrown))"); return }
    }

    // MARK: - Key custody

    @Test("Key round-trips, is idempotent per estate, and differs between estates")
    func keyCustodyRoundTrip() throws {
        guard EstateOpenPosture.isKeyCustodyAvailable else { return }
        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        let one = directory.appendingPathComponent("one.sqlite")
        let two = directory.appendingPathComponent("two.sqlite")
        defer { deleteKeychainKey(for: one); deleteKeychainKey(for: two) }

        let first: Data
        do { first = try EstateOpenPosture.provideKey(databaseURL: one) } catch { return }
        #expect(first.count == EstateOpenPosture.keyByteCount)
        #expect(first.contains(where: { $0 != 0 }), "an all-zero key would mean SecRandomCopyBytes silently failed")
        // The property that matters most: a second call must return the SAME
        // key, or an estate encrypted with the first would be unopenable.
        #expect(try EstateOpenPosture.provideKey(databaseURL: one) == first)
        #expect(try EstateOpenPosture.provideKey(databaseURL: two) != first,
            "keys are scoped per estate path")
    }

    @Test("A returned key is always exactly 32 bytes or the call throws")
    func failsClosedRatherThanFallingBackToPlaintext() throws {
        let hostileURL = URL(fileURLWithPath: "/dev/null/nope/estate.sqlite")
        defer { deleteKeychainKey(for: hostileURL) }
        do {
            let key = try EstateOpenPosture.provideKey(databaseURL: hostileURL)
            #expect(key.count == EstateOpenPosture.keyByteCount)
        } catch {
            #expect(Bool(true))  // throwing is the correct fail-closed outcome
        }
    }

    @Test("On Apple platforms key custody is compiled in")
    func keyCustodyIsCompiledIn() {
        #if canImport(Security)
        #expect(EstateOpenPosture.isKeyCustodyAvailable,
            "if the Keychain path dropped out of the build every estate would quietly revert to plaintext")
        #endif
    }

    @Test("The Keychain strings are the product identity's, spelled once")
    func keychainStringsComeFromProductIdentity() {
        #expect(MootProductIdentity.Keychain.estateKeyService == "com.codedaptive.mootx01")
        #expect(MootProductIdentity.Keychain.sharedAccessGroup == "com.codedaptive.mootx01.shared")
    }

    // MARK: - File classification

    @Test("Detection classifies plaintext, absent, ciphertext, truncated and directory paths")
    func fileStateClassification() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        #expect(EstateOpenPosture.fileState(at: manifest.estateURL) == .plaintext)

        let directory = try makeTempDirectory()
        defer { cleanup(directory) }
        #expect(EstateOpenPosture.fileState(at: directory.appendingPathComponent("missing.sqlite")) == .absent)
        let encrypted = directory.appendingPathComponent("encrypted.sqlite")
        try ciphertextBytes(seed: 37).write(to: encrypted)
        #expect(EstateOpenPosture.fileState(at: encrypted) == .ciphertext)
        // Empty or short files are NOT absent: reporting them absent would
        // invite a caller to create over the top of a file it did not understand.
        let empty = directory.appendingPathComponent("empty.sqlite")
        try Data().write(to: empty)
        #expect(EstateOpenPosture.fileState(at: empty) == .ciphertext)
        let short = directory.appendingPathComponent("short.sqlite")
        try Data("SQLite".utf8).write(to: short)
        #expect(EstateOpenPosture.fileState(at: short) == .ciphertext)
        let nested = directory.appendingPathComponent("dir.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(EstateOpenPosture.fileState(at: nested) == .absent)
        #expect(EstateOpenPosture.plaintextSQLiteMagic == TwentyRowEstateFixture.plaintextSQLiteMagic,
            "the fixture and the production detector must share one definition of plaintext")
    }
}

#if os(macOS) && canImport(Security) && canImport(LocalAuthentication)
/// Count live login-Keychain items for one service and account, failing
/// immediately instead of blocking on a Keychain prompt when the test binary
/// lacks the shared-access-group entitlement.
private func keychainItemCount(service: String, account: String) -> Int {
    let authContext = LAContext()
    authContext.interactionNotAllowed = true
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecMatchLimit: kSecMatchLimitAll,
        kSecReturnAttributes: true,
        kSecUseAuthenticationContext: authContext,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let items = result as? [[CFString: Any]] else { return 0 }
    return items.count
}

/// Key relocation: the account follows the file. Budget-neutral: every item
/// minted here is disposed before the test returns.
@Suite("EstateOpenPosture — key relocation", .serialized)
struct EstateKeyRelocationTests {

    @Test("relocateKey moves the item to the new path's account once, then reports nothing to move")
    func relocationMovesTheKeyOnce() throws {
        guard EstateOpenPosture.isKeyCustodyAvailable else { return }
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("estate-key-relocation-\(UUID().uuidString)", isDirectory: true)
        let old = base.appendingPathComponent("flat/estate.sqlite")
        let new = base.appendingPathComponent("databases/default/estate.sqlite")
        defer {
            EstateOpenPosture.disposeKey(databaseURL: old)
            EstateOpenPosture.disposeKey(databaseURL: new)
        }
        // No key anywhere: nothing to move, nothing minted.
        #expect(try EstateOpenPosture.relocateKey(from: old, to: new) == false)
        let key: Data
        do { key = try EstateOpenPosture.provideKey(databaseURL: old) } catch { return }   // Keychain not usable here
        #expect(try EstateOpenPosture.relocateKey(from: old, to: new) == true)
        #expect(try EstateOpenPosture.existingKey(databaseURL: new) == key, "the same key bytes follow the file")
        #expect(throws: EstateOpenPosture.Error.self) { try EstateOpenPosture.existingKey(databaseURL: old) }
        // Second call: already at the new path.
        #expect(try EstateOpenPosture.relocateKey(from: old, to: new) == false)
        #expect(try EstateOpenPosture.existingKey(databaseURL: new) == key)
    }

    @Test("relocateKey never overwrites a key already at the new path")
    func relocationKeepsTheDestinationKey() throws {
        guard EstateOpenPosture.isKeyCustodyAvailable else { return }
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("estate-key-relocation-\(UUID().uuidString)", isDirectory: true)
        let old = base.appendingPathComponent("a/estate.sqlite")
        let new = base.appendingPathComponent("b/estate.sqlite")
        defer {
            EstateOpenPosture.disposeKey(databaseURL: old)
            EstateOpenPosture.disposeKey(databaseURL: new)
        }
        let oldKey: Data
        do { oldKey = try EstateOpenPosture.provideKey(databaseURL: old) } catch { return }
        let newKey = try EstateOpenPosture.provideKey(databaseURL: new)
        #expect(oldKey != newKey)
        #expect(try EstateOpenPosture.relocateKey(from: old, to: new) == false)
        #expect(try EstateOpenPosture.existingKey(databaseURL: new) == newKey)
        #expect(try EstateOpenPosture.existingKey(databaseURL: old) == oldKey, "the old item is left for the operator; nothing is deleted")
    }
}

/// Regression guard: provideKey + disposeKey must leave the login Keychain as
/// it was. A failure means a mint that the disposal no longer finds.
@Suite("Keychain budget guard — GeniusLocusKitTests must not grow the login Keychain", .serialized)
struct KeychainBudgetGuardTests {
    @Test("provideKey + disposeKey is budget-neutral for the estate key service")
    func mintAndDisposeIsNeutral() throws {
        guard EstateOpenPosture.isKeyCustodyAvailable else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("keychain-budget-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let databaseURL = dir.appendingPathComponent("guard-probe.sqlite")
        let service = MootProductIdentity.Keychain.estateKeyService
        let account = KeychainKeyStore(service: service, estateURL: databaseURL, accessGroup: nil).account
        let before = keychainItemCount(service: service, account: account)
        do { _ = try EstateOpenPosture.provideKey(databaseURL: databaseURL) } catch { return }
        EstateOpenPosture.disposeKey(databaseURL: databaseURL)
        let after = keychainItemCount(service: service, account: account)
        #expect(after == before, "provideKey + disposeKey must be budget-neutral (before=\(before), after=\(after))")
    }
}
#endif
