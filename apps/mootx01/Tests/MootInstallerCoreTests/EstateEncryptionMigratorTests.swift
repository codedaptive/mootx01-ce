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

    // MARK: - Part 4: atomic swap and Trash

    /// Lock-protected event recorder so @Sendable seam closures can append
    /// from a Swift 6 strict-concurrency context.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ event: String) { lock.withLock { storage.append(event) } }
        var events: [String] { lock.withLock { storage } }
    }

    /// A trash seam that moves items into a "trash" directory beside the
    /// estate, so tests never touch the user's real Trash.
    private func makeTestTrash(in directory: URL) -> (EstateEncryptionMigrator.TrashItem, URL) {
        let trashDir = directory.appendingPathComponent("test-trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        return ({ url in
            let dest = trashDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }, trashDir)
    }

    @Test("The full migration leaves ciphertext at the canonical path and plaintext in the trash")
    func fullMigrationHappyPath() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let key = makeKey()
        let dir = manifest.estateURL.deletingLastPathComponent()
        let (trash, trashDir) = makeTestTrash(in: dir)

        // A daemon recorder proving stop-BEFORE-EXPORT (Bob's ruling: never
        // lose data — no write may land after the clone is taken) and
        // restart-after. The stop closure checks that no clone exists yet.
        let log = EventLog()
        let clonePath = manifest.estateURL.path + ".encrypting"
        let daemon = EstateEncryptionMigrator.DaemonControl(
            isRunning: { log.append("isRunning"); return true },
            stop: {
                log.append(FileManager.default.fileExists(atPath: clonePath)
                    ? "stop-AFTER-export (data-loss window!)" : "stop")
                return true
            },
            start: { log.append("start"); return true })

        let result = try EstateEncryptionMigrator.migrate(
            estateURL: manifest.estateURL, key: key, daemon: daemon, trash: trash)

        // The canonical path holds ciphertext that opens with the key.
        #expect(EstateKeyProvider.detectEstateFileState(at: manifest.estateURL) == .ciphertext,
            "the canonical estate path must now hold the encrypted estate")
        let count = try await TwentyRowEstateFixture.drawerCount(of: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: manifest.estateURL, busyTimeout: 5.0),
            encryptionConfig: .fullDatabase(key: key)))
        #expect(count == manifest.drawerCount)

        // Daemon lifecycle: stopped before the swap, restarted after.
        #expect(log.events == ["isRunning", "stop", "start"])
        #expect(result.swap.daemonWasRunning && result.swap.daemonRestarted)

        // The trash holds a READABLE plaintext copy — the mission's "still
        // unencrypted in the Trash" promise, proven by opening it.
        let trashed = try #require(result.swap.trashedOriginalURL)
        #expect(trashed.path.hasPrefix(trashDir.path))
        #expect(EstateKeyProvider.detectEstateFileState(at: trashed) == .plaintext)
        let trashedCount = try await TwentyRowEstateFixture.drawerCount(of: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: trashed, busyTimeout: 5.0),
            encryptionConfig: .plaintext))
        #expect(trashedCount == manifest.drawerCount,
            "the trashed original must remain a complete readable estate")
        #expect(result.swap.untrashedOriginalPath == nil)

        // No leftover working files beside the estate.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".encrypting") || $0.contains(".pre-encryption") }
        #expect(leftovers.isEmpty, "the swap must clean up its working files: \(leftovers)")
    }

    @Test("All four sensitivity tiers survive migration with their adjective bits intact")
    func sensitivityTiersSurvive() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let key = makeKey()
        let (trash, _) = makeTestTrash(in: manifest.estateURL.deletingLastPathComponent())

        // Tier → adjectiveBitmap of every drawer, before.
        let before = try tierBitmaps(
            estateURL: manifest.estateURL, keyHex: nil, manifest: manifest)
        _ = try EstateEncryptionMigrator.migrate(
            estateURL: manifest.estateURL, key: key, daemon: .none, trash: trash)
        let after = try tierBitmaps(
            estateURL: manifest.estateURL,
            keyHex: EstateEncryptionMigrator.keyHex(key), manifest: manifest)

        #expect(before == after,
            "every tier drawer's adjective bitmap must survive the migration bit-for-bit")
        #expect(before.count == 4, "test premise: one drawer per sensitivity tier")
    }

    /// Read `adjectiveBitmap` for the four tier-anchor drawers via raw SQL,
    /// so the comparison is on stored bits, not decoded views.
    private func tierBitmaps(
        estateURL: URL, keyHex: String?, manifest: TwentyRowEstateFixture.Manifest
    ) throws -> [String: Int64] {
        let db = try EstateEncryptionMigrator.openRaw(path: estateURL.path, keyHex: keyHex)
        defer { _ = sqlite3_close_v2(db) }
        var result: [String: Int64] = [:]
        for (_, drawerID) in manifest.drawerIDsByProvenanceTier {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT \"adjectiveBitmap\" FROM \"drawers\" WHERE \"id\" = ?;",
                -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw EstateEncryptionMigrator.MigrationError.sqlite(
                    step: "tier read (test)", detail: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, drawerID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw EstateEncryptionMigrator.MigrationError.sqlite(
                    step: "tier read (test)", detail: "drawer \(drawerID) not found")
            }
            result[drawerID] = sqlite3_column_int64(stmt, 0)
        }
        return result
    }

    // MARK: - Part 5: every failure path leaves a working estate

    /// Prove the canonical path still holds the complete plaintext original.
    private func assertOriginalIntact(_ manifest: TwentyRowEstateFixture.Manifest) async throws {
        #expect(EstateKeyProvider.detectEstateFileState(at: manifest.estateURL) == .plaintext)
        let count = try await TwentyRowEstateFixture.drawerCount(of: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: manifest.estateURL, busyTimeout: 5.0),
            encryptionConfig: .plaintext))
        #expect(count == manifest.drawerCount,
            "after a failed migration the canonical path must hold the complete plaintext original")
    }

    @Test("A daemon that will not stop aborts the swap with the original untouched")
    func daemonStopFailureAborts() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let daemon = EstateEncryptionMigrator.DaemonControl(
            isRunning: { true }, stop: { false }, start: { true })

        #expect(throws: (any Error).self) {
            _ = try EstateEncryptionMigrator.migrate(
                estateURL: manifest.estateURL, key: makeKey(), daemon: daemon,
                trash: { _ in throw CocoaError(.fileNoSuchFile) })
        }
        try await assertOriginalIntact(manifest)
        let dir = manifest.estateURL.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".encrypting") || $0.contains(".pre-encryption") }
        #expect(leftovers.isEmpty, "an aborted swap must clean up its working files: \(leftovers)")
    }

    @Test("A swap that cannot write beside the estate unwinds to the original")
    func swapWriteFailureUnwinds() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        let dir = manifest.estateURL.deletingLastPathComponent()
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            TwentyRowEstateFixture.cleanup(manifest)
        }
        let key = makeKey()
        let copy = encryptedSibling(of: manifest.estateURL)
        try EstateEncryptionMigrator.exportEncryptedCopy(
            from: manifest.estateURL, to: copy, key: key)

        // A read-only estate directory makes the aside hard-link fail —
        // the same unwind path a failed rename takes.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(throws: (any Error).self) {
            _ = try EstateEncryptionMigrator.swapInEncryptedCopy(
                original: manifest.estateURL, encryptedCopy: copy,
                trash: { _ in throw CocoaError(.fileNoSuchFile) })
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        try await assertOriginalIntact(manifest)
    }

    @Test("A failure after the daemon stopped restarts it over the original")
    func postStopFailureRestartsDaemon() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        let dir = manifest.estateURL.deletingLastPathComponent()
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            TwentyRowEstateFixture.cleanup(manifest)
        }
        // A read-only directory fails the migration at the export's ATTACH —
        // the first step after the daemon stop.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let log = EventLog()
        let daemon = EstateEncryptionMigrator.DaemonControl(
            isRunning: { log.append("isRunning"); return true },
            stop: { log.append("stop"); return true },
            start: { log.append("start"); return true })

        #expect(throws: (any Error).self) {
            _ = try EstateEncryptionMigrator.migrate(
                estateURL: manifest.estateURL, key: makeKey(), daemon: daemon,
                trash: { _ in throw CocoaError(.fileNoSuchFile) })
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        try await assertOriginalIntact(manifest)
        #expect(log.events == ["isRunning", "stop", "start"],
            "a failed migration must restart the daemon it stopped")
    }

    @Test("A trash failure reports the plaintext path instead of proceeding silently")
    func trashFailureReportsPath() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let key = makeKey()

        let result = try EstateEncryptionMigrator.migrate(
            estateURL: manifest.estateURL, key: key, daemon: .none,
            trash: { _ in throw CocoaError(.fileWriteNoPermission) })

        // The migration itself succeeded: canonical path is ciphertext.
        #expect(EstateKeyProvider.detectEstateFileState(at: manifest.estateURL) == .ciphertext)
        // And the failure is reported, with the plaintext copy still on disk.
        let reported = try #require(result.swap.untrashedOriginalPath)
        #expect(FileManager.default.fileExists(atPath: reported))
        #expect(EstateKeyProvider.detectEstateFileState(
            at: URL(fileURLWithPath: reported)) == .plaintext,
            "the reported path must be the untrashed plaintext original")
        // Clean up the aside file the failed trash left behind.
        try? FileManager.default.removeItem(atPath: reported)
    }

    @Test("A daemon restart failure is reported but does not fail the migration")
    func daemonRestartFailureIsNonFatal() async throws {
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let (trash, _) = makeTestTrash(in: manifest.estateURL.deletingLastPathComponent())
        let daemon = EstateEncryptionMigrator.DaemonControl(
            isRunning: { true }, stop: { true }, start: { false })

        let result = try EstateEncryptionMigrator.migrate(
            estateURL: manifest.estateURL, key: makeKey(), daemon: daemon, trash: trash)

        #expect(EstateKeyProvider.detectEstateFileState(at: manifest.estateURL) == .ciphertext,
            "the encrypted estate is in place regardless of the restart failure")
        #expect(result.swap.daemonWasRunning)
        #expect(!result.swap.daemonRestarted,
            "the restart failure must be visible to the caller for honest reporting")
    }

    @Test("Migration declines to run on a non-plaintext source")
    func migrateRefusesNonPlaintextSource() async throws {
        // The full driver, not just the export, must refuse: this is what
        // makes a re-run after success (or a race with serve's first-run
        // encryption) a no-op instead of a double-wrap.
        let manifest = try await TwentyRowEstateFixture.generateInTemporaryDirectory()
        defer { TwentyRowEstateFixture.cleanup(manifest) }
        let key = makeKey()
        let (trash, _) = makeTestTrash(in: manifest.estateURL.deletingLastPathComponent())
        _ = try EstateEncryptionMigrator.migrate(
            estateURL: manifest.estateURL, key: key, daemon: .none, trash: trash)

        #expect(throws: (any Error).self) {
            _ = try EstateEncryptionMigrator.migrate(
                estateURL: manifest.estateURL, key: key, daemon: .none, trash: trash)
        }
        // Still openable with the key — the refused second run changed nothing.
        let count = try await TwentyRowEstateFixture.drawerCount(of: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: manifest.estateURL, busyTimeout: 5.0),
            encryptionConfig: .fullDatabase(key: key)))
        #expect(count == manifest.drawerCount)
    }

    // MARK: - Part 1: the offer (source-level drift guards)

    // UpgradeCommand lives in the mootx01 executable target, which this test
    // target cannot import (same seam as CE-1.0.35-02/-06), so the offer's
    // structural requirements are asserted at the source level — the same
    // pattern EstateOpenPostureTests uses for the shared posture helper.

    private var commandsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/mootx01
            .appendingPathComponent("Sources/mootx01/Commands")
    }

    @Test("UpgradeCommand gates the offer on plaintext detection and a TTY")
    func upgradeCommandGatesTheOffer() throws {
        let source = try String(
            contentsOf: commandsDirectory.appendingPathComponent("UpgradeCommand.swift"),
            encoding: .utf8)
        #expect(source.contains("detectEstateFileState"),
            "the offer must classify via the shared detection function, never by guessing")
        #expect(source.contains("isatty"),
            "a non-TTY invocation must never prompt and never migrate")
        #expect(source.contains("EstateEncryptionMigrator.migrate"),
            "the accepted offer must run the migrator, not a bespoke path")
        #expect(source.contains("EstateKeyProvider.provideKey"),
            "key provisioning must go through EstateKeyProvider's custody")
    }

    @Test("No other command detects or prompts for estate encryption migration")
    func noOtherCommandOffersMigration() throws {
        // Bob's ruling: `mootx01 upgrade` is the ONLY migration vehicle.
        // resolveOpenPosture callers (serve/drain/dream) classify to OPEN,
        // which is allowed; what no other command may do is drive migration.
        for name in ["ServeCommand", "DrainCommand", "DreamCommand",
                     "InstallCommand", "DbCommand"] {
            let url = commandsDirectory.appendingPathComponent("\(name).swift")
            let source = try String(contentsOf: url, encoding: .utf8)
            #expect(!source.contains("EstateEncryptionMigrator"),
                "\(name) must not reference the migrator — upgrade is the only vehicle")
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
